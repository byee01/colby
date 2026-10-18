import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

let displayD: NodeSerial = "DISPLAY001"

extension E2ERig {
    func node(_ serial: NodeSerial = displayD, relaying probes: [SimulatedProbe] = [], hops: Int = 1) -> SimulatedNode {
        let n = SimulatedNode(serial: serial, transport: transport, clock: clock)
        for p in probes { n.relay(p, hops: hops) }
        n.start()
        return n
    }

    func nodeConnected(_ serial: NodeSerial = displayD) async -> Bool {
        await app.diagnostics().nodeLinks[serial] == .connected
    }

    func snapshot(_ serial: ProbeSerial) async -> ProbeSnapshot? { await app.probes.snapshot(of: serial) }
}

/// M4 exit: a probe out of the Mac's range but in the Display's range still updates and backfills via the node.
struct M4MeatNetTests {
    private let period = 5.0

    private func readLogCount(_ probe: SimulatedProbe) -> Int {
        probe.requests.filter { if case .readLogs = $0 { true } else { false } }.count
    }

    @Test func probeLeavesMacRangeButStaysInDisplayRangeAndBackfillsViaNode() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 60)
        let t60 = rig.clock.now()
        let display = rig.node(relaying: [probe])
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(30))
        #expect(await rig.connected(serialA))
        #expect(!(await rig.nodeConnected()), "direct wins: no node connection while the probe is connectable")
        #expect(!rig.transport.isConnected(display.peripheral))
        #expect(try await rig.storedSeqs(serialA).count >= 60)
        let directReads = readLogCount(probe)

        // Out of the Mac's range for 3 minutes of cooking; the Display still hears the probe.
        probe.setInRange(false)
        await rig.drain()
        #expect(await rig.run(until: { await rig.nodeConnected() }, limit: .seconds(30)))
        await rig.run(.seconds(180))

        // Live data arrives through the node.
        let snap = try #require(await rig.snapshot(serialA))
        let primary = try #require(snap.link.primary)
        #expect(primary.kind == .nodeConnection)
        #expect(primary.via == displayD)
        #expect(primary.hopCount == 1)
        #expect(!snap.isOffline)
        let record = try #require(probe.record(probe.logRange.max))
        #expect(abs((snap.temperatures[0] ?? 0) - record.temperatures[.t1]) < 0.1)
        #expect(abs(snap.receivedAt.timeIntervalSince(rig.clock.now())) < 10)

        // History is complete, filled through the node: the probe itself saw no Read Logs since the drop.
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) ?? 0 >= probe.recordCount - 1 })
        let seqs = try await rig.storedSeqs(serialA)
        #expect(seqs == contiguous(0...(seqs.last ?? 0)))
        #expect((seqs.last ?? 0) >= probe.logRange.max - 1)
        #expect(readLogCount(probe) == directReads)
        let nodeReads = display.requests.filter { if case .readLogs = $0.request { true } else { false } }
        #expect(!nodeReads.isEmpty)
        #expect(nodeReads.allSatisfy { $0.probe == serialA })
        // Times line up with when the probe made the samples.
        let series = try await rig.series(serialA)
        let sample = try #require(series.samples.first { $0.seq == 100 })
        #expect(abs(sample.time.timeIntervalSince(t60.addingTimeInterval(40 * period))) < 1.5)

        await rig.app.stop()
        #expect(!rig.transport.isConnected(display.peripheral))
    }

    @Test func probeNeverInMacRangeIsFollowedBackfilledAndLiveThroughNode() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 200)
        probe.setInRange(false)
        let display = rig.node(relaying: [probe], hops: 2)
        display.setDeviceInfo(DeviceInfo(firmware: "v2.0.1", hardware: "rev C", model: "Display"))
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(2), step: .seconds(1))
        // Only the Display's repeated advertisement is heard, so the probe shows up (offline of any connection).
        #expect(await rig.app.diagnostics().links[serialA] == .waitingForAdvertisement)
        #expect(try #require(await rig.snapshot(serialA)).link.primary?.kind == .nodeAdvertisement)

        #expect(await rig.run(until: { await rig.nodeConnected() }, limit: .seconds(30)))
        await rig.run(.seconds(40))
        #expect(await rig.app.diagnostics().links[serialA] == .waitingForAdvertisement)
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))
        let snap = try #require(await rig.snapshot(serialA))
        #expect(snap.link.primary?.kind == .nodeConnection)
        #expect(snap.link.primary?.hopCount == 2)
        #expect(snap.session?.info?.sessionId == 1)

        // The node itself is visible to the UI.
        let nodes = await rig.app.probes.nodeSnapshots()
        let node = try #require(nodes[displayD])
        #expect(node.isConnected)
        #expect(node.productType == .display)
        #expect(node.probes == [serialA])
        #expect(node.hopCounts == [serialA: 2])
        #expect(node.firmware == DeviceInfo(firmware: "v2.0.1", hardware: "rev C", model: "Display"))
        #expect(node.heartbeatCount > 10)
        #expect(node.link.kind == .directConnection)
        await rig.app.stop()
    }

    @Test func probeComingBackInMacRangeGetsADirectLinkAndDirectWins() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 40)
        probe.setInRange(false)
        let display = rig.node(relaying: [probe])
        await rig.app.start()
        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.nodeConnected() }, limit: .seconds(30)))
        await rig.run(.seconds(30))
        #expect(try #require(await rig.snapshot(serialA)).link.primary?.kind == .nodeConnection)

        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(30)))
        await rig.run(.seconds(20))
        let snap = try #require(await rig.snapshot(serialA))
        #expect(snap.link.primary?.kind == .directConnection)
        #expect(snap.link.sources.contains { $0.kind == .nodeConnection && $0.via == displayD })
        #expect(await rig.nodeConnected(), "the node link stays up as a fallback")
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))

        // And back: the node covers the probe again with no gap.
        probe.setInRange(false)
        await rig.run(.seconds(60))
        #expect(try #require(await rig.snapshot(serialA)).link.primary?.kind == .nodeConnection)
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) ?? 0 >= probe.recordCount - 1 })
        _ = display
        await rig.app.stop()
    }

    @Test func nodeDropsAndComesBackWithBackoffAndTheProbeKeepsFillingIn() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 20)
        probe.setInRange(false)
        let display = rig.node(relaying: [probe])
        await rig.app.start()
        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.nodeConnected() }, limit: .seconds(30)))
        await rig.run(.seconds(20))

        display.setInRange(false) // the Display is switched off / carried away
        await rig.drain()
        await rig.run(.seconds(60))
        #expect(await rig.app.diagnostics().nodeLinks[displayD] == nil, "nothing relays the probe, so the policy stops trying")
        #expect(!(await rig.nodeConnected()))
        let during = try await rig.storedSeqs(serialA)
        #expect(probe.logRange.max > (during.last ?? 0) + 5)
        #expect(try #require(await rig.snapshot(serialA)).isOffline)

        display.setInRange(true)
        #expect(await rig.run(until: { await rig.nodeConnected() }, limit: .seconds(40)))
        await rig.run(.seconds(40))
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) ?? 0 >= probe.recordCount - 1 })
        let seqs = try await rig.storedSeqs(serialA)
        #expect(seqs == contiguous(0...(seqs.last ?? 0)))
        await rig.app.stop()
    }

    @Test func nodeSeenButNothingFollowedIsNeverConnected() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 10)
        probe.setInRange(false)
        let display = rig.node(relaying: [probe])
        await rig.app.start()
        await rig.run(.seconds(30))
        #expect(!rig.transport.isConnected(display.peripheral))
        let node = try #require(await rig.app.probes.nodeSnapshots()[displayD])
        #expect(!node.isConnected)
        #expect(node.link.kind == .nodeAdvertisement)
        #expect(node.probes.isEmpty)
        // The probe's live temperature is still visible from the repeated advertisement alone.
        #expect(try #require(await rig.snapshot(serialA)).link.primary?.kind == .nodeAdvertisement)

        // Unfollowing closes a node connection that was only there for that probe.
        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.nodeConnected() }, limit: .seconds(30)))
        await rig.app.unfollow(serialA)
        await rig.run(.seconds(5))
        #expect(!rig.transport.isConnected(display.peripheral))
        await rig.app.stop()
    }
}
