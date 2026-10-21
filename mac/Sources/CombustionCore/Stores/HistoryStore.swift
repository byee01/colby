import CombustionCodec
import Foundation

/// Persistent cooks: sessions, log samples, time derivation, backfill. docs/02 §6.3, §11.
///
/// Owns the SQLite database (confined to this actor). Samples are keyed `(session row, seq)` and inserted
/// with `INSERT OR IGNORE`, so every path (live fetch, backfill, re-delivery) is idempotent. Times are never
/// stored: they are derived on read from the session's latest anchor `(seq = logRange.max, time = receivedAt)`.
public actor HistoryStore {
    /// Used when a status carries no sample period (old firmware). The probe logs every 5 s by default.
    public static let defaultSamplePeriodMs: Int64 = 5000
    /// `valueAt` interpolates only between stored neighbours at most this many seqs apart.
    public static let maxInterpolationGap: UInt32 = 12

    private let db: SQLiteDatabase
    private let clock: any Clock
    private var logFetcher: (any LogFetcher)?

    private struct Runtime {
        var tracker: SessionTracker
        var rowId: Int64?
        var lastStatusAt: Date
    }

    private var runtime: [ProbeSerial: Runtime] = [:]
    private var lastRanges: [Int64: LogRange] = [:]
    private var seriesBroadcasters: [Int64: Broadcaster<TemperatureSeries>] = [:]
    private var liveRunning: Set<Int64> = []
    private var livePending: [Int64: LogRange] = [:]
    private var backfilling: Set<Int64> = []

    /// Log downloads running right now (live fetches plus backfills), for diagnostics.
    public var fetchesInFlight: Int { liveRunning.count + backfilling.count }

    /// Last database error from `consume`.
    public private(set) var lastError: (any Error)?

    public init(database: sending SQLiteDatabase, clock: any Clock, logFetcher: (any LogFetcher)? = nil) throws {
        self.db = database
        self.clock = clock
        self.logFetcher = logFetcher
        try Schema.migrate(database)
    }

    /// `":memory:"` or a file path.
    public init(path: String, clock: any Clock, logFetcher: (any LogFetcher)? = nil) throws {
        let database = try SQLiteDatabase(path: path)
        self.db = database
        self.clock = clock
        self.logFetcher = logFetcher
        try Schema.migrate(database)
    }

    /// Default fetcher for live record fetches (direct or node link). Replace as links come and go.
    public func setLogFetcher(_ fetcher: (any LogFetcher)?) { logFetcher = fetcher }

    // MARK: - Status ingest

    /// Consumes `ProbeStore.statusEvents` until the stream ends.
    public func consume(_ events: AsyncStream<ProbeStatusEvent>) async {
        for await e in events {
            do { try await ingest(status: e) } catch { lastError = error }
        }
    }

    /// Handles one full status: session detection, anchors, kind, ready-since, then (if `logRange.max`
    /// advanced) fetches the new records through `fetcher` (default: the store's fetcher).
    /// Returns the session the status belongs to.
    @discardableResult
    public func ingest(status event: ProbeStatusEvent, using fetcher: (any LogFetcher)? = nil) async throws -> SessionKey {
        let (key, rowId) = try record(event)
        // A Normal status is the record at `logRange.max` (iOS SDK `addDataToLog`), so it is stored as one and
        // never requested. Instant Read statuses carry only T1.
        if event.status.mode != .instantRead, try insert([Self.logRecord(event.status)], rowId: rowId) > 0 {
            publishSeries(rowId)
        }
        if let f = fetcher ?? logFetcher {
            await liveFetch(serial: event.serial, rowId: rowId, range: event.status.logRange, fetcher: f)
        }
        return key
    }

    private func record(_ event: ProbeStatusEvent) throws -> (SessionKey, Int64) {
        let serial = event.serial
        let status = event.status
        let sessionId = status.session?.sessionId ?? 0
        let at = event.receivedAt
        var rt = try runtime[serial] ?? restore(serial, fallbackTime: at)
        let decision = rt.tracker.observe(sessionId: sessionId, logRange: status.logRange, at: at)
        let periodMs = status.session.map { Int64($0.samplePeriodMs) }
        let predictive = status.prediction.mode != .none && status.prediction.mode != .reserved

        let rowId: Int64 = try db.transaction {
            var rowId = rt.rowId
            if case .newSession = decision, let old = rowId {
                try endSession(rowId: old, at: rt.lastStatusAt)
                rowId = nil
            }
            if case .adoptedSessionId(let id) = decision, let r = rowId {
                try db.run("UPDATE session SET session_id=? WHERE id=?", [.integer(Int64(id)), .integer(r)])
            }
            if rowId == nil {
                try db.run("""
                    INSERT INTO session(serial, session_id, sample_period_ms, started_at, ended_at, anchor_seq,
                                        anchor_time, nickname, kind, ready_since, thumbnail)
                    VALUES(?,?,?,?,NULL,?,?,NULL,?,NULL,NULL)
                    """, [.integer(Int64(serial.rawValue)), .integer(Int64(sessionId)),
                          .integer(periodMs ?? Self.defaultSamplePeriodMs), .integer(Self.ms(at)),
                          .integer(Int64(status.logRange.max)), .integer(Self.ms(at)),
                          .text((predictive ? SessionKind.predictive : .manual).rawValue)])
                rowId = db.lastInsertRowId
            } else {
                // Re-anchor (never backwards in time).
                try db.run("""
                    UPDATE session SET anchor_seq=?, anchor_time=?
                    WHERE id=? AND anchor_time<=?
                    """, [.integer(Int64(status.logRange.max)), .integer(Self.ms(at)), .integer(rowId!), .integer(Self.ms(at))])
                if let periodMs {
                    try db.run("UPDATE session SET sample_period_ms=? WHERE id=?", [.integer(periodMs), .integer(rowId!)])
                }
                if predictive {
                    try db.run("UPDATE session SET kind='predictive' WHERE id=?", [.integer(rowId!)])
                }
            }
            let id = rowId!
            switch status.prediction.state {
            case .removalPredictionDone:
                try db.run("UPDATE session SET ready_since=? WHERE id=? AND ready_since IS NULL", [.integer(Self.ms(at)), .integer(id)])
            case .notInserted, .inserted, .warming, .predicting:
                try db.run("UPDATE session SET ready_since=NULL WHERE id=? AND ready_since IS NOT NULL", [.integer(id)])
            case .unknown:
                break
            }
            try db.run("""
                INSERT INTO probe(serial, followed, last_seen) VALUES(?,0,?)
                ON CONFLICT(serial) DO UPDATE SET last_seen=excluded.last_seen
                """, [.integer(Int64(serial.rawValue)), .integer(Self.ms(at))])
            return id
        }

        let isLatest = at >= rt.lastStatusAt
        rt.rowId = rowId
        rt.lastStatusAt = max(rt.lastStatusAt, at)
        runtime[serial] = rt
        if isLatest || lastRanges[rowId] == nil { lastRanges[rowId] = status.logRange }
        publishSeries(rowId)
        let row = try loadRow(rowId)!
        return (row.key, rowId)
    }

    /// Latest open session of `serial` becomes the tracker's current session.
    private func restore(_ serial: ProbeSerial, fallbackTime: Date) throws -> Runtime {
        let rows = try db.query("""
            SELECT \(SessionRow.columns) FROM session WHERE serial=? ORDER BY started_at DESC, id DESC LIMIT 1
            """, [.integer(Int64(serial.rawValue))])
        if let r = rows.first.flatMap(SessionRow.init), r.endedAt == nil {
            let seen = Self.date(r.anchorTime)
            return Runtime(tracker: SessionTracker(restoring: r.sessionId, logRange: LogRange(min: 0, max: r.anchorSeq), lastSeen: seen),
                           rowId: r.id, lastStatusAt: seen)
        }
        return Runtime(tracker: SessionTracker(), rowId: nil, lastStatusAt: fallbackTime)
    }

    private func endSession(rowId: Int64, at: Date) throws {
        let samples = try loadSamples(rowId)
        let thumb = Thumbnail.make(from: samples)
        try db.run("""
            UPDATE session SET ended_at=?, thumbnail=? WHERE id=? AND ended_at IS NULL
            """, [.integer(Self.ms(at)), thumb.isEmpty ? .null : .blob(Thumbnail.encode(thumb)), .integer(rowId)])
    }

    /// Closes the open session of `serial` (ended_at, thumbnail). The next status starts a new session.
    public func endCurrentSession(of serial: ProbeSerial, at time: Date? = nil) throws {
        guard let rt = runtime[serial], let rowId = rt.rowId else { return }
        try endSession(rowId: rowId, at: time ?? rt.lastStatusAt)
        runtime[serial] = Runtime(tracker: SessionTracker(), rowId: nil, lastStatusAt: rt.lastStatusAt)
        publishSeries(rowId)
    }

    /// The open session of `serial`, if any.
    public func currentSession(of serial: ProbeSerial) throws -> SessionKey? {
        guard let id = runtime[serial]?.rowId else { return nil }
        return try loadRow(id)?.key
    }

    // MARK: - Live fetch and backfill

    /// Highest stored seq below `limit`.
    private func maxStoredSeq(_ rowId: Int64, below limit: UInt32) throws -> UInt32? {
        if case .integer(let v)? = try db.query("SELECT MAX(seq) FROM sample WHERE session=? AND seq<?",
                                                [.integer(rowId), .integer(Int64(limit))]).first?.first {
            return UInt32(v)
        }
        return nil
    }

    private func hasSeq(_ rowId: Int64, _ seq: UInt32) throws -> Bool {
        try !db.query("SELECT 1 FROM sample WHERE session=? AND seq=?", [.integer(rowId), .integer(Int64(seq))]).isEmpty
    }

    private static func logRecord(_ status: ProbeStatusPayload) -> LogRecord {
        let p = status.prediction
        return LogRecord(
            sequence: status.logRange.max, temperatures: status.temperatures,
            prediction: PredictionLog(virtualSensors: status.virtualSensors, state: p.state, mode: p.mode, type: p.type,
                                      setpoint: p.setpoint, rawSecondsRemaining: p.rawSecondsRemaining,
                                      estimatedCore: p.estimatedCore))
    }

    private func liveFetch(serial: ProbeSerial, rowId: Int64, range: LogRange, fetcher: any LogFetcher) async {
        if liveRunning.contains(rowId) {
            livePending[rowId] = range
            return
        }
        liveRunning.insert(rowId)
        defer { liveRunning.remove(rowId) }
        var target = range
        while true {
            // New seqs since the last stored one below the newest (usually stored from the status itself),
            // at most one chunk; older holes are backfill's job.
            let end = Int64(target.max) - ((try? hasSeq(rowId, target.max)) == true ? 1 : 0)
            let stored = (try? maxStoredSeq(rowId, below: target.max)) ?? nil
            let from = stored.map { Int64($0) + 1 } ?? Int64(target.min)
            let start = max(from, end - Int64(BackfillPlanner.defaultChunkSize) + 1, Int64(target.min))
            guard start <= end else { break }
            _ = await fetchChunk(serial: serial, rowId: rowId, UInt32(start)...UInt32(end), fetcher: fetcher)
            if let p = livePending.removeValue(forKey: rowId), p.max > target.max {
                target = p
            } else {
                break
            }
        }
        livePending[rowId] = nil
    }

    /// Fills holes in a session's log, newest chunk first, 128 records per request. Partial results are kept;
    /// holes that remain are retried by the next call. Stops at the first fetcher error (e.g. link lost).
    /// `range` defaults to the log range of the session's latest status.
    @discardableResult
    public func backfill(_ session: SessionKey, using fetcher: any LogFetcher, range: LogRange? = nil) async -> BackfillResult {
        guard let rowId = try? rowId(for: session), let range = range ?? lastRanges[rowId] else {
            return BackfillResult(requested: 0, received: 0, remaining: 0, failed: false)
        }
        guard backfilling.insert(rowId).inserted else {
            return BackfillResult(requested: 0, received: 0, remaining: 0, failed: false)
        }
        defer { backfilling.remove(rowId) }

        let existing = (try? seqs(rowId, in: range)) ?? []
        let chunks = BackfillPlanner.plan(existing: existing, range: range)
        var requested = 0, received = 0, failed = false
        for chunk in chunks {
            if Task.isCancelled { failed = true; break }
            requested += Int(chunk.upperBound - chunk.lowerBound) + 1
            let (got, error) = await fetchChunk(serial: session.serial, rowId: rowId, chunk, fetcher: fetcher)
            received += got
            if error != nil { failed = true; break }
        }
        let remaining = ((try? seqs(rowId, in: range)).map {
            BackfillPlanner.plan(existing: $0, range: range).reduce(0) { $0 + Int($1.upperBound - $1.lowerBound) + 1 }
        }) ?? 0
        return BackfillResult(requested: requested, received: received, remaining: remaining, failed: failed)
    }

    /// Reads one range, inserts what arrived (even if the stream failed), publishes the series.
    private func fetchChunk(serial: ProbeSerial, rowId: Int64, _ range: ClosedRange<UInt32>,
                            fetcher: any LogFetcher) async -> (inserted: Int, error: (any Error)?) {
        var records: [LogRecord] = []
        var failure: (any Error)?
        do {
            for try await r in fetcher.readLogs(probe: serial, start: range.lowerBound, end: range.upperBound)
            where range.contains(r.sequence) {
                records.append(r)
            }
        } catch {
            failure = error
        }
        let inserted = (try? insert(records, rowId: rowId)) ?? 0
        if inserted > 0 { publishSeries(rowId) }
        return (inserted, failure)
    }

    private func insert(_ records: [LogRecord], rowId: Int64) throws -> Int {
        guard !records.isEmpty else { return 0 }
        return try db.transaction {
            let stmt = try db.prepare("""
                INSERT OR IGNORE INTO sample(session, seq, t1,t2,t3,t4,t5,t6,t7,t8, vs, pred_state, pred_mode,
                                             pred_type, setpoint, pred_seconds, est_core)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """)
            var inserted = 0
            var predictive = false
            for r in records {
                let p = r.prediction
                let vs = p.virtualSensors
                var params: [SQLiteValue] = [.integer(rowId), .integer(Int64(r.sequence))]
                params += r.temperatures.celsius.map { .real($0) }
                params += [
                    .integer(Int64(vs.core.rawValue) | Int64(vs.surface.rawValue - 3) << 3 | Int64(vs.ambient.rawValue - 4) << 5),
                    .integer(Int64(Self.stateCode(p.state))), .integer(Int64(p.mode.rawValue)),
                    .integer(Int64(p.type.rawValue)), .real(p.setpoint), .integer(Int64(p.rawSecondsRemaining)),
                    .real(p.estimatedCore),
                ]
                try stmt.bind(params)
                while try stmt.step() {}
                try stmt.reset()
                inserted += db.changes
                if p.mode != .none && p.mode != .reserved { predictive = true }
            }
            if predictive { try db.run("UPDATE session SET kind='predictive' WHERE id=?", [.integer(rowId)]) }
            return inserted
        }
    }

    private func seqs(_ rowId: Int64, in range: LogRange) throws -> [UInt32] {
        try db.query("SELECT seq FROM sample WHERE session=? AND seq BETWEEN ? AND ?",
                     [.integer(rowId), .integer(Int64(range.min)), .integer(Int64(range.max))])
            .compactMap { if case .integer(let v) = $0[0] { UInt32(v) } else { nil } }
    }

    // MARK: - Reads

    /// Summaries, newest first.
    public func sessions(serial: ProbeSerial? = nil) throws -> [SessionSummary] {
        let rows: [[SQLiteValue]]
        if let serial {
            rows = try db.query("SELECT \(SessionRow.columns) FROM session WHERE serial=? ORDER BY started_at DESC, id DESC",
                                [.integer(Int64(serial.rawValue))])
        } else {
            rows = try db.query("SELECT \(SessionRow.columns) FROM session ORDER BY started_at DESC, id DESC")
        }
        return try rows.compactMap(SessionRow.init).map(summary)
    }

    private func summary(_ r: SessionRow) throws -> SessionSummary {
        let agg = try db.query("""
            SELECT COUNT(*), MAX(\(Self.coreExpr)) FROM sample WHERE session=?
            """, [.integer(r.id)])[0]
        var count = 0
        if case .integer(let c) = agg[0] { count = Int(c) }
        var peak: Double?
        if case .real(let p) = agg[1] { peak = p }
        var setpoint: Double?
        if case .real(let s)? = try db.query("SELECT setpoint FROM sample WHERE session=? AND pred_mode<>0 ORDER BY seq DESC LIMIT 1",
                                             [.integer(r.id)]).first?.first {
            setpoint = s
        }
        var thumb: [ThumbnailPoint] = r.thumbnail.map(Thumbnail.decode) ?? []
        if thumb.isEmpty, r.endedAt == nil, count > 0 {
            thumb = Thumbnail.make(from: try loadSamples(r.id))
        }
        return SessionSummary(
            key: r.key, start: Self.date(r.startedAt), end: r.endedAt.map(Self.date), peakCore: peak,
            setpoint: setpoint, kind: r.kind, nickname: r.nickname, sampleCount: count,
            samplePeriod: Double(r.samplePeriodMs) / 1000, readySince: r.readySince.map(Self.date), thumbnail: thumb)
    }

    public func sampleCount(_ session: SessionKey) throws -> Int {
        guard let id = try rowId(for: session) else { return 0 }
        if case .integer(let c)? = try db.query("SELECT COUNT(*) FROM sample WHERE session=?", [.integer(id)]).first?.first { return Int(c) }
        return 0
    }

    /// One-shot series (times derived now from the latest anchor).
    public func currentSeries(_ session: SessionKey) throws -> TemperatureSeries? {
        guard let id = try rowId(for: session) else { return nil }
        return try buildSeries(id)
    }

    /// Series as an observable: latest value first, then a new value whenever samples or the anchor change.
    /// Finishes when the session is deleted. Unknown sessions give an empty, finished stream.
    public func series(_ session: SessionKey) -> AsyncStream<TemperatureSeries> {
        guard let id = (try? rowId(for: session)) ?? nil else {
            return AsyncStream { $0.finish() }
        }
        if let b = seriesBroadcasters[id] { return b.stream() }
        let b = Broadcaster<TemperatureSeries>(replayLatest: true)
        seriesBroadcasters[id] = b
        if let s = try? buildSeries(id) { b.send(s) }
        return b.stream()
    }

    public func rename(_ session: SessionKey, nickname: String?) throws {
        guard let id = try rowId(for: session) else { return }
        try db.run("UPDATE session SET nickname=? WHERE id=?", [nickname.map { .text($0) } ?? .null, .integer(id)])
    }

    public func delete(_ session: SessionKey) throws {
        guard let id = try rowId(for: session) else { return }
        try db.transaction {
            try db.run("DELETE FROM sample WHERE session=?", [.integer(id)])
            try db.run("DELETE FROM session WHERE id=?", [.integer(id)])
        }
        for (serial, rt) in runtime where rt.rowId == id { runtime[serial]?.rowId = nil }
        lastRanges[id] = nil
        seriesBroadcasters.removeValue(forKey: id)?.finish()
    }

    /// Scrub readout at `time`: core, surface, ambient (linearly interpolated between stored neighbours
    /// at most `maxInterpolationGap` seqs apart, else the nearest sample) and the nearest sample's
    /// prediction. nil if the session has no samples or `time` is more than half a period outside them.
    public func valueAt(_ session: SessionKey, time: Date) throws -> SessionValue? {
        guard let r = try loadRow(try rowId(for: session) ?? -1) else { return nil }
        let period = Double(r.samplePeriodMs) / 1000
        let anchorTime = Self.date(r.anchorTime)
        let pos = TimeDerivation.seq(at: time, anchorSeq: r.anchorSeq, anchorTime: anchorTime, samplePeriod: period)
        let fl = Int64(pos.rounded(.down)), ce = Int64(pos.rounded(.up))
        let lower = try db.query("SELECT \(Self.sampleColumns) FROM sample WHERE session=? AND seq<=? ORDER BY seq DESC LIMIT 1",
                                 [.integer(r.id), .integer(fl)]).first.flatMap { Self.decodeSample($0, row: r) }
        let upper = try db.query("SELECT \(Self.sampleColumns) FROM sample WHERE session=? AND seq>=? ORDER BY seq ASC LIMIT 1",
                                 [.integer(r.id), .integer(ce)]).first.flatMap { Self.decodeSample($0, row: r) }
        guard let near = [lower, upper].compactMap({ $0 }).min(by: { abs(Double($0.seq) - pos) < abs(Double($1.seq) - pos) })
        else { return nil }
        guard abs(Double(near.seq) - pos) <= 0.5 || (lower != nil && upper != nil) else { return nil }
        if let a = lower, let b = upper, a.seq != b.seq, b.seq - a.seq <= Self.maxInterpolationGap {
            let f = min(1, max(0, (pos - Double(a.seq)) / Double(b.seq - a.seq)))
            return SessionValue(time: time, seq: near.seq,
                                core: a.core + (b.core - a.core) * f, surface: a.surface + (b.surface - a.surface) * f,
                                ambient: a.ambient + (b.ambient - a.ambient) * f, prediction: near.prediction)
        }
        return SessionValue(time: time, seq: near.seq, core: near.core, surface: near.surface,
                            ambient: near.ambient, prediction: near.prediction)
    }

    // MARK: - Internals

    private func publishSeries(_ rowId: Int64) {
        guard let b = seriesBroadcasters[rowId], let s = try? buildSeries(rowId) else { return }
        b.send(s)
    }

    private func buildSeries(_ rowId: Int64) throws -> TemperatureSeries? {
        guard let r = try loadRow(rowId) else { return nil }
        return TemperatureSeries(key: r.key, samplePeriod: Double(r.samplePeriodMs) / 1000, anchorSeq: r.anchorSeq,
                                 anchorTime: Self.date(r.anchorTime), samples: try loadSamples(rowId, row: r))
    }

    private func loadSamples(_ rowId: Int64) throws -> [TemperatureSample] {
        guard let r = try loadRow(rowId) else { return [] }
        return try loadSamples(rowId, row: r)
    }

    private func loadSamples(_ rowId: Int64, row r: SessionRow) throws -> [TemperatureSample] {
        let stmt = try db.prepare("SELECT \(Self.sampleColumns) FROM sample WHERE session=? ORDER BY seq")
        try stmt.bind([.integer(rowId)])
        var out: [TemperatureSample] = []
        while try stmt.step() {
            if let s = Self.decodeSample(stmt.row(), row: r) { out.append(s) }
        }
        return out
    }

    private func loadRow(_ id: Int64) throws -> SessionRow? {
        try db.query("SELECT \(SessionRow.columns) FROM session WHERE id=?", [.integer(id)]).first.flatMap(SessionRow.init)
    }

    private func rowId(for key: SessionKey) throws -> Int64? {
        let rows = try db.query("SELECT id FROM session WHERE serial=? AND session_id=? AND started_at=?",
                                [.integer(Int64(key.serial.rawValue)), .integer(Int64(key.sessionId)), .integer(key.startedAtMs)])
        if case .integer(let v)? = rows.first?.first { return v }
        return nil
    }

    static let coreExpr = """
        CASE (vs & 7) WHEN 1 THEN t2 WHEN 2 THEN t3 WHEN 3 THEN t4 WHEN 4 THEN t5 WHEN 5 THEN t6 ELSE t1 END
        """

    static let sampleColumns = "seq,t1,t2,t3,t4,t5,t6,t7,t8,vs,pred_state,pred_mode,pred_type,setpoint,pred_seconds,est_core"

    private static func decodeSample(_ c: [SQLiteValue], row r: SessionRow) -> TemperatureSample? {
        func i(_ k: Int) -> Int64 { if case .integer(let v) = c[k] { v } else { 0 } }
        func d(_ k: Int) -> Double {
            switch c[k] {
            case .real(let v): v
            case .integer(let v): Double(v)
            default: 0
            }
        }
        let bits = i(9)
        let core = SensorIndex(rawValue: UInt8(bits & 7)) ?? .t1
        guard let vs = try? VirtualSensors(
            core: core.rawValue <= SensorIndex.t6.rawValue ? core : .t1,
            surface: SensorIndex(rawValue: UInt8((bits >> 3) & 3) + 3) ?? .t4,
            ambient: SensorIndex(rawValue: UInt8((bits >> 5) & 3) + 4) ?? .t5) else { return nil }
        let seq = UInt32(i(0))
        let prediction = PredictionLog(
            virtualSensors: vs, state: stateFrom(Int(i(10))),
            mode: PredictionMode(rawValue: UInt8(i(11))) ?? .none, type: PredictionType(rawValue: UInt8(i(12))) ?? .none,
            setpoint: d(13), rawSecondsRemaining: UInt32(i(14)), estimatedCore: d(15))
        return TemperatureSample(
            seq: seq,
            time: TimeDerivation.time(seq: seq, anchorSeq: r.anchorSeq, anchorTime: date(r.anchorTime),
                                      samplePeriod: Double(r.samplePeriodMs) / 1000),
            temperatures: (1...8).map { d($0) }, virtualSensors: vs, prediction: prediction)
    }

    static func stateCode(_ s: PredictionState) -> Int {
        switch s {
        case .notInserted: 0
        case .inserted: 1
        case .warming: 2
        case .predicting: 3
        case .removalPredictionDone: 4
        case .unknown: 15
        }
    }

    static func stateFrom(_ n: Int) -> PredictionState {
        switch n {
        case 0: .notInserted
        case 1: .inserted
        case 2: .warming
        case 3: .predicting
        case 4: .removalPredictionDone
        default: .unknown
        }
    }

    static func ms(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: Double(ms) / 1000) }

    private struct SessionRow {
        static let columns = "id,serial,session_id,sample_period_ms,started_at,ended_at,anchor_seq,anchor_time,nickname,kind,ready_since,thumbnail"
        var id: Int64
        var serial: ProbeSerial
        var sessionId: UInt32
        var samplePeriodMs: Int64
        var startedAt: Int64
        var endedAt: Int64?
        var anchorSeq: UInt32
        var anchorTime: Int64
        var nickname: String?
        var kind: SessionKind
        var readySince: Int64?
        var thumbnail: [UInt8]?

        var key: SessionKey { SessionKey(serial: serial, sessionId: sessionId, startedAtMs: startedAt) }

        init?(_ c: [SQLiteValue]) {
            func i(_ k: Int) -> Int64? { if case .integer(let v) = c[k] { v } else { nil } }
            guard let id = i(0), let serial = i(1), let sid = i(2), let started = i(4) else { return nil }
            self.id = id
            self.serial = ProbeSerial(UInt32(serial))
            sessionId = UInt32(sid)
            let period = i(3) ?? HistoryStore.defaultSamplePeriodMs
            samplePeriodMs = period > 0 ? period : HistoryStore.defaultSamplePeriodMs
            startedAt = started
            endedAt = i(5)
            anchorSeq = UInt32(i(6) ?? 0)
            anchorTime = i(7) ?? started
            if case .text(let n) = c[8] { nickname = n }
            if case .text(let k) = c[9] { kind = SessionKind(rawValue: k) ?? .manual } else { kind = .manual }
            readySince = i(10)
            if case .blob(let b) = c[11] { thumbnail = b }
        }
    }
}

public struct BackfillResult: Sendable, Equatable {
    /// Records asked for.
    public var requested: Int
    /// New records stored.
    public var received: Int
    /// Seqs in the log range still missing afterwards.
    public var remaining: Int
    /// A fetch threw (link lost) or the task was cancelled; the rest was not attempted.
    public var failed: Bool

    public init(requested: Int, received: Int, remaining: Int, failed: Bool) {
        self.requested = requested
        self.received = received
        self.remaining = remaining
        self.failed = failed
    }
}

extension HistoryStore: FollowedProbePersistence {
    public func loadFollowed() async throws -> Set<ProbeSerial> {
        let rows = try db.query("SELECT serial FROM probe WHERE followed=1")
        return Set(rows.compactMap { if case .integer(let v) = $0[0] { ProbeSerial(UInt32(v)) } else { nil } })
    }

    public func setFollowed(_ serial: ProbeSerial, _ followed: Bool) async throws {
        try db.run("""
            INSERT INTO probe(serial, followed) VALUES(?,?)
            ON CONFLICT(serial) DO UPDATE SET followed=excluded.followed
            """, [.integer(Int64(serial.rawValue)), .integer(followed ? 1 : 0)])
    }
}
