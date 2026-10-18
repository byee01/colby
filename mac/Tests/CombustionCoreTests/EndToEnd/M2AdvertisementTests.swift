import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// M2 exit: live 8-sensor temps for all nearby probes, from advertisements alone.
struct M2AdvertisementTests {
    @Test func threeProbesShowEightTempsAndGoOfflineAfterTenSeconds() async throws {
        let rig = try E2ERig()
        let a = rig.probe(serialA, preload: 100)
        let b = rig.probe(serialB, preload: 200, offset: 5)
        let c = rig.probe(serialC, preload: 300, offset: 10)
        await rig.app.start()
        await rig.run(.seconds(2), step: .seconds(1))

        #expect(await rig.eventually { await rig.app.probes.snapshots().count == 3 })
        let snaps = await rig.app.probes.snapshots()
        for (serial, probe) in [(serialA, a), (serialB, b), (serialC, c)] {
            let s = try #require(snaps[serial])
            #expect(s.temperatures.count == 8)
            #expect(s.temperatures.allSatisfy { $0 != nil })
            #expect(!s.isOffline)
            #expect(s.link.primary?.kind == .advertisement)
            let expected = try #require(probe.record(probe.logRange.max)).temperatures.celsius
            for i in 0..<8 { #expect(abs(try #require(s.temperatures[i]) - expected[i]) < 0.06) }
        }
        // Different curves, so the probes are told apart.
        #expect(snaps[serialA]!.temperatures[0]! != snaps[serialC]!.temperatures[0]!)

        // Live: temperatures keep moving without any connection.
        let before = snaps[serialA]!.temperatures[7]!
        await rig.run(.seconds(60), step: .seconds(5))
        let after = try #require(await rig.app.probes.snapshot(of: serialA)).temperatures[7]!
        #expect(after != before)
        #expect(rig.spy.attempts.isEmpty, "unfollowed probes are never connected")

        // A goes out of range: still shown just before the 10 s source timeout, offline after it.
        a.setInRange(false)
        await rig.run(.seconds(8), step: .seconds(1))
        #expect(try #require(await rig.app.probes.snapshot(of: serialA)).isOffline == false)
        await rig.run(.seconds(4), step: .seconds(1))
        #expect(try #require(await rig.app.probes.snapshot(of: serialA)).isOffline)
        #expect(try #require(await rig.app.probes.snapshot(of: serialB)).isOffline == false)
        #expect(try #require(await rig.app.probes.snapshot(of: serialC)).isOffline == false)

        // And back.
        a.setInRange(true)
        await rig.run(.seconds(1), step: .seconds(1))
        #expect(try #require(await rig.app.probes.snapshot(of: serialA)).isOffline == false)

        let d = await rig.app.diagnostics()
        #expect(d.bluetooth == .poweredOn)
        #expect(d.advertisements.probePackets > 100)
        #expect(d.advertisements.codecErrors == 0)
        #expect(d.links.isEmpty)
        await rig.app.stop()
    }
}
