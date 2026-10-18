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

public extension ConnectionPolicy {
    func nodeStates() async -> [NodeSerial: ProbeConnectionState] { [:] }
}

/// Default policy:
/// 1. Scanning is the app's job (always on); this policy reacts to what the scan hears.
/// 2. Connect directly to each followed probe once its own advertisement has been heard. Direct wins:
///    a probe that is connected (or on its first attempt) never needs a node.
/// 3. MeatNet node step: when a followed probe is not directly connectable (no advertisement of its own,
///    a retry after a failure, or given up) but a node repeats its advertisement, connect to that node
///    after a short grace period. One node connection serves every probe on its network, and its statuses
///    and logs fill in while the probe is out of range. It stays up until it drops; the node is retried
///    (same backoff) only while a followed probe is still heard through it and still lacks a direct link.
/// 4. Reconnect with backoff 1, 2, 4 ... 30 s. Give up on a probe when it has been absent from advertisements
///    for 5 min (absence counts from the later of the last advertisement and the end of the last link);
///    resume as soon as it advertises again.
/// 5. At most one connection per probe: one supervisor task per followed probe, and one per node.
public actor DirectConnectionPolicy: ConnectionPolicy {
    public struct Timing: Sendable {
        public var initialBackoff: Duration = .seconds(1)
        public var maxBackoff: Duration = .seconds(30)
        public var absentLimit: Duration = .seconds(300)
        public var connectTimeout: Duration = .seconds(10)
        /// A link that lasted this long counts as healthy: the next reconnect starts from `initialBackoff`.
        public var stableAfter: Duration = .seconds(10)
        /// How long a probe must stay without a direct link before its node is connected, so a direct
        /// connection that is about to succeed wins.
        public var nodeGrace: Duration = .seconds(3)
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
        var reason = DisconnectReason.linkLost
        for await r in drops {
            reason = r
            break
        }
        await link.close()
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

    /// A followed probe heard through the node has no usable direct link: not connected, and not on its
    /// first direct attempt (which may be about to succeed).
    private func nodeWanted(_ serial: NodeSerial) -> Bool {
        followedViaNode(serial).contains { probe in
            switch stateByProbe[probe] {
            case .connected?, .connecting(attempt: 1)?: return false
            default: return true
            }
        }
    }

    /// Starts a supervisor for every node that is wanted and has none. Cheap; called on every input.
    private func evaluateNodes() {
        guard input != nil else { return }
        for serial in nodes.keys where nodeSupervisors[serial] == nil && nodeWanted(serial) {
            stateByNode[serial] = .waitingForAdvertisement // waiting out the grace period
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
        do { try await clock.sleep(for: timing.nodeGrace) } catch { return }

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
        await input.delegate.nodeLinkEstablished(link)
        var reason = DisconnectReason.linkLost
        for await r in drops {
            reason = r
            break
        }
        await link.close()
        if Task.isCancelled { reason = .requested }
        await input.delegate.nodeLinkEnded(serial: serial, reason: reason)
        return input.clock.monotonic()
    }
}
