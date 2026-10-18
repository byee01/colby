/// docs/02 §11 with `t1..t8` expanded.
public enum Schema {
    public static let migrations: [Migration] = [
        Migration(version: 1, sql: """
        CREATE TABLE probe(
            serial INTEGER PRIMARY KEY, nickname TEXT, followed INTEGER, last_seen INTEGER);
        CREATE TABLE session(
            id INTEGER PRIMARY KEY, serial INTEGER, session_id INTEGER, sample_period_ms INTEGER,
            started_at INTEGER, ended_at INTEGER, anchor_seq INTEGER, anchor_time INTEGER, nickname TEXT,
            kind TEXT, ready_since INTEGER, thumbnail BLOB,
            UNIQUE(serial, session_id, started_at));
        CREATE TABLE sample(
            session INTEGER, seq INTEGER,
            t1 REAL, t2 REAL, t3 REAL, t4 REAL, t5 REAL, t6 REAL, t7 REAL, t8 REAL,
            vs INTEGER, pred_state INTEGER, pred_mode INTEGER, pred_type INTEGER,
            setpoint REAL, pred_seconds INTEGER, est_core REAL,
            PRIMARY KEY(session, seq)) WITHOUT ROWID;
        CREATE TABLE alert_rule(
            id TEXT PRIMARY KEY, serial INTEGER, kind TEXT, params_json TEXT, enabled INTEGER);
        CREATE TABLE alert_event(
            id TEXT PRIMARY KEY, rule_id TEXT, serial INTEGER, session INTEGER, fired_at INTEGER,
            cleared_at INTEGER, acked_at INTEGER, value REAL);
        """),
        // Alert rules keep their order; a serial in alert_rule_set has been configured (even if it now has no rules).
        Migration(version: 2, sql: """
        ALTER TABLE alert_rule ADD COLUMN position INTEGER NOT NULL DEFAULT 0;
        CREATE TABLE alert_rule_set(serial INTEGER PRIMARY KEY);
        CREATE INDEX alert_event_open ON alert_event(rule_id, cleared_at);
        CREATE INDEX alert_event_serial ON alert_event(serial, fired_at);
        """),
    ]

    public static func migrate(_ db: SQLiteDatabase) throws {
        try db.migrate(migrations)
    }
}
