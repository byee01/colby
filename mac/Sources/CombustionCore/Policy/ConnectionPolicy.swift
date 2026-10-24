import CombustionCodec
import Foundation

/// Where one followed probe stands in the connection lifecycle (diagnostics and tests).
public enum ProbeConnectionState: Sendable, Equatable {
    /// Followed, but its own advertisement has not been heard yet.
    case waitingForAdvertisement
    case connecting(attempt: Int)
    case connected
    /// A connect failed or the link dropped; the next attempt is at `retryAt` (clock monotonic time).
    case backoff(attempt: Int, retryAt: Duration)
    /// Absent from advertisements for the give-up interval. Resumes when it advertises again.
    case gaveUp
    /// A connected MeatNet node covers this probe, so no direct connection is held (probe slots stay free).
    case viaNode(NodeSerial)
}

/// Receives the links a policy creates. All calls for one probe are sequential.
public protocol ConnectionPolicyDelegate: Sendable {
    /// A link object exists but has not started. Subscribe to its streams here so nothing is missed.
    func linkCreated(_ link: DirectProbeLink) async
    /// The link is started (discovered, UART ready, subscribed to Probe Status).
    func linkEstablished(_ link: DirectProbeLink) async
    /// The link is gone (dropped, closed on unfollow, or closed by `stop`).
    func linkEnded(serial: ProbeSerial, reason: DisconnectReason) async

    /// Node links follow the same three steps. Defaults do nothing.
    func nodeLinkCreated(_ link: NodeLink) async
    func nodeLinkEstablished(_ link: NodeLink) async
    func nodeLinkEnded(serial: NodeSerial, reason: DisconnectReason) async
}

public extension ConnectionPolicyDelegate {
    func nodeLinkCreated(_ link: NodeLink) async {}
    func nodeLinkEstablished(_ link: NodeLink) async {}
    func nodeLinkEnded(serial: NodeSerial, reason: DisconnectReason) async {}
}

/// Everything a policy needs from the app.
public struct ConnectionPolicyInput: Sendable {
    public var transport: any BleTransport
    public var clock: any Clock
    /// Probes heard on their own peripheral (`AdvertisementSource.probeSightings`).
    public var sightings: AsyncStream<ProbeSighting>
    /// The followed set; current value first (`ProbeStore.followed`).
    public var followed: AsyncStream<Set<ProbeSerial>>
    public var delegate: any ConnectionPolicyDelegate
    /// MeatNet nodes heard on their own peripheral (`AdvertisementSource.nodeSightings`).
    public var nodeSightings: AsyncStream<NodeSighting>
    /// Probes heard through a node (`AdvertisementSource.repeatedSightings`).
    public var repeatedSightings: AsyncStream<RepeatedProbeSighting>

    public init(transport: any BleTransport, clock: any Clock, sightings: AsyncStream<ProbeSighting>,
                followed: AsyncStream<Set<ProbeSerial>>, delegate: any ConnectionPolicyDelegate,
                nodeSightings: AsyncStream<NodeSighting> = AsyncStream { $0.finish() },
                repeatedSightings: AsyncStream<RepeatedProbeSighting> = AsyncStream { $0.finish() }) {
        self.transport = transport
        self.clock = clock
        self.sightings = sightings
        self.followed = followed
        self.delegate = delegate
        self.nodeSightings = nodeSightings
        self.repeatedSightings = repeatedSightings
    }
}

/// Decides what to connect to (docs/02 §5.6). Replaceable so it can be tuned without touching links.
public protocol ConnectionPolicy: Sendable {
    func start(_ input: ConnectionPolicyInput) async
    /// Closes every link and ends all work.
    func stop() async
    func states() async -> [ProbeSerial: ProbeConnectionState]
    /// Connection state of each node the policy is working on (diagnostics). Empty for policies without nodes.
    func nodeStates() async -> [NodeSerial: ProbeConnectionState]
}

/// Default policy (docs/02 §5.6):
/// 1. Scanning is the app's job (always on); this policy reacts to what the scan hears.
/// 2. MeatNet node step: when a node repeats the advertisement of a followed probe, connect to the node
///    (one connection gets every probe on its network and keeps probe slots free for the phone app).
///    While a node is connected and covers a probe, that probe gets no direct connection, and an existing
///    one is closed. A connected node covers a probe while it relays its `0x45` statuses or repeats its
///    advertisement (a connected Display advertises the probe with gaps of up to 16 s,
///    spec/replays/display-relay-1hop). A node whose first connect attempt is still under way holds direct connects back.
/// 3. Otherwise connect directly to each followed probe once its own advertisement has been heard. If the
///    node link drops (or stops repeating the probe) the probe falls back to direct, starting from the
///    initial backoff.
/// 4. Reconnect with backoff 1, 2, 4 ... 30 s, for probes and nodes alike. Give up on a probe when it has
///    been absent from advertisements for 5 min (absence counts from the later of the last advertisement
///    and the end of the last link); resume as soon as it advertises again. A node is left alone once no
///    followed probe is heard through it.
/// 5. At most one connection per probe: one supervisor task per followed probe, and one per node.
public actor DirectConnectionPolicy: ConnectionPolicy {
    public struct Timing: Sendable {
        public var initialBackoff: Duration = .seconds(1)
        public var maxBackoff: Duration = .seconds(30)
        public var absentLimit: Duration = .seconds(300)
        public var connectTimeout: Duration = .seconds(10)
        /// A link that lasted this long counts as healthy: the next reconnect starts from `initialBackoff`.
        public var stableAfter: Duration = .seconds(10)
        /// How often a probe supervisor re-checks whether a node covers it.
        public var coverageCheck: Duration = .seconds(1)
        /// A probe counts as heard through a node for this long after the node's last repeated advertisement.
        public var viaNodeFresh: Duration = .seconds(15)
        public init() {}
    }

    private struct NodeInfo {
        var peripheral: PeripheralId
        var productType: NodeProductType
    }

    private let timing: Timing
    private var input: ConnectionPolicyInput?
    private var background: [Task<Void, Never>] = []
    private var supervisors: [ProbeSerial: Task<Void, Never>] = [:]
    private var peripherals: [ProbeSerial: PeripheralId] = [:]
    private var lastSeen: [ProbeSerial: Duration] = [:]
    private var stateByProbe: [ProbeSerial: ProbeConnectionState] = [:]
    private var waiters: [ProbeSerial: [UInt64: CheckedContinuation<Void, Never>]] = [:]
    private var nextWaiter: UInt64 = 0

    private var followedSet: Set<ProbeSerial> = []
    private var nodes: [NodeSerial: NodeInfo] = [:]
    /// When each followed probe was last repeated by each node peripheral (monotonic).
    private var viaNode: [ProbeSerial: [PeripheralId: Duration]] = [:]
    private var nodeSupervisors: [NodeSerial: Task<Void, Never>] = [:]
    private var nodeLinks: [NodeSerial: NodeLink] = [:]
    private var stateByNode: [NodeSerial: ProbeConnectionState] = [:]

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public func states() -> [ProbeSerial: ProbeConnectionState] { stateByProbe }
    public func nodeStates() -> [NodeSerial: ProbeConnectionState] { stateByNode }

    public func start(_ input: ConnectionPolicyInput) async {
        guard self.input == nil else { return }
        self.input = input
        background.append(Task { [sightings = input.sightings] in
            for await s in sightings { self.noteSighting(s) }
        })
        background.append(Task { [followed = input.followed] in
            for await set in followed { self.reconcile(set) }
        })
        background.append(Task { [nodeSightings = input.nodeSightings] in
            for await s in nodeSightings { self.noteNode(s) }
        })
        background.append(Task { [repeated = input.repeatedSightings] in
            for await s in repeated { self.noteRepeated(s) }
        })
    }

    public func stop() async {
        let all = background + Array(supervisors.values) + Array(nodeSupervisors.values)
        background = []
        supervisors = [:]
        nodeSupervisors = [:]
        input = nil
        for t in all { t.cancel() }
        for t in all { await t.value }
        stateByProbe = [:]
        stateByNode = [:]
    }

    // MARK: Inputs

    private func noteSighting(_ s: ProbeSighting) {
        guard let input else { return }
        peripherals[s.serial] = s.peripheral
        lastSeen[s.serial] = input.clock.monotonic()
        if let ws = waiters.removeValue(forKey: s.serial) {
            for c in ws.values { c.resume() }
        }
    }

    private func reconcile(_ followed: Set<ProbeSerial>) {
        guard input != nil else { return }
        followedSet = followed
        for serial in followed where supervisors[serial] == nil {
            stateByProbe[serial] = .waitingForAdvertisement
            supervisors[serial] = Task { await self.supervise(serial) }
        }
        for serial in Array(supervisors.keys) where !followed.contains(serial) {
            supervisors.removeValue(forKey: serial)?.cancel()
            stateByProbe[serial] = nil
        }
        // A node no followed probe is heard through has nothing to do for us.
        for serial in Array(nodeSupervisors.keys) where !nodeHearsFollowed(serial) {
            nodeSupervisors.removeValue(forKey: serial)?.cancel()
            stateByNode[serial] = nil
        }
        evaluateNodes()
    }

    private func noteNode(_ s: NodeSighting) {
        nodes[s.serial] = NodeInfo(peripheral: s.peripheral, productType: s.productType)
        evaluateNodes()
    }

    private func noteRepeated(_ s: RepeatedProbeSighting) {
        guard let input, followedSet.contains(s.serial) else { return }
        viaNode[s.serial, default: [:]][s.nodePeripheral] = input.clock.monotonic()
        evaluateNodes()
    }

    /// Suspends until the next sighting of `serial` (or cancellation).
    private func waitForSighting(_ serial: ProbeSerial) async {
        nextWaiter += 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    c.resume()
                } else {
                    waiters[serial, default: [:]][id] = c
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(serial, id) }
        }
    }

    private func cancelWaiter(_ serial: ProbeSerial, _ id: UInt64) {
        waiters[serial]?.removeValue(forKey: id)?.resume()
    }

    private func set(_ serial: ProbeSerial, _ state: ProbeConnectionState) {
        guard supervisors[serial] != nil else { return }
        stateByProbe[serial] = state
        evaluateNodes()
    }

    // MARK: Per-probe supervisor

    private func supervise(_ serial: ProbeSerial) async {
        guard let input else { return }
        let clock = input.clock
        var attempt = 0
        var backoff = timing.initialBackoff

        while !Task.isCancelled {
            // Node first: no direct connection while a node covers the probe (or is about to).
            if let node = coveringNode(serial) {
                set(serial, .viaNode(node))
                attempt = 0
                backoff = timing.initialBackoff
                do { try await clock.sleep(for: timing.coverageCheck) } catch { return }
                continue
            }
            if nodePending(serial) {
                set(serial, .waitingForAdvertisement)
                do { try await clock.sleep(for: timing.coverageCheck) } catch { return }
                continue
            }
            guard let peripheral = peripherals[serial], let seen = lastSeen[serial] else {
                set(serial, .waitingForAdvertisement)
                await waitForSighting(serial)
                attempt = 0
                backoff = timing.initialBackoff
                continue
            }
            if clock.monotonic() - seen >= timing.absentLimit {
                set(serial, .gaveUp)
                await waitForSighting(serial)
                attempt = 0
                backoff = timing.initialBackoff
                continue
            }

            attempt += 1
            set(serial, .connecting(attempt: attempt))
            let startedAt = clock.monotonic()
            if let ended = await connectAndRun(serial, peripheral, input) {
                lastSeen[serial] = max(lastSeen[serial] ?? ended, ended)
                if ended - startedAt >= timing.stableAfter {
                    attempt = 0
                    backoff = timing.initialBackoff
                }
            }
            guard !Task.isCancelled else { return }
            if coveringNode(serial) != nil { continue } // closed because a node took over: no backoff

            // Wait out the backoff, but never past the give-up deadline.
            let now = clock.monotonic()
            let deadline = (lastSeen[serial] ?? now) + timing.absentLimit
            let wait = min(backoff, deadline - now)
            backoff = min(backoff * 2, timing.maxBackoff)
            guard wait > .zero else { continue }
            set(serial, .backoff(attempt: attempt, retryAt: now + wait))
            do { try await clock.sleep(for: wait) } catch { return }
        }
    }

    /// One connection attempt and, if it succeeds, the life of the link. Returns the monotonic time the
    /// link ended, or nil if no link was established.
    private func connectAndRun(_ serial: ProbeSerial, _ peripheral: PeripheralId,
                               _ input: ConnectionPolicyInput) async -> Duration? {
        let connection: any GattConnection
        do {
            connection = try await input.transport.connect(peripheral, timeout: timing.connectTimeout)
        } catch {
            return nil
        }
        let link = DirectProbeLink(serial: serial, connection: connection, clock: input.clock)
        await input.delegate.linkCreated(link)
        let drops = link.disconnected
        do {
            try await link.start()
        } catch {
            await link.close()
            await input.delegate.linkEnded(serial: serial, reason: .requested)
            return nil
        }
        set(serial, .connected)
        await input.delegate.linkEstablished(link)
        // Ends when the link drops, or when a node connects and covers this probe (we close the link then).
        let clock = input.clock
        let check = timing.coverageCheck
        let dropped: DisconnectReason? = await withTaskGroup(of: DisconnectReason?.self) { group in
            group.addTask {
                for await r in drops { return r }
                return .linkLost
            }
            group.addTask {
                while !Task.isCancelled {
                    if await self.coveringNode(serial) != nil { return nil }
                    do { try await clock.sleep(for: check) } catch { return nil }
                }
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        await link.close()
        var reason = dropped ?? .requested
        if Task.isCancelled { reason = .requested }
        await input.delegate.linkEnded(serial: serial, reason: reason)
        return input.clock.monotonic()
    }

    // MARK: MeatNet node step

    /// Followed probes heard through `serial` (its peripheral repeated them within `viaNodeFresh`).
    private func followedViaNode(_ serial: NodeSerial) -> [ProbeSerial] {
        guard let input, let node = nodes[serial] else { return [] }
        let now = input.clock.monotonic()
        return followedSet.filter { p in
            guard let seen = viaNode[p]?[node.peripheral] else { return false }
            return now - seen < timing.viaNodeFresh
        }
    }

    private func nodeHearsFollowed(_ serial: NodeSerial) -> Bool { !followedViaNode(serial).isEmpty }

    /// A connected node that relays or repeats `probe` right now.
    private func coveringNode(_ probe: ProbeSerial) -> NodeSerial? {
        nodeLinks.keys.sorted().first { stateByNode[$0] == .connected && nodeLinks[$0]?.covers(probe) == true }
            ?? nodesHearing(probe).first { stateByNode[$0] == .connected }
    }

    /// A node that repeats `probe` is waiting to connect or on its first attempt.
    private func nodePending(_ probe: ProbeSerial) -> Bool {
        nodesHearing(probe).contains { n in
            switch stateByNode[n] {
            case .waitingForAdvertisement?, .connecting(attempt: 1)?: return true
            default: return false
            }
        }
    }

    private func nodesHearing(_ probe: ProbeSerial) -> [NodeSerial] {
        guard let input, let heard = viaNode[probe] else { return [] }
        let now = input.clock.monotonic()
        return nodes.filter { _, info in
            heard[info.peripheral].map { now - $0 < timing.viaNodeFresh } ?? false
        }.keys.sorted()
    }

    /// A followed probe is heard through the node: worth a connection.
    private func nodeWanted(_ serial: NodeSerial) -> Bool { nodeHearsFollowed(serial) }

    /// Starts a supervisor for every node that is wanted and has none. Cheap; called on every input.
    private func evaluateNodes() {
        guard input != nil else { return }
        for serial in nodes.keys where nodeSupervisors[serial] == nil && nodeWanted(serial) {
            stateByNode[serial] = .connecting(attempt: 1)
            nodeSupervisors[serial] = Task { await self.superviseNode(serial) }
        }
    }

    private func setNode(_ serial: NodeSerial, _ state: ProbeConnectionState) {
        if nodeSupervisors[serial] != nil { stateByNode[serial] = state }
    }

    /// Same retry shape as `supervise`. Ends (and is restarted by `evaluateNodes`) once no followed probe
    /// needs the node, so there is no give-up timer: the repeated advertisements stopping is the signal.
    private func superviseNode(_ serial: NodeSerial) async {
        guard let input else { return }
        let clock = input.clock
        var attempt = 0
        var backoff = timing.initialBackoff

        while !Task.isCancelled {
            guard nodeWanted(serial), let node = nodes[serial] else {
                nodeSupervisors[serial] = nil
                stateByNode[serial] = nil
                return
            }
            attempt += 1
            setNode(serial, .connecting(attempt: attempt))
            let startedAt = clock.monotonic()
            if let ended = await connectAndRunNode(serial, node, input), ended - startedAt >= timing.stableAfter {
                attempt = 0
                backoff = timing.initialBackoff
            }
            guard !Task.isCancelled else { return }

            let wait = backoff
            backoff = min(backoff * 2, timing.maxBackoff)
            setNode(serial, .backoff(attempt: attempt, retryAt: clock.monotonic() + wait))
            do { try await clock.sleep(for: wait) } catch { return }
        }
    }

    /// One connection attempt to a node and, if it succeeds, the life of the link. Returns the monotonic
    /// time the link ended, or nil if no link was established.
    private func connectAndRunNode(_ serial: NodeSerial, _ node: NodeInfo,
                                   _ input: ConnectionPolicyInput) async -> Duration? {
        let connection: any GattConnection
        do {
            connection = try await input.transport.connect(node.peripheral, timeout: timing.connectTimeout)
        } catch {
            return nil
        }
        let link = NodeLink(serial: serial, productType: node.productType, connection: connection, clock: input.clock)
        await input.delegate.nodeLinkCreated(link)
        let drops = link.disconnected
        do {
            try await link.start()
        } catch {
            await link.close()
            await input.delegate.nodeLinkEnded(serial: serial, reason: .requested)
            return nil
        }
        setNode(serial, .connected)
        nodeLinks[serial] = link
        await input.delegate.nodeLinkEstablished(link)
        var reason = DisconnectReason.linkLost
        for await r in drops {
            reason = r
            break
        }
        nodeLinks[serial] = nil
        await link.close()
        if Task.isCancelled { reason = .requested }
        await input.delegate.nodeLinkEnded(serial: serial, reason: reason)
        return input.clock.monotonic()
    }
}
