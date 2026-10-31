import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// Lossy links and mid-download disconnects must still end in a complete history.
struct FaultInjectionE2ETests {
    private func readRanges(_ probe: SimulatedProbe) -> [ClosedRange<UInt32>] {
        probe.requests.compactMap { r in
            if case .readLogs(let s, let e) = r { return s...e } else { return nil }
        }
    }

    @Test func notificationsDroppedDuringDownloadAreFilledByTheNextBackfillPass() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 300)
        // The live fetch takes 128 responses (173...300 or so). Then the first backfill chunk starts:
        // let 40 of its records through and lose the next 3.
        rig.transport.dropNextNotifications(3, after: 128 + 40, on: .uartTX)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(5))
        #expect(await rig.connected(serialA))
        await rig.run(.seconds(30))

        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))
        // The hole was requested twice: once lost, once recovered.
        let ranges = readRanges(probe)
        let live = try #require(ranges.first)
        let lostSeq = (live.lowerBound - 128) + 40 // first record of the backfill chunk below `live`
        let hits = ranges.filter { $0.contains(lostSeq) }.count
        #expect(hits >= 2, "seq \(lostSeq) requested \(hits) times in \(ranges)")
        let d = await rig.app.diagnostics()
        #expect(d.logFetchesInFlight == 0)
        await rig.app.stop()
    }

    @Test func droppedLiveRecordIsRepairedByThePeriodicCheck() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 20)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(30))
        #expect(await rig.connected(serialA))
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))

        // Lose one status, so the next live fetch asks for two records, then lose the first response.
        // The stored max moves past the hole and only the periodic recheck can repair it.
        rig.transport.dropNextNotifications(1, on: .probeStatus)
        await rig.run(.seconds(5))
        rig.transport.dropNextNotifications(1, on: .uartTX)
        await rig.run(.seconds(5))
        let seqs = try await rig.storedSeqs(serialA)
        #expect(seqs.count == Int(probe.logRange.max), "exactly one record is missing right now")
        // Within the next minute the connected-state recheck fills it.
        await rig.run(.seconds(70))
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))
        await rig.app.stop()
    }

    @Test func disconnectMidDownloadCompletesAfterReconnect() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 300)
        probe.dropLinkAfterLogRecords(50) // first Read Logs: 50 records, then the link drops
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(6))
        // The partial download was kept.
        let partial = try await rig.storedSeqs(serialA)
        #expect(partial.count == 51)   // 50 records plus the status's own
        #expect(await rig.app.diagnostics().links[serialA] != .connected)

        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(30)))
        await rig.run(.seconds(30))
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))
        #expect(try await rig.app.history.sessions(serial: serialA).count == 1)
        // Two connections were made (the second after backoff).
        #expect(rig.spy.attempts.count == 2)
        await rig.app.stop()
    }

    @Test func duplicatedNotificationsDoNotDuplicateSamples() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 200)
        rig.transport.duplicateNextNotifications(100, on: .uartTX)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(30))
        #expect(try await rig.storedSeqs(serialA) == contiguous(0...probe.logRange.max))
        await rig.app.stop()
    }
}
