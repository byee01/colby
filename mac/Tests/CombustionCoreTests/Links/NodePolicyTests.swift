import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// Records the links a policy creates (probe and node).
private final class RecordingDelegate: ConnectionPolicyDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _nodesEstablished: [NodeSerial] = []
    private var _nodesEnded: [(NodeSerial, DisconnectReason)] = []
    private var _probesEstablished: [ProbeSerial] = []

    var nodesEstablished: [NodeSerial] { lock.withLock { _nodesEstablished } }
    var nodesEnded: [(NodeSerial, DisconnectReason)] { lock.withLock { _nodesEnded } }
    var probesEstablished: [ProbeSerial] { lock.withLock { _probesEstablished } }

    func linkCreated(_ link: DirectProbeLink) async {}
    func linkEstablished(_ link: DirectProbeLink) async { lock.withLock { _probesEstablished.append(link.serial) } }
    func linkEnded(serial: ProbeSerial, reason: DisconnectReason) async {}
    func nodeLinkEstablished(_ link: NodeLink) async { lock.withLock { _nodesEstablished.append(link.serial) } }
    func nodeLinkEnded(serial: NodeSerial, reason: DisconnectReason) async {
        lock.withLock { _nodesEnded.append((serial, reason)) }
    }
}

/// Drives a `DirectConnectionPolicy` with hand-fed sightings over a `SimulatedTransport`.
private final class PolicyRig: @unchecked Sendable {
    let clock = TestClock(wakeGrace: .microseconds(500))
    let transport: SimulatedTransport
    let spy: ConnectSpyTransport
    let delegate = RecordingDelegate()
    let policy: DirectConnectionPolicy

    private let sightings = AsyncStream<ProbeSighting>.makeStream()
    private let followed = AsyncStream<Set<ProbeSerial>>.makeStream()
    private let nodes = AsyncStream<NodeSighting>.makeStream()
    private let repeated = AsyncStream<RepeatedProbeSighting>.makeStream()

    static let nodePeripheral: PeripheralId = "NODE-1"
    static let probePeripheral: PeripheralId = "PROBE-1"

    init() {
        transport = SimulatedTransport(clock: clock)
        spy = ConnectSpyTransport(inner: transport, clock: clock)
        policy = DirectConnectionPolicy()
    }

    func start() async {
        await policy.start(ConnectionPolicyInput(
            transport: spy, clock: clock, sightings: sightings.stream, followed: followed.stream, delegate: delegate,
            nodeSightings: nodes.stream, repeatedSightings: repeated.stream))
    }

    func follow(_ serials: Set<ProbeSerial>) { followed.continuation.yield(serials) }

    func probeHeard(_ serial: ProbeSerial = linkProbe) {
        sightings.continuation.yield(ProbeSighting(
            serial: serial, peripheral: Self.probePeripheral, rssi: -50, time: clock.now()))
    }

    func nodeHeard(_ serial: NodeSerial = "DISPLAY001", type: NodeProductType = .display) {
        nodes.continuation.yield(NodeSighting(
            serial: serial, productType: type, peripheral: Self.nodePeripheral, rssi: -50, time: clock.now()))
    }

    func repeatedHeard(_ serial: ProbeSerial = linkProbe, via peripheral: PeripheralId = PolicyRig.nodePeripheral) {
        repeated.continuation.yield(RepeatedProbeSighting(
            serial: serial, nodePeripheral: peripheral, via: nil, hopCount: 1, rssi: -50, time: clock.now()))
    }

    /// Hears the node and the probe through it every second for `seconds`.
    func run(_ seconds: Int, repeating: Bool = true) async {
        for _ in 0..<seconds {
            if repeating {
                nodeHeard()
                repeatedHeard()
            }
            await clock.advance(by: .seconds(1))
            await settle()
        }
    }

    func settle() async {
        for _ in 0..<20 {
            try? await Task.sleep(for: .milliseconds(1))
            await clock.settle()
        }
    }
}

struct NodePolicyTests {
    @Test func connectsToTheNodeAtOnceWhenAFollowedProbeIsRepeatedByIt() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        await rig.run(2)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)
        #expect(rig.delegate.nodesEstablished == ["DISPLAY001"])
        #expect(rig.spy.attempts.count == 1)
        #expect(rig.transport.isConnected(PolicyRig.nodePeripheral))
        #expect(await rig.policy.states()[linkProbe] == .viaNode("DISPLAY001"))
        await rig.policy.stop()
        #expect(!rig.transport.isConnected(PolicyRig.nodePeripheral))
        #expect(rig.delegate.nodesEnded.map(\.1) == [.requested])
    }

    @Test func nodeCoveringTheProbeMeansNoDirectConnection() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        rig.probeHeard() // the probe's own advertisement too, yet the node wins
        await rig.run(30)
        #expect(await rig.policy.states()[linkProbe] == .viaNode("DISPLAY001"))
        #expect(rig.delegate.probesEstablished.isEmpty)
        #expect(rig.delegate.nodesEstablished == ["DISPLAY001"])
        #expect(!rig.transport.isConnected(PolicyRig.probePeripheral))
        #expect(rig.spy.attempts.count == 1)
        await rig.policy.stop()
    }

    @Test func probeNotRepeatedByAnyNodeIsConnectedDirectly() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard() // a node is in range, but does not repeat this probe
        rig.probeHeard()
        await rig.run(10, repeating: false)
        #expect(await rig.policy.states()[linkProbe] == .connected)
        #expect(rig.delegate.nodesEstablished.isEmpty)
        await rig.policy.stop()
    }

    @Test func unreachableNodeLetsTheProbeFallBackToDirect() async throws {
        let rig = PolicyRig()
        rig.transport.blockConnects(to: PolicyRig.nodePeripheral)
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        rig.probeHeard()
        await rig.run(20)
        #expect(await rig.policy.states()[linkProbe] == .connected)
        guard case .backoff = try #require(await rig.policy.nodeStates()["DISPLAY001"]) else {
            Issue.record("node side should be backing off")
            return
        }
        await rig.policy.stop()
    }

    @Test func nodeDropFallsBackToDirectThenNodeReturnsAndReleasesTheDirectLink() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        rig.probeHeard()
        await rig.run(5)
        #expect(await rig.policy.states()[linkProbe] == .viaNode("DISPLAY001"))

        // The node goes away (drops and is unreachable): direct, from the initial backoff.
        rig.transport.blockConnects(to: PolicyRig.nodePeripheral)
        rig.transport.forceDisconnect(PolicyRig.nodePeripheral, reason: .linkLost)
        await rig.run(8, repeating: false)
        for _ in 0..<5 {
            rig.probeHeard()
            await rig.run(1, repeating: false)
        }
        #expect(await rig.policy.states()[linkProbe] == .connected)
        #expect(rig.transport.isConnected(PolicyRig.probePeripheral))

        // The node comes back: it takes over and the direct link is closed.
        rig.transport.allowConnects(to: PolicyRig.nodePeripheral)
        await rig.run(30)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)
        #expect(!rig.transport.isConnected(PolicyRig.probePeripheral))
        #expect(await rig.policy.states()[linkProbe] == .viaNode("DISPLAY001"))
        await rig.policy.stop()
    }

    @Test func nothingFollowedMeansNoNodeConnection() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.nodeHeard()
        rig.repeatedHeard()
        await rig.run(20)
        #expect(rig.spy.attempts.isEmpty)
        // Following a different probe than the one the node repeats changes nothing either.
        rig.follow([otherProbe])
        await rig.run(20)
        #expect(rig.spy.attempts.isEmpty)
        await rig.policy.stop()
    }

    @Test func nodeNotYetIdentifiedByItsOwnAdvertisementWaits() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        await rig.run(10, repeating: false)
        rig.repeatedHeard()
        await rig.run(5, repeating: false)
        #expect(rig.spy.attempts.isEmpty, "the repeated advertisement alone has no node serial yet")
        rig.nodeHeard()
        rig.repeatedHeard()
        await rig.run(5)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)
        await rig.policy.stop()
    }

    @Test func refusedNodeConnectsBackOffLikeProbes() async throws {
        let rig = PolicyRig()
        rig.transport.refuseConnects(3)
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        await rig.run(30)
        // Refused at once, +1, +2, +4 (the 4th attempt works).
        let t = rig.spy.attempts.map(\.totalSeconds)
        expectSchedule(t.map { $0 - t[0] }, [0, 1, 3, 7])
        #expect(t[0] <= 3)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)
        await rig.policy.stop()
    }

    @Test func droppedNodeReconnectsWhileStillRepeatedAndStopsWhenNot() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        await rig.run(8)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)

        rig.transport.forceDisconnect(PolicyRig.nodePeripheral, reason: .linkLost)
        await rig.run(5) // still repeating: back after the 1 s backoff
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)
        #expect(rig.delegate.nodesEnded.map(\.1) == [.linkLost])
        #expect(rig.delegate.nodesEstablished.count == 2)

        // The node goes silent and drops: once the repeated advertisements are stale it is left alone.
        rig.transport.blockConnects(to: PolicyRig.nodePeripheral)
        rig.transport.forceDisconnect(PolicyRig.nodePeripheral, reason: .linkLost)
        await rig.run(40, repeating: false)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == nil)
        let attempts = rig.spy.attempts.count
        await rig.run(60, repeating: false)
        #expect(rig.spy.attempts.count == attempts)

        // Heard again: resumes (after the grace period).
        rig.transport.allowConnects(to: PolicyRig.nodePeripheral)
        await rig.run(8)
        #expect(await rig.policy.nodeStates()["DISPLAY001"] == .connected)
        await rig.policy.stop()
    }

    @Test func unfollowingClosesTheNodeConnection() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard()
        rig.repeatedHeard()
        await rig.run(8)
        #expect(rig.transport.isConnected(PolicyRig.nodePeripheral))
        rig.follow([])
        await rig.run(3)
        #expect(!rig.transport.isConnected(PolicyRig.nodePeripheral))
        #expect(await rig.policy.nodeStates().isEmpty)
        #expect(rig.delegate.nodesEnded.map(\.1) == [.requested])
        await rig.policy.stop()
    }

    @Test func anyNodeProductTypeIsUsed() async throws {
        let rig = PolicyRig()
        await rig.start()
        rig.follow([linkProbe])
        rig.nodeHeard("BOOSTER001", type: .booster)
        rig.repeatedHeard()
        for _ in 0..<8 {
            rig.nodeHeard("BOOSTER001", type: .booster)
            rig.repeatedHeard()
            await rig.clock.advance(by: .seconds(1))
            await rig.settle()
        }
        #expect(await rig.policy.nodeStates()["BOOSTER001"] == .connected)
        await rig.policy.stop()
    }
}
