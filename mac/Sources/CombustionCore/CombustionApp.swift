import CombustionCodec
import Foundation

/// Counters and link states for a diagnostics screen. docs/02 §13 `diagnostics`.
public struct DiagnosticsSnapshot: Sendable, Equatable {
    public var bluetooth: BluetoothState
    public var advertisements: AdvertisementDiagnostics
    /// UART counters per followed probe, summed over every link it has had since `start()`.
    public var uart: [ProbeSerial: UartDiagnostics]
    /// Probe Status notifications the codec rejected, per probe, summed over links.
    public var statusDecodeErrors: [ProbeSerial: Int]
    public var links: [ProbeSerial: ProbeConnectionState]
    /// Log downloads (live fetch or backfill) in progress.
    public var logFetchesInFlight: Int
}

/// The facade a UI talks to (docs/02 §13). Only the parts that exist so far: probes, history, follow,
/// diagnostics. Commands, predictions and alerts arrive with M5/M6.
///
/// Wiring:
/// - `AdvertisementSource` -> `ProbeStore`.
/// - `ConnectionPolicy` makes a `DirectProbeLink` per followed probe; link observations -> `ProbeStore`.
/// - `ProbeStore.statusEvents` (followed probes only) -> `HistoryStore`, one ordered lane per probe.
/// - After the first status of each (re)connection is recorded, `HistoryStore.backfill` runs over that link.
///   It repeats while holes remain and re-checks every minute while connected.
/// - The store's live `LogFetcher` routes each probe to its current link and fails while it has none.
public actor CombustionApp {
    public nonisolated let probes: ProbeStore
    public nonisolated let history: HistoryStore

    /// Bluetooth state: current value first, then changes.
    public nonisolated var bluetoothState: AsyncStream<BluetoothState> { transport.state }

    private let transport: any BleTransport
    private let clock: any Clock
    private let advertisements: AdvertisementSource
    private let policy: any ConnectionPolicy
    private let trace: (any TraceSink)?
    private let router = LinkRouter()
    private let coordinator: LinkCoordinator

    private var tasks: [Task<Void, Never>] = []
    private var lanes: [ProbeSerial: AsyncStream<ProbeStatusEvent>.Continuation] = [:]
    private var laneTasks: [Task<Void, Never>] = []
    private var lastSession: [ProbeSerial: SessionKey] = [:]
    private var started = false
    private var bluetooth: BluetoothState = .poweredOff

    /// - Parameters:
    ///   - databasePath: a file path or `":memory:"`.
    ///   - policy: defaults to `DirectConnectionPolicy`.
    ///   - trace: optional parity trace (docs/05 §3): `probe`, `session` and `link` events.
    public init(
        transport: any BleTransport, clock: any Clock, databasePath: String = ":memory:",
        policy: (any ConnectionPolicy)? = nil, trace: (any TraceSink)? = nil
    ) throws {
        let history = try HistoryStore(path: databasePath, clock: clock, logFetcher: router)
        self.transport = transport
        self.clock = clock
        self.history = history
        self.probes = ProbeStore(clock: clock, persistence: history)
        self.advertisements = AdvertisementSource(transport: transport)
        self.policy = policy ?? DirectConnectionPolicy()
        self.trace = trace
        self.coordinator = LinkCoordinator(probes: probes, history: history, clock: clock, router: router, trace: trace)
    }

    // MARK: Lifecycle

    /// Loads the followed set, starts scanning and the connection policy. Idempotent.
    public func start() async {
        guard !started else { return }
        started = true
        await probes.start()

        // Subscribe before anything can produce events.
        let observations = advertisements.observations
        let sightings = advertisements.probeSightings
        let statuses = probes.statusEvents
        let followed = probes.followed
        let bluetoothChanges = transport.state

        let probes = self.probes
        tasks.append(Task { for await o in observations { await probes.ingest(o) } })
        tasks.append(Task { for await e in statuses { await self.route(e) } })
        tasks.append(Task {
            for await s in bluetoothChanges { await self.bluetoothChanged(s) }
        })

        await advertisements.start()
        await policy.start(ConnectionPolicyInput(
            transport: transport, clock: clock, sightings: sightings, followed: followed, delegate: coordinator))
    }

    /// Closes every link, stops scanning and timers. Streams of the stores stay open.
    public func stop() async {
        guard started else { return }
        started = false
        for t in tasks { t.cancel() }
        tasks = []
        await policy.stop()
        await coordinator.shutdown()
        for c in lanes.values { c.finish() }
        lanes = [:]
        for t in laneTasks { t.cancel() }
        laneTasks = []
        await advertisements.stop()
        await probes.stop()
    }

    // MARK: Follow

    public func follow(_ serial: ProbeSerial) async { await probes.follow(serial) }
    public func unfollow(_ serial: ProbeSerial) async { await probes.unfollow(serial) }

    // MARK: Diagnostics

    public func diagnostics() async -> DiagnosticsSnapshot {
        let (uart, decode) = await coordinator.linkCounters()
        return DiagnosticsSnapshot(
            bluetooth: bluetooth, advertisements: await advertisements.diagnostics, uart: uart,
            statusDecodeErrors: decode, links: await policy.states(),
            logFetchesInFlight: await history.fetchesInFlight)
    }

    // MARK: Internals

    private func bluetoothChanged(_ state: BluetoothState) async {
        bluetooth = state
        // Leaving poweredOn stops the scan; resume it when Bluetooth returns.
        if state == .poweredOn, started { await transport.startScan() }
    }

    private func route(_ event: ProbeStatusEvent) async {
        guard started, await probes.followedSerials().contains(event.serial) else { return }
        if let lane = lanes[event.serial] {
            lane.yield(event)
            return
        }
        let (stream, continuation) = AsyncStream<ProbeStatusEvent>.makeStream()
        lanes[event.serial] = continuation
        laneTasks.append(Task { for await e in stream { await self.process(e) } })
        continuation.yield(event)
    }

    /// Records one status. Runs in the probe's own lane, so statuses of one probe stay in order and a slow
    /// log fetch on one probe does not hold up another.
    private func process(_ event: ProbeStatusEvent) async {
        let s = event.status
        let core = s.temperatures[s.virtualSensors.core]
        trace?.emit("probe", [
            "serial": .serial(event.serial.rawValue), "core": .double(core),
            "state": .string(String(describing: s.prediction.state)),
        ])
        guard let key = try? await history.ingest(status: event) else { return }
        if lastSession[event.serial] != key {
            if let old = lastSession[event.serial] {
                trace?.emit("session", [
                    "serial": .serial(old.serial.rawValue), "sessionId": .int(Int(old.sessionId)),
                    "transition": .string("ended"),
                ])
            }
            trace?.emit("session", [
                "serial": .serial(key.serial.rawValue), "sessionId": .int(Int(key.sessionId)),
                "transition": .string("started"),
            ])
            lastSession[event.serial] = key
        }
        await coordinator.statusRecorded(serial: event.serial, receivedAt: event.receivedAt)
    }
}

// MARK: - Link plumbing

/// Routes live log fetches to the current link of each probe.
final class LinkRouter: LogFetcher, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ProbeSerial: DirectProbeLink] = [:]

    func set(_ serial: ProbeSerial, _ link: DirectProbeLink?) {
        lock.withLock { links[serial] = link }
    }

    func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error> {
        guard let link = lock.withLock({ links[probe] }) else {
            return AsyncThrowingStream { $0.finish(throwing: UartError.disconnected) }
        }
        return link.readLogs(probe: probe, start: start, end: end)
    }
}

/// Receives links from the policy: forwards their observations, publishes them to the router and runs
/// the backfill loop.
actor LinkCoordinator: ConnectionPolicyDelegate {
    private let probes: ProbeStore
    private let history: HistoryStore
    private let clock: any Clock
    private let router: LinkRouter
    private let trace: (any TraceSink)?

    private var links: [ProbeSerial: DirectProbeLink] = [:]
    private var forwarders: [ProbeSerial: Task<Void, Never>] = [:]
    private var backfills: [ProbeSerial: Task<Void, Never>] = [:]
    /// Probes whose link is up but whose first status has not been recorded yet.
    private var awaitingFirstStatus: [ProbeSerial: Date] = [:]
    private var retiredUart: [ProbeSerial: UartDiagnostics] = [:]
    private var retiredDecodeErrors: [ProbeSerial: Int] = [:]

    static let recheckInterval: Duration = .seconds(60)

    init(probes: ProbeStore, history: HistoryStore, clock: any Clock, router: LinkRouter, trace: (any TraceSink)?) {
        self.probes = probes
        self.history = history
        self.clock = clock
        self.router = router
        self.trace = trace
    }

    func linkCreated(_ link: DirectProbeLink) {
        let serial = link.serial
        links[serial] = link
        forwarders[serial]?.cancel()
        let observations = link.observations
        let probes = self.probes
        forwarders[serial] = Task { for await o in observations { await probes.ingest(o) } }
    }

    func linkEstablished(_ link: DirectProbeLink) {
        let serial = link.serial
        router.set(serial, link)
        awaitingFirstStatus[serial] = clock.now()
        trace?.emit("link", ["serial": .serial(serial.rawValue), "state": .string("connected")])
    }

    func linkEnded(serial: ProbeSerial, reason: DisconnectReason) async {
        router.set(serial, nil)
        awaitingFirstStatus[serial] = nil
        backfills.removeValue(forKey: serial)?.cancel()
        forwarders.removeValue(forKey: serial)?.cancel()
        if let link = links.removeValue(forKey: serial) {
            retiredUart[serial] = Self.sum(retiredUart[serial], await link.uart.diagnostics)
            retiredDecodeErrors[serial, default: 0] += await link.statusDecodeErrors
        }
        trace?.emit("link", [
            "serial": .serial(serial.rawValue), "state": .string("disconnected"), "reason": .string(reason.rawValue),
        ])
    }

    /// Called after a status was recorded in history. The first one after a connect starts the backfill:
    /// until then the session for this connection may not exist (new session) or may still be the old one.
    func statusRecorded(serial: ProbeSerial, receivedAt: Date) {
        guard let since = awaitingFirstStatus[serial], receivedAt >= since, let link = links[serial] else { return }
        awaitingFirstStatus[serial] = nil
        backfills[serial]?.cancel()
        backfills[serial] = Task { await self.runBackfill(serial: serial, link: link) }
    }

    func shutdown() {
        for t in backfills.values { t.cancel() }
        for t in forwarders.values { t.cancel() }
        backfills = [:]
        forwarders = [:]
    }

    func linkCounters() async -> ([ProbeSerial: UartDiagnostics], [ProbeSerial: Int]) {
        var uart = retiredUart
        var decode = retiredDecodeErrors
        for (serial, link) in links {
            uart[serial] = Self.sum(uart[serial], await link.uart.diagnostics)
            decode[serial, default: 0] += await link.statusDecodeErrors
        }
        return (uart, decode)
    }

    /// Fills holes while the link lives: retry soon while holes remain, otherwise re-check every minute
    /// (a live fetch can lose a record to a dropped notification).
    private func runBackfill(serial: ProbeSerial, link: DirectProbeLink) async {
        var attempt = 0
        while !Task.isCancelled {
            var complete = true
            if let key = try? await history.currentSession(of: serial) {
                let result = await history.backfill(key, using: link)
                complete = result.remaining == 0 && !result.failed
            }
            let wait: Duration
            if complete {
                attempt = 0
                wait = Self.recheckInterval
            } else {
                attempt += 1
                wait = .seconds(min(2 * attempt, 30))
            }
            do { try await clock.sleep(for: wait) } catch { return }
        }
    }

    private static func sum(_ a: UartDiagnostics?, _ b: UartDiagnostics) -> UartDiagnostics {
        var out = a ?? UartDiagnostics()
        out.framingErrors += b.framingErrors
        out.ignoredFrames += b.ignoredFrames
        out.duplicateResponses += b.duplicateResponses
        out.codecErrors += b.codecErrors
        return out
    }
}
