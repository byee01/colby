import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// docs/02 §5.6, direct-only: backoff 1, 2, 4 ... 30 s; give up after 5 min absent; resume on reappearance.
struct ConnectionPolicyE2ETests {
    @Test func givesUpAfterFiveMinutesAbsentAndResumesWhenItReappears() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 30)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(20))
        #expect(await rig.connected(serialA))

        probe.setInRange(false)
        await rig.drain()
        let left = rig.clock.monotonic()

        // Still trying just before the limit ...
        await rig.run(.seconds(290))
        let state = try #require(await rig.app.diagnostics().links[serialA])
        guard case .backoff = state else { Issue.record("expected backoff, got \(state)"); return }
        // ... and gives up at 5 min (checked a few seconds after, to allow for a late wake on a busy machine).
        await rig.run(.seconds(15))
        #expect(await rig.app.diagnostics().links[serialA] == .gaveUp)
        let attempts = rig.spy.attempts.filter { $0 > left }.map { ($0 - left).totalSeconds }
        expectSchedule(attempts, [1, 3, 7, 15, 31, 61, 91, 121, 151, 181, 211, 241, 271])
        #expect(attempts.allSatisfy { $0 < 300 })

        // Stays given up (no more connects) while absent.
        let count = rig.spy.attempts.count
        await rig.run(.seconds(240))
        #expect(rig.spy.attempts.count == count)
        #expect(await rig.app.diagnostics().links[serialA] == .gaveUp)

        // Reappears: resumes at once (no backoff wait) and backfills the 9 minutes it missed.
        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(5)))
        #expect(rig.spy.attempts.count == count + 1)
        await rig.run(.seconds(20))
        let seqs = try await rig.storedSeqs(serialA)
        #expect(seqs == contiguous(0...probe.logRange.max))
        #expect(probe.logRange.max > 30 + 100)
        await rig.app.stop()
    }

    @Test func refusedConnectsBackOffThenSucceed() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 5)
        rig.transport.refuseConnects(3)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(20))
        #expect(await rig.connected(serialA))
        // Heard at t=0.25; refused at once, then +1, +2, +4 later it works.
        let attempts = rig.spy.attempts.map { ($0 - rig.spy.attempts[0]).totalSeconds }
        expectSchedule(attempts, [0, 1, 3, 7])
        probe.stop()
        await rig.app.stop()
    }

    @Test func connectTimeoutCountsAsFailureAndBacksOff() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 5)
        rig.transport.setConnectDelay(.seconds(30)) // longer than the 10 s connect timeout
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(10))
        guard case .connecting(let attempt) = try #require(await rig.app.diagnostics().links[serialA]) else {
            Issue.record("expected connecting")
            return
        }
        #expect(attempt == 1)
        await rig.run(.seconds(1)) // timed out at 10.25 s, now waiting 1 s
        guard case .backoff(_, let retryAt) = try #require(await rig.app.diagnostics().links[serialA]) else {
            Issue.record("expected backoff")
            return
        }
        #expect(retryAt.totalSeconds > rig.clock.monotonic().totalSeconds)
        rig.transport.setConnectDelay(.zero)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(60)))
        probe.stop()
        await rig.app.stop()
    }

    @Test func oneConnectionPerProbeAndNoReconnectChurnWhileConnected() async throws {
        let rig = try E2ERig()
        let a = rig.probe(serialA, preload: 5)
        let b = rig.probe(serialB, preload: 5)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.app.follow(serialB)
        await rig.run(.seconds(20))
        #expect(await rig.connected(serialA))
        #expect(await rig.connected(serialB))
        #expect(rig.spy.attempts.count == 2)
        // Following twice or re-following changes nothing.
        await rig.app.follow(serialA)
        await rig.run(.seconds(120))
        #expect(rig.spy.attempts.count == 2)
        a.stop()
        b.stop()
        await rig.app.stop()
        #expect(!rig.transport.isConnected(a.peripheral))
        #expect(!rig.transport.isConnected(b.peripheral))
    }

    @Test func bluetoothOffDropsLinksAndComesBackWithScanning() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 20)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(20))
        #expect(await rig.connected(serialA))

        rig.transport.setState(.poweredOff)
        await rig.run(.seconds(20))
        #expect(await rig.app.diagnostics().bluetooth == .poweredOff)
        #expect(await rig.app.diagnostics().links[serialA] != .connected)

        rig.transport.setState(.poweredOn)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(60)))
        await rig.run(.seconds(20))
        #expect(await rig.app.diagnostics().bluetooth == .poweredOn)
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))
        await rig.app.stop()
    }

    @Test func followedSetSurvivesRestartThroughTheDatabase() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("colby-e2e-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        do {
            let clock = TestClock()
            let app = try CombustionApp(transport: SimulatedTransport(clock: clock), clock: clock, databasePath: path)
            await app.follow(serialA)
        }
        let clock = TestClock()
        let app = try CombustionApp(transport: SimulatedTransport(clock: clock), clock: clock, databasePath: path)
        await app.start()
        #expect(await app.probes.followedSerials() == [serialA])
        await app.stop()
    }
}
