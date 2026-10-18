import CombustionCodec
import Foundation

/// Where followed probes are persisted (the `probe` table). `HistoryStore` conforms.
public protocol FollowedProbePersistence: Sendable {
    func loadFollowed() async throws -> Set<ProbeSerial>
    func setFollowed(_ serial: ProbeSerial, _ followed: Bool) async throws
}

/// Merges observations from every link into one `ProbeSnapshot` per probe. docs/02 §6.1.
///
/// - Streams replay the latest value to new subscribers.
/// - UI-facing streams (`probes`, `probe(_:)`) are coalesced: the first change after a quiet period is emitted
///   immediately, later changes at most once per `coalesceInterval` (100 ms = 10 Hz) carrying the latest state.
/// - `statusEvents` is not coalesced; it carries each accepted full status.
/// - A source with no data for `sourceTimeout` is dropped (checked every `expiryCheckInterval`, so the drop
///   happens at the first check at or after the timeout). A probe whose sources are all gone stays, offline.
///
/// Call `start()` once to load the persisted followed set; the timers start lazily on the first ingest.
public actor ProbeStore {
    private let clock: any Clock
    private let persistence: (any FollowedProbePersistence)?
    private let sourceTimeout: Duration
    private let coalesceInterval: Duration
    private let expiryCheckInterval: Duration

    private var mergers: [ProbeSerial: ProbeMerger] = [:]
    private var published: [ProbeSerial: ProbeSnapshot] = [:]
    private var dirty: Set<ProbeSerial> = []
    private var lastFlush: Duration?
    private var flushTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var followedSet: Set<ProbeSerial> = []
    private var perProbe: [ProbeSerial: Broadcaster<ProbeSnapshot?>] = [:]

    private let probesBroadcaster = Broadcaster<[ProbeSerial: ProbeSnapshot]>(initial: [:], replayLatest: true)
    private let followedBroadcaster = Broadcaster<Set<ProbeSerial>>(initial: [], replayLatest: true)
    private let statusBroadcaster = Broadcaster<ProbeStatusEvent>()

    public init(
        clock: any Clock,
        persistence: (any FollowedProbePersistence)? = nil,
        sourceTimeout: Duration = .seconds(10),
        coalesceInterval: Duration = .milliseconds(100),
        expiryCheckInterval: Duration = .seconds(1)
    ) {
        self.clock = clock
        self.persistence = persistence
        self.sourceTimeout = sourceTimeout
        self.coalesceInterval = coalesceInterval
        self.expiryCheckInterval = expiryCheckInterval
    }

    deinit {
        flushTask?.cancel()
        expiryTask?.cancel()
    }

    // MARK: Observables

    /// All probes, latest map (coalesced).
    public nonisolated var probes: AsyncStream<[ProbeSerial: ProbeSnapshot]> { probesBroadcaster.stream() }

    /// One probe; emits nil first if the probe is unknown (coalesced).
    public func probe(_ serial: ProbeSerial) -> AsyncStream<ProbeSnapshot?> {
        if let b = perProbe[serial] { return b.stream() }
        let initial: ProbeSnapshot?? = .some(published[serial])
        let b = Broadcaster<ProbeSnapshot?>(initial: initial, replayLatest: true)
        perProbe[serial] = b
        return b.stream()
    }

    public nonisolated var followed: AsyncStream<Set<ProbeSerial>> { followedBroadcaster.stream() }

    /// Every accepted full status (freshest per probe), uncoalesced. For HistoryStore and session detection.
    public nonisolated var statusEvents: AsyncStream<ProbeStatusEvent> { statusBroadcaster.stream() }

    // MARK: Direct reads (not coalesced)

    public func snapshot(of serial: ProbeSerial) -> ProbeSnapshot? { mergers[serial]?.snapshot() }

    public func snapshots() -> [ProbeSerial: ProbeSnapshot] {
        mergers.compactMapValues { $0.snapshot() }
    }

    // MARK: Lifecycle

    /// Loads the persisted followed set.
    public func start() async {
        guard let persistence else { return }
        if let loaded = try? await persistence.loadFollowed() {
            followedSet.formUnion(loaded)
            followedBroadcaster.send(followedSet)
        }
    }

    /// Cancels timers. Streams stay open.
    public func stop() {
        flushTask?.cancel()
        flushTask = nil
        expiryTask?.cancel()
        expiryTask = nil
    }

    // MARK: Ingest

    public func ingest(_ o: ProbeObservation) {
        ensureExpiryTimer()
        var m = mergers[o.serial] ?? ProbeMerger(serial: o.serial)
        let accepted = m.ingest(o, arrivedAt: clock.now())
        mergers[o.serial] = m
        if accepted, case .status(let s) = o.payload {
            statusBroadcaster.send(ProbeStatusEvent(serial: o.serial, status: s, receivedAt: o.receivedAt))
        }
        markDirty(o.serial)
    }

    // MARK: Follow

    public func follow(_ serial: ProbeSerial) async {
        guard followedSet.insert(serial).inserted else { return }
        followedBroadcaster.send(followedSet)
        try? await persistence?.setFollowed(serial, true)
    }

    public func unfollow(_ serial: ProbeSerial) async {
        guard followedSet.remove(serial) != nil else { return }
        followedBroadcaster.send(followedSet)
        try? await persistence?.setFollowed(serial, false)
    }

    public func followedSerials() -> Set<ProbeSerial> { followedSet }

    // MARK: Source expiry

    private func ensureExpiryTimer() {
        guard expiryTask == nil else { return }
        let ticks = clock.timer(every: expiryCheckInterval)
        expiryTask = Task { [weak self] in
            for await _ in ticks {
                guard let self else { return }
                await self.expireSources()
            }
        }
    }

    private func expireSources() {
        let now = clock.now()
        let ttl = sourceTimeout.totalSeconds
        for serial in Array(mergers.keys) {
            if mergers[serial]?.expire(now: now, ttl: ttl) == true { markDirty(serial) }
        }
    }

    // MARK: Coalesced publishing

    private func markDirty(_ serial: ProbeSerial) {
        dirty.insert(serial)
        guard flushTask == nil else { return }
        let now = clock.monotonic()
        if let last = lastFlush, now - last < coalesceInterval {
            let wait = coalesceInterval - (now - last)
            let clock = self.clock
            flushTask = Task { [weak self] in
                try? await clock.sleep(for: wait)
                guard !Task.isCancelled else { return }
                await self?.scheduledFlush()
            }
        } else {
            flush()
        }
    }

    private func scheduledFlush() {
        flushTask = nil
        flush()
    }

    private func flush() {
        guard !dirty.isEmpty else { return }
        lastFlush = clock.monotonic()
        let serials = dirty
        dirty.removeAll()
        for serial in serials {
            guard let snap = mergers[serial]?.snapshot() else { continue }
            published[serial] = snap
            perProbe[serial]?.send(snap)
        }
        probesBroadcaster.send(published)
    }
}
