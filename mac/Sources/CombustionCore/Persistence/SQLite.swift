import CSQLite
import Foundation

public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob([UInt8])
}

public struct SQLiteError: Error, Equatable, CustomStringConvertible {
    public var code: Int32
    public var message: String
    public var sql: String?
    public var description: String { "SQLite error \(code): \(message)" + (sql.map { " [\($0)]" } ?? "") }
}

/// Thin wrapper over a sqlite3 handle.
///
/// Concurrency: deliberately NOT Sendable. It is a final class meant to be owned
/// and used only from one actor (the HistoryStore actor); the compiler enforces
/// that confinement.
public final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private var transactionDepth = 0

    /// `":memory:"` or a file path.
    public init(path: String) throws {
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: message, sql: nil)
        }
        handle = db
        if path != ":memory:" {
            _ = try query("PRAGMA journal_mode=WAL")
        }
    }

    public static func inMemory() throws -> SQLiteDatabase { try SQLiteDatabase(path: ":memory:") }

    deinit { sqlite3_close(handle) }

    func error(_ rc: Int32, sql: String? = nil) -> SQLiteError {
        SQLiteError(code: rc, message: handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed", sql: sql)
    }

    /// Run one or more statements without parameters or results.
    public func exec(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw error(rc, sql: sql) }
    }

    public func prepare(_ sql: String) throws -> SQLiteStatement {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(rc, sql: sql) }
        return SQLiteStatement(stmt, db: self, sql: sql)
    }

    /// Prepare, bind, run to completion. Returns rows changed.
    @discardableResult
    public func run(_ sql: String, _ params: [SQLiteValue] = []) throws -> Int {
        let s = try prepare(sql)
        try s.bind(params)
        while try s.step() {}
        return changes
    }

    public func query(_ sql: String, _ params: [SQLiteValue] = []) throws -> [[SQLiteValue]] {
        let s = try prepare(sql)
        try s.bind(params)
        var rows: [[SQLiteValue]] = []
        while try s.step() { rows.append(s.row()) }
        return rows
    }

    /// Rows changed by the most recent INSERT/UPDATE/DELETE.
    public var changes: Int { Int(sqlite3_changes(handle)) }
    public var lastInsertRowId: Int64 { sqlite3_last_insert_rowid(handle) }

    /// Runs `body` in a transaction (a savepoint when nested). Rolls back if it throws.
    @discardableResult
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        let nested = transactionDepth > 0
        let name = "sp\(transactionDepth)"
        try exec(nested ? "SAVEPOINT \(name)" : "BEGIN IMMEDIATE")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try exec(nested ? "RELEASE \(name)" : "COMMIT")
            return result
        } catch {
            try? exec(nested ? "ROLLBACK TO \(name); RELEASE \(name)" : "ROLLBACK")
            throw error
        }
    }

    public var userVersion: Int {
        get {
            if case .integer(let v)? = (try? query("PRAGMA user_version"))?.first?.first { return Int(v) }
            return 0
        }
        set { try? exec("PRAGMA user_version = \(newValue)") }
    }

    /// Applies, in order and each in its own transaction, every migration whose
    /// version is greater than `user_version`, then records the new version.
    public func migrate(_ migrations: [Migration]) throws {
        for m in migrations.sorted(by: { $0.version < $1.version }) where m.version > userVersion {
            try transaction {
                try exec(m.sql)
                try exec("PRAGMA user_version = \(m.version)")
            }
        }
    }
}

public struct Migration: Sendable {
    public var version: Int
    public var sql: String
    public init(version: Int, sql: String) {
        self.version = version
        self.sql = sql
    }
}

public final class SQLiteStatement {
    private var stmt: OpaquePointer?
    private unowned let db: SQLiteDatabase
    private let sql: String
    // SQLITE_TRANSIENT is a C macro and not imported.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ stmt: OpaquePointer, db: SQLiteDatabase, sql: String) {
        self.stmt = stmt
        self.db = db
        self.sql = sql
    }

    deinit { sqlite3_finalize(stmt) }

    /// Parameter indices are 1-based, as in SQLite.
    public func bind(_ index: Int32, _ value: SQLiteValue) throws {
        let rc: Int32
        switch value {
        case .null: rc = sqlite3_bind_null(stmt, index)
        case .integer(let v): rc = sqlite3_bind_int64(stmt, index, v)
        case .real(let v): rc = sqlite3_bind_double(stmt, index, v)
        case .text(let v): rc = sqlite3_bind_text(stmt, index, v, -1, Self.transient)
        case .blob(let v):
            rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32($0.count), Self.transient) }
        }
        guard rc == SQLITE_OK else { throw db.error(rc, sql: sql) }
    }

    public func bind(_ params: [SQLiteValue]) throws {
        for (i, p) in params.enumerated() { try bind(Int32(i + 1), p) }
    }

    /// True when a row is available, false when done.
    public func step() throws -> Bool {
        let rc = sqlite3_step(stmt)
        switch rc {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw db.error(rc, sql: sql)
        }
    }

    public func reset() throws {
        let rc = sqlite3_reset(stmt)
        guard rc == SQLITE_OK else { throw db.error(rc, sql: sql) }
    }

    public func clearBindings() { sqlite3_clear_bindings(stmt) }

    public var columnCount: Int { Int(sqlite3_column_count(stmt)) }

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }

    public func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }

    public func blob(_ i: Int32) -> [UInt8]? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return [] }
        return Array(UnsafeBufferPointer(start: p.assumingMemoryBound(to: UInt8.self), count: n))
    }

    public func value(_ i: Int32) -> SQLiteValue {
        switch sqlite3_column_type(stmt, i) {
        case SQLITE_INTEGER: return .integer(int64(i))
        case SQLITE_FLOAT: return .real(double(i))
        case SQLITE_TEXT: return .text(text(i) ?? "")
        case SQLITE_BLOB: return .blob(blob(i) ?? [])
        default: return .null
        }
    }

    public func row() -> [SQLiteValue] { (0..<Int32(columnCount)).map(value) }
}
