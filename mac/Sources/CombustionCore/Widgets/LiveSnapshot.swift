import CombustionCodec
import Foundation

/// What widgets read (docs/02 §18, 06 §17.2): one small JSON file in a shared container. macOS: the App Group
/// container read by the WidgetKit extension; Windows: the package's LocalState read by the widget provider.
public struct LiveSnapshot: Codable, Sendable, Equatable {
    public struct Probe: Codable, Sendable, Equatable {
        /// 8-character hex serial.
        public var serial: String
        public var number: Int
        /// Cook nickname, if any; widgets fall back to "Probe <number>".
        public var name: String?
        /// °C; the widget formats units and clock from the OS and the app's units setting.
        public var core: Double?
        public var target: Double?
        /// `PredictionState` name: notInserted, inserted, warming, predicting, removalPredictionDone, unknown.
        public var state: String
        public var secondsRemaining: UInt32?
        /// Completion time; widgets tick the countdown from this with a self-updating timer text.
        public var readyAt: Date?
        public var readySince: Date?
        public var isOffline: Bool
        public var isStale: Bool
        /// Up to the last 30 core readings in °C, oldest first, for the trend line.
        public var trend: [Double]
    }

    public var writtenAt: Date
    /// Soonest finish first: predicting by `readyAt`, then ready, then the rest by probe number.
    public var probes: [Probe]
}

/// Where the snapshot goes.
public protocol LiveSnapshotWriting: Sendable {
    func write(_ data: Data) async throws
}

/// Writes atomically to a file URL, so a widget never reads half a file.
public struct FileLiveSnapshotWriter: LiveSnapshotWriting {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func write(_ data: Data) async throws {
        try data.write(to: url, options: .atomic)
    }
}

/// Builds `LiveSnapshot` from the stores and writes it at most every `minInterval`, and at once when
/// something a widget shows as a state changes (prediction state, offline, stale, the probe set).
public actor LiveSnapshotWriter {
    public static let trendLength = 30

    private let clock: any Clock
    private let writer: any LiveSnapshotWriting
    private let minInterval: Duration

    private var snapshots: [ProbeSerial: ProbeSnapshot] = [:]
    private var predictions: [ProbeSerial: PredictionView] = [:]
    private var followed: Set<ProbeSerial> = []
    private var names: [ProbeSerial: String] = [:]
    private var trends: [ProbeSerial: [Double]] = [:]
    private var lastTrendAt: [ProbeSerial: Date] = [:]

    private var lastWrite: Duration?
    private var lastStateKey: [String] = []
    private var pending: Task<Void, Never>?
    private var inputs: [Task<Void, Never>] = []

    /// Snapshots written so far, newest last (for tests and diagnostics).
    public private(set) var written: [LiveSnapshot] = []
    public private(set) var lastError: (any Error)?

    public init(clock: any Clock, writer: any LiveSnapshotWriting, minInterval: Duration = .seconds(5)) {
        self.clock = clock
        self.writer = writer
        self.minInterval = minInterval
    }

    public func start(
        probes: AsyncStream<[ProbeSerial: ProbeSnapshot]>, predictions: AsyncStream<PredictionUpdate>,
        followed: AsyncStream<Set<ProbeSerial>>
    ) {
        guard inputs.isEmpty else { return }
        inputs.append(Task { [weak self] in for await m in probes { await self?.ingest(snapshots: m) } })
        inputs.append(Task { [weak self] in for await u in predictions { await self?.ingest(prediction: u.view) } })
        inputs.append(Task { [weak self] in for await f in followed { await self?.setFollowed(f) } })
    }

    public func stop() {
        for t in inputs { t.cancel() }
        inputs = []
        pending?.cancel()
        pending = nil
    }

    public func setName(_ name: String?, for serial: ProbeSerial) async {
        names[serial] = name
        await changed()
    }

    public func setFollowed(_ set: Set<ProbeSerial>) async {
        followed = set
        await changed()
    }

    public func ingest(snapshots map: [ProbeSerial: ProbeSnapshot]) async {
        let now = clock.now()
        for (serial, snap) in map where followed.contains(serial) {
            snapshots[serial] = snap
            // One trend point per probe sample period at most (5 s), not per advertisement.
            if let core = snap.virtual.core, !snap.isOffline,
               lastTrendAt[serial].map({ now.timeIntervalSince($0) >= 5 }) ?? true {
                var t = trends[serial] ?? []
                t.append(core)
                if t.count > Self.trendLength { t.removeFirst(t.count - Self.trendLength) }
                trends[serial] = t
                lastTrendAt[serial] = now
            }
        }
        await changed()
    }

    public func ingest(prediction view: PredictionView) async {
        predictions[view.serial] = view
        await changed()
    }

    /// The snapshot for the current inputs.
    public func current() -> LiveSnapshot {
        var list: [LiveSnapshot.Probe] = followed.compactMap { serial in
            guard let snap = snapshots[serial] else { return nil }
            let p = predictions[serial]
            return LiveSnapshot.Probe(
                serial: serial.hex, number: snap.probeNumber, name: names[serial],
                core: snap.virtual.core, target: Self.target(p, snap.prediction),
                state: Self.stateName(p?.state ?? snap.prediction?.state),
                secondsRemaining: p?.secondsRemaining, readyAt: p?.readyAt, readySince: p?.readySince,
                isOffline: snap.isOffline, isStale: p?.isStale ?? false, trend: trends[serial] ?? [])
        }
        list.sort(by: Self.order)
        return LiveSnapshot(writtenAt: clock.now(), probes: list)
    }

    // MARK: Private

    private func changed() async {
        let snapshot = current()
        let key = Self.stateKey(snapshot)
        let now = clock.monotonic()
        if key != lastStateKey || lastWrite.map({ now - $0 >= minInterval }) ?? true {
            lastStateKey = key
            await flush(snapshot)
            return
        }
        // Throttled: one trailing write when the interval is up.
        guard pending == nil, let last = lastWrite else { return }
        let wait = minInterval - (now - last)
        pending = Task { [weak self] in
            do { try await self?.clock.sleep(for: wait) } catch { return }
            await self?.trailingWrite()
        }
    }

    private func trailingWrite() async {
        pending = nil
        let snapshot = current()
        lastStateKey = Self.stateKey(snapshot)
        await flush(snapshot)
    }

    private func flush(_ snapshot: LiveSnapshot) async {
        pending?.cancel()
        pending = nil
        lastWrite = clock.monotonic()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            try await writer.write(try encoder.encode(snapshot))
            written.append(snapshot)
            if written.count > 50 { written.removeFirst(written.count - 50) }
        } catch {
            lastError = error
        }
    }

    /// The set point, only while a prediction mode is set (mode none carries a meaningless set point).
    private static func target(_ view: PredictionView?, _ status: PredictionStatus?) -> Double? {
        if let view { return view.mode == .none ? nil : view.setpoint }
        guard let status, status.mode != .none else { return nil }
        return status.setpoint
    }

    /// What a widget shows as a state, so a change is written at once: probe set and order, prediction state,
    /// offline, stale, and whether a completion time exists (its value moves every status; that is throttled).
    private static func stateKey(_ snapshot: LiveSnapshot) -> [String] {
        snapshot.probes.map { "\($0.serial):\($0.state):\($0.isOffline):\($0.isStale):\($0.readyAt != nil)" }
    }

    private static func stateName(_ state: PredictionState?) -> String {
        guard let state else { return "unknown" }
        return String(describing: state)
    }

    private static func order(_ a: LiveSnapshot.Probe, _ b: LiveSnapshot.Probe) -> Bool {
        func rank(_ p: LiveSnapshot.Probe) -> Int {
            if p.state == "predicting", p.readyAt != nil { return 0 }
            if p.state == "removalPredictionDone" { return 1 }
            return 2
        }
        let ra = rank(a), rb = rank(b)
        if ra != rb { return ra < rb }
        if ra == 0, let x = a.readyAt, let y = b.readyAt, x != y { return x < y }
        return a.number < b.number
    }
}
