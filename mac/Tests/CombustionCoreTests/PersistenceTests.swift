import CombustionCore
import Foundation
import Testing

struct PersistenceTests {
    private func migrated() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase.inMemory()
        try Schema.migrate(db)
        return db
    }

    @Test func migrationOneRunsOnceAndSetsUserVersion() throws {
        let db = try SQLiteDatabase.inMemory()
        #expect(db.userVersion == 0)
        try Schema.migrate(db)
        #expect(db.userVersion == 1)
        // A second pass must not re-run (CREATE TABLE would fail).
        try Schema.migrate(db)
        #expect(db.userVersion == 1)
        let tables = try db.query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        #expect(tables == ["alert_event", "alert_rule", "probe", "sample", "session"].map { [.text($0)] })
    }

    @Test func laterMigrationsApplyInOrderOnce() throws {
        let db = try migrated()
        let extra = Migration(version: 2, sql: "ALTER TABLE probe ADD COLUMN note TEXT")
        try db.migrate(Schema.migrations + [extra])
        try db.migrate(Schema.migrations + [extra])
        #expect(db.userVersion == 2)
    }

    @Test func failedMigrationRollsBack() throws {
        let db = try migrated()
        let bad = Migration(version: 2, sql: "CREATE TABLE ok(x); CREATE TABLE probe(y)")
        #expect(throws: SQLiteError.self) { try db.migrate(Schema.migrations + [bad]) }
        #expect(db.userVersion == 1)
        #expect(try db.query("SELECT name FROM sqlite_master WHERE name='ok'").isEmpty)
    }

    @Test func schemaMatchesDesignDoc() throws {
        let db = try migrated()
        func columns(_ table: String) throws -> [String] {
            try db.query("SELECT name FROM pragma_table_info('\(table)')").map { row in
                if case .text(let s) = row[0] { s } else { "" }
            }
        }
        #expect(try columns("probe") == ["serial", "nickname", "followed", "last_seen"])
        #expect(try columns("session") == ["id", "serial", "session_id", "sample_period_ms", "started_at", "ended_at",
                                           "anchor_seq", "anchor_time", "nickname", "kind", "ready_since", "thumbnail"])
        #expect(try columns("sample") == ["session", "seq", "t1", "t2", "t3", "t4", "t5", "t6", "t7", "t8", "vs",
                                          "pred_state", "pred_mode", "pred_type", "setpoint", "pred_seconds", "est_core"])
        #expect(try columns("alert_rule") == ["id", "serial", "kind", "params_json", "enabled"])
        #expect(try columns("alert_event") == ["id", "rule_id", "serial", "session", "fired_at", "cleared_at",
                                               "acked_at", "value"])
    }

    @Test func sampleInsertOrIgnoreIsIdempotentOnPrimaryKey() throws {
        let db = try migrated()
        let sql = "INSERT OR IGNORE INTO sample(session, seq, t1, vs) VALUES (?, ?, ?, ?)"
        #expect(try db.run(sql, [.integer(1), .integer(7), .real(21.5), .integer(3)]) == 1)
        #expect(try db.run(sql, [.integer(1), .integer(7), .real(99), .integer(9)]) == 0)
        #expect(try db.run(sql, [.integer(1), .integer(8), .real(22), .integer(3)]) == 1)
        let rows = try db.query("SELECT seq, t1 FROM sample ORDER BY seq")
        #expect(rows == [[.integer(7), .real(21.5)], [.integer(8), .real(22)]])
    }

    @Test func sessionUniqueKey() throws {
        let db = try migrated()
        let sql = "INSERT INTO session(serial, session_id, started_at) VALUES (?, ?, ?)"
        try db.run(sql, [.integer(0x10005A3F), .integer(0), .integer(1000)])
        // Same probe and session_id 0 but a different start is a new cook.
        try db.run(sql, [.integer(0x10005A3F), .integer(0), .integer(2000)])
        do {
            try db.run(sql, [.integer(0x10005A3F), .integer(0), .integer(1000)])
            Issue.record("expected a unique constraint failure")
        } catch let e as SQLiteError {
            #expect(e.code == 19)  // SQLITE_CONSTRAINT
        }
    }

    @Test func valueRoundTripIncludingNullAndBlob() throws {
        let db = try migrated()
        try db.run("INSERT INTO probe(serial, nickname, followed, last_seen) VALUES (?, ?, ?, ?)",
                   [.integer(Int64(UInt32.max)), .text("Brisket \u{1F525}"), .null, .integer(-5)])
        try db.run("INSERT INTO session(id, thumbnail) VALUES (1, ?)", [.blob([0, 1, 2, 255])])
        try db.run("INSERT INTO session(id, thumbnail) VALUES (2, ?)", [.blob([])])
        let s = try db.prepare("SELECT serial, nickname, followed, last_seen FROM probe")
        #expect(try s.step())
        #expect(s.int64(0) == Int64(UInt32.max))
        #expect(s.text(1) == "Brisket \u{1F525}")
        #expect(s.isNull(2))
        #expect(s.int64(3) == -5)
        #expect(try !s.step())
        let blobs = try db.prepare("SELECT thumbnail FROM session ORDER BY id")
        #expect(try blobs.step())
        #expect(blobs.blob(0) == [0, 1, 2, 255])
        #expect(try blobs.step())
        #expect(blobs.blob(0) == [])
    }

    @Test func preparedStatementCanBeReusedWithReset() throws {
        let db = try migrated()
        let insert = try db.prepare("INSERT INTO sample(session, seq, est_core) VALUES (?, ?, ?)")
        for seq in 0..<3 {
            try insert.bind([.integer(1), .integer(Int64(seq)), .real(Double(seq) / 2)])
            #expect(try !insert.step())
            try insert.reset()
            insert.clearBindings()
        }
        #expect(try db.query("SELECT count(*) FROM sample") == [[.integer(3)]])
    }

    @Test func transactionsCommitRollbackAndNest() throws {
        let db = try migrated()
        try db.transaction { try db.run("INSERT INTO probe(serial) VALUES (1)") }
        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.run("INSERT INTO probe(serial) VALUES (2)")
                throw Boom()
            }
        }
        try db.transaction {
            try db.run("INSERT INTO probe(serial) VALUES (3)")
            _ = try? db.transaction {
                try db.run("INSERT INTO probe(serial) VALUES (4)")
                throw Boom()
            }
        }
        #expect(try db.query("SELECT serial FROM probe ORDER BY serial") == [[.integer(1)], [.integer(3)]])
    }

    @Test func fileDatabasePersistsAcrossReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("colby-\(UUID().uuidString).sqlite").path
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        do {
            let db = try SQLiteDatabase(path: path)
            try Schema.migrate(db)
            try db.run("INSERT INTO probe(serial, nickname) VALUES (5, 'x')")
        }
        let db = try SQLiteDatabase(path: path)
        try Schema.migrate(db)
        #expect(db.userVersion == 1)
        #expect(try db.query("SELECT nickname FROM probe") == [[.text("x")]])
    }

    @Test func badSQLThrowsWithMessage() throws {
        let db = try SQLiteDatabase.inMemory()
        do {
            try db.exec("SELEC nonsense")
            Issue.record("expected failure")
        } catch let e as SQLiteError {
            #expect(e.code == 1)
            #expect(e.message.contains("syntax"))
        }
    }
}
