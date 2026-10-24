import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// M3 exit: connect mid-cook and get the full graph; reconnect after out-of-range without gaps.
struct M3HistoryTests {
    private let period = 5.0

    /// Every seq 0...max present, in order, and each sample's time matches when the probe made it.
    private func expectComplete(_ rig: E2ERig, _ probe: SimulatedProbe, session index: Int = 0,
                                timeOf: (UInt32) -> Date, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let series = try await rig.series(probe.serial, session: index)
        let max = probe.logRange.max
        #expect(series.samples.map(\.seq) == contiguous(0...max), sourceLocation: sourceLocation)
        for s in series.samples where s.seq % 50 == 0 || s.seq == max {
            #expect(abs(s.time.timeIntervalSince(timeOf(s.seq))) < 0.5, "seq \(s.seq)", sourceLocation: sourceLocation)
        }
        // Content is the probe's own data.
        for s in series.samples where s.seq % 97 == 0 {
            let r = try #require(probe.record(s.seq))
            #expect(abs(s.temperatures[0] - r.temperatures[.t1]) < 0.001, sourceLocation: sourceLocation)
        }
    }

    @Test func followMidCookBackfillsEverySeq() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 500)
        let t500 = rig.clock.now() // the moment the probe's latest record (seq 500) was made
        await rig.app.start()
        await rig.run(.seconds(3), step: .seconds(1))
        #expect(await rig.app.history.loadFollowedIsEmpty())

        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(10)))
        // First status after connect arrives within one sample period; then live fetch + backfill.
        await rig.run(.seconds(10))
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) ?? 0 >= 501 })

        try await expectComplete(rig, probe) { t500.addingTimeInterval(Double(Int($0) - 500) * period) }
        let sessions = try await rig.app.history.sessions(serial: serialA)
        #expect(sessions.count == 1)
        #expect(sessions[0].key.sessionId == 1)
        #expect(sessions[0].samplePeriod == period)
        #expect(sessions[0].end == nil)

        // Live from here on: new records arrive one per period, no gaps.
        await rig.run(.seconds(60))
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) == probe.recordCount })
        try await expectComplete(rig, probe) { t500.addingTimeInterval(Double(Int($0) - 500) * period) }

        // Backfill requested the old part (the live fetch only asks for the newest 128).
        let reads = probe.requests.compactMap { r -> ClosedRange<UInt32>? in
            if case .readLogs(let s, let e) = r { return s...e } else { return nil }
        }
        let live = try #require(reads.first)
        #expect(live.count == 128, "the live fetch asks for the newest 128 only")
        #expect(live.upperBound >= 500)
        #expect(reads.dropFirst().first?.upperBound == live.lowerBound - 1, "backfill continues below it, newest first")
        #expect(reads.contains { $0.lowerBound == 0 })
        await rig.app.stop()
    }

    @Test func outOfRangeThreeMinutesReconnectsWithBackoffAndBackfills() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 100)
        let t100 = rig.clock.now()
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(30))
        #expect(await rig.connected(serialA))
        let seqsBefore = try await rig.storedSeqs(serialA)
        #expect(seqsBefore.count >= 100)
        let connectsBefore = rig.spy.attempts.count

        // Out of range for 3 minutes of cooking.
        probe.setInRange(false)
        await rig.drain()
        let drop = rig.clock.monotonic()
        await rig.run(.seconds(180))
        #expect(await rig.app.diagnostics().links[serialA] != .connected)
        // Backoff 1, 2, 4, 8, 16, then 30 s steps: attempts at +1, +3, +7, +15, +31, +61, +91 ...
        let attempts = rig.spy.attempts.dropFirst(connectsBefore).map { ($0 - drop).totalSeconds }
        expectSchedule(Array(attempts.prefix(8)), [1, 3, 7, 15, 31, 61, 91, 121])
        // The probe kept logging meanwhile, so history has a hole right now.
        let mid = try await rig.storedSeqs(serialA)
        #expect(probe.logRange.max > (mid.last ?? 0) + 30)

        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(40)))
        await rig.run(.seconds(30))
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) ?? 0 >= probe.recordCount - 1 })
        await rig.run(.seconds(10))

        try await expectComplete(rig, probe) { t100.addingTimeInterval(Double(Int($0) - 100) * period) }
        #expect(try await rig.app.history.sessions(serial: serialA).count == 1)
        await rig.app.stop()
    }

    @Test func chargerRemovalStartsSecondSessionAndClosesFirstWithThumbnail() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 60, sessionId: 7)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(60))
        #expect(await rig.connected(serialA))

        probe.setInRange(false)
        await rig.run(.seconds(20))
        probe.newSession() // session 8, log restarts at seq 0
        let t0 = rig.clock.now()
        #expect(probe.sessionId == 8)
        await rig.run(.seconds(60))
        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(40)))
        await rig.run(.seconds(30))

        let sessions = try await rig.app.history.sessions(serial: serialA) // newest first
        #expect(sessions.count == 2)
        #expect(sessions.map(\.key.sessionId) == [8, 7])
        #expect(sessions[0].end == nil)
        let closed = sessions[1]
        #expect(closed.end != nil)
        #expect(!closed.thumbnail.isEmpty)
        #expect(closed.sampleCount >= 60)

        // The new session holds only the new log, from seq 0, with no gaps.
        try await expectComplete(rig, probe, session: 0) { t0.addingTimeInterval(Double($0) * period) }
        // The old session was not polluted with the new log.
        let old = try await rig.storedSeqs(serialA, session: 1)
        #expect(old == contiguous(0...(old.last ?? 0)))
        #expect((old.last ?? 0) < 100)
        await rig.app.stop()
    }

    @Test func legacyFirmwareWithoutSessionIdWorks() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 120)
        probe.legacyFirmware = true
        let t120 = rig.clock.now()
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(60))
        #expect(await rig.connected(serialA))

        var sessions = try await rig.app.history.sessions(serial: serialA)
        #expect(sessions.count == 1)
        #expect(sessions[0].key.sessionId == 0)
        #expect(sessions[0].samplePeriod == 5) // default when the status carries none
        #expect(await rig.eventually { (try? await rig.storedSeqs(serialA).count) == probe.recordCount })
        try await expectComplete(rig, probe) { t120.addingTimeInterval(Double(Int($0) - 120) * period) }
        let snap = try #require(await rig.app.probes.snapshot(of: serialA))
        #expect(snap.session?.info == nil)
        #expect(snap.link.primary?.kind == .directConnection)

        // Fallback session detection: the log restarts (max drops) while the probe was away.
        probe.setInRange(false)
        await rig.run(.seconds(10))
        probe.newSession()
        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(40)))
        await rig.run(.seconds(20))
        sessions = try await rig.app.history.sessions(serial: serialA)
        #expect(sessions.count == 2)
        #expect(sessions[1].end != nil)
        #expect(try await rig.storedSeqs(serialA, session: 0) == contiguous(0...probe.logRange.max))
        await rig.app.stop()
    }

    /// fw v2.3.3 (spec/replays/charger-new-session): the 94 B status has no session id, but Read Session Info works.
    @Test func sessionIdIsReadOverUartWhenTheStatusHasNone() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 60, sessionId: 7)
        probe.statusWithoutSession = true
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(30))
        #expect(await rig.connected(serialA))

        var sessions = try await rig.app.history.sessions(serial: serialA)
        #expect(sessions.count == 1)
        #expect(sessions[0].key.sessionId == 7)
        #expect(try #require(await rig.app.probes.snapshot(of: serialA)).session?.info?.sessionId == 7)
        let reads = probe.requests.filter { if case .readSessionInfo = $0 { true } else { false } }
        #expect(reads.count == 1, "read once per link, not per status")

        // A charger cycle while away: the new link reads the new id and history splits the cook.
        probe.setInRange(false)
        await rig.run(.seconds(10))
        probe.newSession()
        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(40)))
        await rig.run(.seconds(20))
        sessions = try await rig.app.history.sessions(serial: serialA)
        #expect(sessions.map(\.key.sessionId) == [8, 7])
        #expect(try await rig.storedSeqs(serialA, session: 0) == contiguous(0...probe.logRange.max))
        await rig.app.stop()
    }

    @Test func unfollowedProbeIsNeverConnectedOrRecorded() async throws {
        let rig = try E2ERig()
        let a = rig.probe(serialA, preload: 10)
        let b = rig.probe(serialB, preload: 10)
        defer { a.stop(); b.stop() }
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(30))
        #expect(await rig.connected(serialA))
        #expect(rig.transport.isConnected(PeripheralId("PROBE-\(serialA.hex)")))
        #expect(!rig.transport.isConnected(PeripheralId("PROBE-\(serialB.hex)")))
        #expect(try await rig.app.history.sessions(serial: serialB).isEmpty)
        #expect(try await rig.app.history.sessions(serial: serialA).count == 1)

        await rig.app.unfollow(serialA)
        await rig.run(.seconds(10))
        #expect(!rig.transport.isConnected(PeripheralId("PROBE-\(serialA.hex)")))
        #expect(await rig.app.diagnostics().links.isEmpty)
        let attempts = rig.spy.attempts.count
        await rig.run(.seconds(60))
        #expect(rig.spy.attempts.count == attempts)
        await rig.app.stop()
    }
    @Test func theCookNameReachesHistoryAndTheWidgetSnapshot() async throws {
        let rig = try E2ERig(liveSnapshot: FileLiveSnapshotWriter(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("colby-live-\(UUID().uuidString).json")))
        let probe = rig.probe(serialA, preload: 10)
        await rig.app.start()
        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(20)))
        await rig.run(.seconds(10))

        try await rig.app.setCookName("Brisket", for: serialA)
        #expect(try await rig.app.history.sessions(serial: serialA).first?.nickname == "Brisket")
        let writer = try #require(rig.app.liveSnapshot)
        #expect(await rig.eventually { await writer.current().probes.first?.name == "Brisket" })
        await rig.app.stop()
        withExtendedLifetime(probe) {}
    }
}

extension HistoryStore {
    /// True when no probe is persisted as followed.
    func loadFollowedIsEmpty() async -> Bool { ((try? await loadFollowed()) ?? []).isEmpty }
}
