import CombustionCodec
import Foundation

/// Alert rules and the alert log in SQLite (docs/02 §11 `alert_rule`, `alert_event`).
///
/// Uses its own connection to the app database, so it never contends with `HistoryStore`'s actor. Rules keep
/// their order (`position`). A serial in `alert_rule_set` has been configured, so an empty rule list stays empty
/// instead of being re-seeded with the defaults.
public actor SQLiteAlertStore: AlertRuleStore {
    private let db: SQLiteDatabase
    /// Last database error from a call that cannot throw (the `AlertRuleStore` methods, `record`).
    public private(set) var lastError: (any Error)?

    public init(database: sending SQLiteDatabase) throws {
        self.db = database
        try Schema.migrate(database)
    }

    /// `":memory:"` or a file path (normally the same file as `HistoryStore`).
    public init(path: String) throws {
        let database = try SQLiteDatabase(path: path)
        self.db = database
        try Schema.migrate(database)
    }

    // MARK: Rules

    public func loadRules(for serial: ProbeSerial) -> [AlertRule]? {
        do {
            let configured = try db.query("SELECT 1 FROM alert_rule_set WHERE serial=?", [.integer(Int64(serial.rawValue))])
            guard !configured.isEmpty else { return nil }
            let rows = try db.query(
                "SELECT id, kind, params_json, enabled FROM alert_rule WHERE serial=? ORDER BY position",
                [.integer(Int64(serial.rawValue))])
            return rows.compactMap { row in
                guard case .text(let id) = row[0], case .text(let kind) = row[1] else { return nil }
                let params: String? = if case .text(let p) = row[2] { p } else { nil }
                let enabled: Bool = if case .integer(let e) = row[3] { e != 0 } else { true }
                guard let k = AlertRuleCoding.decode(kind: kind, params: params) else { return nil }
                return AlertRule(id: id, kind: k, enabled: enabled)
            }
        } catch {
            lastError = error
            return nil
        }
    }

    public func saveRules(_ rules: [AlertRule], for serial: ProbeSerial) {
        let s = SQLiteValue.integer(Int64(serial.rawValue))
        do {
            try db.transaction {
                _ = try db.run("DELETE FROM alert_rule WHERE serial=?", [s])
                for (i, r) in rules.enumerated() {
                    let (kind, params) = AlertRuleCoding.encode(r.kind)
                    _ = try db.run(
                        "INSERT OR REPLACE INTO alert_rule(id, serial, kind, params_json, enabled, position) VALUES(?,?,?,?,?,?)",
                        [.text(r.id), s, .text(kind), params.map { .text($0) } ?? .null,
                         .integer(r.enabled ? 1 : 0), .integer(Int64(i))])
                }
                _ = try db.run("INSERT OR IGNORE INTO alert_rule_set(serial) VALUES(?)", [s])
            }
        } catch {
            lastError = error
        }
    }

    // MARK: Alert log

    /// Writes every engine event until the stream ends. docs/06 §11 "alerts during this cook".
    public func consume(_ events: AsyncStream<AlertEvent>) async {
        for await e in events { record(e) }
    }

    /// One row per firing: opened on `-> firing` (unless the same firing is only coming back from a snooze),
    /// acknowledged on `-> acknowledged`, closed on `-> idle`.
    public func record(_ event: AlertEvent) {
        let inst = event.instance
        let ms = { (d: Date) in SQLiteValue.integer(Int64((d.timeIntervalSince1970 * 1000).rounded())) }
        do {
            switch event.to {
            case .firing:
                if event.from == .snoozed, try openRow(inst.id) != nil { return }
                _ = try db.run(
                    "INSERT OR IGNORE INTO alert_event(id, rule_id, serial, fired_at, value) VALUES(?,?,?,?,?)",
                    [.text("\(inst.id)@\(Int64((inst.firedAt.timeIntervalSince1970 * 1000).rounded()))"),
                     .text(inst.id), .integer(Int64(inst.serial.rawValue)), ms(inst.firedAt),
                     inst.value.map { .real($0) } ?? .null])
            case .acknowledged:
                if let row = try openRow(inst.id) {
                    _ = try db.run("UPDATE alert_event SET acked_at=? WHERE id=?", [ms(event.at), .text(row)])
                }
            case .idle:
                if let row = try openRow(inst.id) {
                    _ = try db.run("UPDATE alert_event SET cleared_at=? WHERE id=?", [ms(event.at), .text(row)])
                }
            case .snoozed:
                break
            }
        } catch {
            lastError = error
        }
    }

    /// Logged alerts for a probe that fired in `range`, oldest first.
    public func events(for serial: ProbeSerial, in range: ClosedRange<Date>) throws -> [AlertLogEntry] {
        let ms = { (d: Date) in SQLiteValue.integer(Int64((d.timeIntervalSince1970 * 1000).rounded())) }
        let rows = try db.query(
            "SELECT rule_id, fired_at, acked_at, cleared_at, value FROM alert_event WHERE serial=? AND fired_at BETWEEN ? AND ? ORDER BY fired_at",
            [.integer(Int64(serial.rawValue)), ms(range.lowerBound), ms(range.upperBound)])
        func date(_ v: SQLiteValue) -> Date? {
            if case .integer(let i) = v { return Date(timeIntervalSince1970: Double(i) / 1000) }
            return nil
        }
        return rows.compactMap { r in
            guard case .text(let id) = r[0], let fired = date(r[1]) else { return nil }
            let value: Double? = if case .real(let v) = r[4] { v } else { nil }
            return AlertLogEntry(alertId: id, serial: serial, firedAt: fired, acknowledgedAt: date(r[2]),
                                 clearedAt: date(r[3]), value: value)
        }
    }

    private func openRow(_ alertId: String) throws -> String? {
        let rows = try db.query(
            "SELECT id FROM alert_event WHERE rule_id=? AND cleared_at IS NULL ORDER BY fired_at DESC LIMIT 1",
            [.text(alertId)])
        if case .text(let id)? = rows.first?.first { return id }
        return nil
    }
}

/// One logged firing of an alert.
public struct AlertLogEntry: Sendable, Equatable {
    /// The alert instance id: a rule id, `<serial>.alarm.<high|low>.<channel>` or `<serial>.overheat.<sensor>`.
    public var alertId: String
    public var serial: ProbeSerial
    public var firedAt: Date
    public var acknowledgedAt: Date?
    public var clearedAt: Date?
    public var value: Double?
}

/// `AlertRuleKind` <-> (`kind`, `params_json`) columns.
enum AlertRuleCoding {
    private struct Params: Codable, Equatable {
        var channel: Int?
        var celsius: Double?
        var hysteresis: Double?
        var seconds: Double?
        var min: Double?
        var max: Double?
        var sustain: Double?
        var window: Double?
        var minRise: Double?
        var onlyDuringCook: Bool?
    }

    static func encode(_ kind: AlertRuleKind) -> (String, String?) {
        let p: Params?
        let name: String
        switch kind {
        case .temperatureAbove(let ch, let c, let h):
            name = "temperatureAbove"; p = Params(channel: ch.rawValue, celsius: c, hysteresis: h)
        case .temperatureBelow(let ch, let c, let h):
            name = "temperatureBelow"; p = Params(channel: ch.rawValue, celsius: c, hysteresis: h)
        case .predictionWithin(let s):
            name = "predictionWithin"; p = Params(seconds: Double(s))
        case .predictionDone:
            name = "predictionDone"; p = nil
        case .restingDone:
            name = "restingDone"; p = nil
        case .ambientOutOfRange(let lo, let hi, let s):
            name = "ambientOutOfRange"; p = Params(min: lo, max: hi, sustain: s)
        case .stall(let w, let r):
            name = "stall"; p = Params(window: w, minRise: r)
        case .probeOffline(let s, let only):
            name = "probeOffline"; p = Params(seconds: s, onlyDuringCook: only)
        case .batteryLow:
            name = "batteryLow"; p = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = p.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
        return (name, json)
    }

    static func decode(kind: String, params: String?) -> AlertRuleKind? {
        let p = params.flatMap { try? JSONDecoder().decode(Params.self, from: Data($0.utf8)) } ?? Params()
        switch kind {
        case "temperatureAbove", "temperatureBelow":
            guard let raw = p.channel, let ch = AlarmChannel(rawValue: raw), let c = p.celsius else { return nil }
            return kind == "temperatureAbove"
                ? .temperatureAbove(channel: ch, celsius: c, hysteresis: p.hysteresis ?? 1)
                : .temperatureBelow(channel: ch, celsius: c, hysteresis: p.hysteresis ?? 1)
        case "predictionWithin":
            guard let s = p.seconds else { return nil }
            return .predictionWithin(seconds: Int(s))
        case "predictionDone": return .predictionDone
        case "restingDone": return .restingDone
        case "ambientOutOfRange":
            guard let lo = p.min, let hi = p.max else { return nil }
            return .ambientOutOfRange(min: lo, max: hi, sustain: p.sustain ?? 0)
        case "stall":
            guard let r = p.minRise else { return nil }
            return .stall(window: p.window ?? 1800, minRise: r)
        case "probeOffline":
            return .probeOffline(seconds: p.seconds ?? 60, onlyDuringCook: p.onlyDuringCook ?? false)
        case "batteryLow": return .batteryLow
        default: return nil
        }
    }
}
