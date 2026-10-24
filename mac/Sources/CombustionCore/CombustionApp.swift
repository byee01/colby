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
    /// Connection state of each MeatNet node the policy is working on.
    public var nodeLinks: [NodeSerial: ProbeConnectionState] = [:]
    /// Log downloads (live fetch or backfill) in progress.
    public var logFetchesInFlight: Int
}

/// The facade a UI talks to (docs/02 §13): probes, history, follow, diagnostics, predictions, commands, alerts.
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
    public nonisolated let commands: Commands
    public nonisolated let alerts: AlertEngine
    public nonisolated let predictionPresenter: PredictionPresenter
    /// Alert rules and the alert log, in the app database (nil when a custom rule store was passed).
    public nonisolated let alertStore: SQLiteAlertStore?
    /// Widget snapshot writer (docs/02 §18); nil unless a destination was passed.
    public nonisolated let liveSnapshot: LiveSnapshotWriter?
    /// MeatNet nodes in range or connected (`ProbeStore.nodes`).
    public nonisolated var nodes: AsyncStream<[NodeSerial: NodeSnapshot]> { probes.nodes }

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
    ///   - alertSinks: where alert events go (notification, sound); none by default.
    ///   - keepAwake: held while a followed probe is in a cook.
    ///   - databasePath: a file path or `":memory:"`.
    ///   - liveSnapshot: where to write the widget snapshot; no snapshot when nil.
    ///   - alertRuleStore: defaults to a `SQLiteAlertStore` on `databasePath`, which also logs alert events.
    ///   - policy: defaults to `DirectConnectionPolicy`.
    ///   - trace: optional parity trace (docs/05 §3): `probe`, `session` and `link` events.
    public init(
        transport: any BleTransport, clock: any Clock, databasePath: String = ":memory:",
        policy: (any ConnectionPolicy)? = nil, trace: (any TraceSink)? = nil,
        alertSinks: [any AlertSink] = [], keepAwake: (any KeepAwake)? = nil,
        alertRuleStore: (any AlertRuleStore)? = nil, liveSnapshot: (any LiveSnapshotWriting)? = nil
    ) throws {
        // History migrates the shared schema first; the alert store's own connection then finds it current.
        let history = try HistoryStore(path: databasePath, clock: clock, logFetcher: router)
        let alertStore = alertRuleStore == nil ? try SQLiteAlertStore(path: databasePath) : nil
        self.alertStore = alertStore
        self.liveSnapshot = liveSnapshot.map { LiveSnapshotWriter(clock: clock, writer: $0) }
        self.transport = transport
        self.clock = clock
        self.history = history
        self.probes = ProbeStore(clock: clock, persistence: history)
        self.advertisements = AdvertisementSource(transport: transport)
        self.policy = policy ?? DirectConnectionPolicy()
        self.trace = trace
        self.coordinator = LinkCoordinator(probes: probes, history: history, clock: clock, router: router, trace: trace)
        let commands = Commands(probes: probes, routing: router, clock: clock, trace: trace)
        self.commands = commands
        self.predictionPresenter = PredictionPresenter(probes: probes, clock: clock)
        self.alerts = AlertEngine(
            clock: clock, ruleStore: alertRuleStore ?? alertStore ?? InMemoryAlertRuleStore(), sinks: alertSinks,
            keepAwake: keepAwake, silencer: commands, trace: trace)
    }

    /// One probe's prediction for the UI: the latest view first, then every change. docs/02 §7.
    public nonisolated func predictions(_ serial: ProbeSerial) -> AsyncStream<PredictionView> {
        predictionPresenter.predictions(serial)
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
        let nodeSightings = advertisements.nodeSightings
        let policyNodes = advertisements.nodeSightings
        let policyRepeated = advertisements.repeatedSightings
        let alertEvents = alerts.events

        let probes = self.probes
        tasks.append(Task { for await o in observations { await probes.ingest(o) } })
        tasks.append(Task { for await e in statuses { await self.route(e) } })
        tasks.append(Task { for await s in nodeSightings { await probes.ingest(sighting: s) } })
        if let alertStore { tasks.append(Task { await alertStore.consume(alertEvents) }) }
        tasks.append(Task {
            for await s in bluetoothChanges { await self.bluetoothChanged(s) }
        })

        await predictionPresenter.start()
        await alerts.start(probes: probes.probes, predictions: predictionPresenter.updates, followed: probes.followed)
        await liveSnapshot?.start(
            probes: probes.probes, predictions: predictionPresenter.updates, followed: probes.followed)
        if let liveSnapshot {
            let names = history.cookNames
            tasks.append(Task { for await m in names { await liveSnapshot.setNames(m) } })
        }

        await advertisements.start()
        await policy.start(ConnectionPolicyInput(
            transport: transport, clock: clock, sightings: sightings, followed: followed, delegate: coordinator,
            nodeSightings: policyNodes, repeatedSightings: policyRepeated))
    }

    /// Closes every link, stops scanning and timers. Streams of the stores stay open.
    public func stop() async {
        guard started else { return }
        started = false
        for t in tasks { t.cancel() }
        tasks = []
        await alerts.stop()
        await liveSnapshot?.stop()
        await predictionPresenter.stop()
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

    // MARK: Cook names

    /// Each probe's current cook name (absent when unnamed): the latest map first, then changes.
    public nonisolated var cookNames: AsyncStream<[ProbeSerial: String]> { history.cookNames }

    /// Names the probe's current cook, or its next one if none is open; nil or blank clears it.
    /// History rows and the widget snapshot show it.
    public func setCookName(_ name: String?, for serial: ProbeSerial) async throws {
        try await history.setCookName(name, for: serial)
    }

    // MARK: Diagnostics

    public func diagnostics() async -> DiagnosticsSnapshot {
        let (uart, decode) = await coordinator.linkCounters()
        return DiagnosticsSnapshot(
            bluetooth: bluetooth, advertisements: await advertisements.diagnostics, uart: uart,
            statusDecodeErrors: decode, links: await policy.states(), nodeLinks: await policy.nodeStates(),
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

/// Routes log fetches and commands to the current link of each probe: its direct link if it has one, else
/// a node that is relaying it (nearest first).
final class LinkRouter: LogFetcher, CommandRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ProbeSerial: DirectProbeLink] = [:]
    private var nodes: [NodeSerial: NodeLink] = [:]

    func set(_ serial: ProbeSerial, _ link: DirectProbeLink?) {
        lock.withLock { links[serial] = link }
    }

    func setNode(_ serial: NodeSerial, _ link: NodeLink?) {
        lock.withLock { nodes[serial] = link }
    }

    func commandRoute(for probe: ProbeSerial) -> (any CommandRoute)? {
        let (direct, nodeLinks) = lock.withLock { (links[probe], Array(nodes.values)) }
        return direct ?? nearestNode(relaying: probe, among: nodeLinks)
    }

    func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error> {
        let (direct, nodeLinks) = lock.withLock { (links[probe], Array(nodes.values)) }
        if let direct { return direct.readLogs(probe: probe, start: start, end: end) }
        guard let node = nearestNode(relaying: probe, among: nodeLinks) else {
            return AsyncThrowingStream { $0.finish(throwing: UartError.disconnected) }
        }
        return node.readLogs(probe: probe, start: start, end: end)
    }

    private func nearestNode(relaying probe: ProbeSerial, among nodeLinks: [NodeLink]) -> NodeLink? {
        nodeLinks.compactMap { n in n.hops(to: probe).map { (n, $0) } }
            .sorted { ($0.1, $0.0.serial) < ($1.1, $1.0.serial) }
            .first?.0
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
    private var nodeLinks: [NodeSerial: NodeLink] = [:]
    private var nodeForwarders: [NodeSerial: [Task<Void, Never>]] = [:]
    /// Probes whose running backfill reads through a node, and which one (no direct link at the time).
    private var nodeBackfills: [ProbeSerial: NodeSerial] = [:]
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
        nodeBackfills[serial] = nil
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
    ///
    /// A probe with no direct link but relayed by a connected node gets its backfill through the node
    /// (the router picks the node per read), started by its first recorded status.
    func statusRecorded(serial: ProbeSerial, receivedAt: Date) {
        if let since = awaitingFirstStatus[serial], receivedAt >= since, let link = links[serial] {
            awaitingFirstStatus[serial] = nil
            backfills[serial]?.cancel()
            nodeBackfills[serial] = nil
            backfills[serial] = Task { await self.runBackfill(serial: serial, fetcher: link) }
            return
        }
        guard links[serial] == nil, backfills[serial] == nil,
              let node = nodeLinks.values.first(where: { $0.covers(serial) }) else { return }
        nodeBackfills[serial] = node.serial
        backfills[serial] = Task { await self.runBackfill(serial: serial, fetcher: self.router) }
    }

    // MARK: Nodes

    func nodeLinkCreated(_ link: NodeLink) {
        let serial = link.serial
        nodeLinks[serial] = link
        nodeForwarders[serial]?.forEach { $0.cancel() }
        let observations = link.observations
        let snapshots = link.snapshots
        let probes = self.probes
        nodeForwarders[serial] = [
            Task { for await o in observations { await probes.ingest(o) } },
            Task { for await s in snapshots { await probes.ingest(node: s) } },
        ]
    }

    func nodeLinkEstablished(_ link: NodeLink) {
        router.setNode(link.serial, link)
    }

    func nodeLinkEnded(serial: NodeSerial, reason: DisconnectReason) async {
        router.setNode(serial, nil)
        for (probe, via) in nodeBackfills where via == serial {
            backfills.removeValue(forKey: probe)?.cancel()
            nodeBackfills[probe] = nil
        }
        nodeForwarders.removeValue(forKey: serial)?.forEach { $0.cancel() }
        if let link = nodeLinks.removeValue(forKey: serial) {
            // The forwarder may not have seen the final (disconnected) snapshot yet.
            await probes.ingest(node: await link.snapshot)
        }
    }

    func shutdown() {
        for t in backfills.values { t.cancel() }
        for t in forwarders.values { t.cancel() }
        for ts in nodeForwarders.values { ts.forEach { $0.cancel() } }
        backfills = [:]
        forwarders = [:]
        nodeForwarders = [:]
        nodeBackfills = [:]
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
    private func runBackfill(serial: ProbeSerial, fetcher: any LogFetcher) async {
        var attempt = 0
        while !Task.isCancelled {
            var complete = true
            if let key = try? await history.currentSession(of: serial) {
                let result = await history.backfill(key, using: fetcher)
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
