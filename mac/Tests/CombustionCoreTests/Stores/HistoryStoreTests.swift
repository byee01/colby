import CombustionCodec
import CombustionCore
import Foundation
import Testing

struct HistoryStoreTests {
    typealias F = StoreFixtures
    private let t0 = StoreFixtures.t0

    private func ev(_ s: ProbeStatusPayload, at: Date, serial: ProbeSerial = F.serial) -> ProbeStatusEvent {
        ProbeStatusEvent(serial: serial, status: s, receivedAt: at)
    }

    private func makeStore(fetcher: (any LogFetcher)? = nil) throws -> HistoryStore {
        try HistoryStore(path: ":memory:", clock: TestClock(), logFetcher: fetcher)
    }

    // MARK: Time derivation

    @Test func timeDerivationFormula() {
        let t = TimeDerivation.time(seq: 7, anchorSeq: 10, anchorTime: t0, samplePeriod: 5)
        #expect(t == t0 - 15)
        #expect(TimeDerivation.time(seq: 12, anchorSeq: 10, anchorTime: t0, samplePeriod: 5) == t0 + 10)
        #expect(TimeDerivation.seq(at: t0 - 15, anchorSeq: 10, anchorTime: t0, samplePeriod: 5) == 7)
    }

    @Test func timesAreDerivedFromLatestAnchorOnRead() async throws {
        let fetcher = StoreFakeFetcher(seqs: 0...40)
        let store = try makeStore(fetcher: fetcher)
        let key = try await store.ingest(status: ev(F.status(logMax: 10), at: t0))
        var series = try #require(try await store.currentSeries(key))
        #expect(series.samples.map(\.seq) == Array(0...10))
        #expect(series.samples.last?.time == t0)
        #expect(series.samples.first?.time == t0 - 50)

        // Re-anchor 100 s later: the same seqs move with the anchor; nothing was rewritten.
        try await store.ingest(status: ev(F.status(logMax: 30), at: t0 + 100))
        series = try #require(try await store.currentSeries(key))
        #expect(series.anchorSeq == 30 && series.anchorTime == t0 + 100)
        #expect(series.samples.first { $0.seq == 10 }?.time == t0)          // 100 - 20 * 5
        #expect(series.samples.first { $0.seq == 30 }?.time == t0 + 100)

        // A new sample period re-times everything on the next read.
        try await store.ingest(status: ev(F.status(logMax: 30, periodMs: 6000), at: t0 + 100))
        series = try #require(try await store.currentSeries(key))
        #expect(series.samplePeriod == 6)
        #expect(series.samples.first { $0.seq == 10 }?.time == t0 - 20)     // 100 - 20 * 6
    }

    @Test func anchorNeverMovesBackwardsInTime() async throws {
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 30), at: t0 + 100))
        try await store.ingest(status: ev(F.status(logMax: 25), at: t0 + 50))
        let s = try #require(try await store.currentSeries(key))
        #expect(s.anchorSeq == 30 && s.anchorTime == t0 + 100)
    }

    @Test func legacyStatusWithoutSessionInfoUsesDefaultPeriod() async throws {
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 4, sessionId: nil), at: t0))
        #expect(key.sessionId == 0)
        #expect(try await store.currentSeries(key)?.samplePeriod == 5)
    }

    // MARK: Insert idempotence

    @Test func insertsAreIdempotent() async throws {
        let fetcher = StoreFakeFetcher(seqs: 0...20)
        fetcher.add(StoreFixtures.record(5, core: 99))   // same seq, different data: first write wins
        let store = try makeStore(fetcher: fetcher)
        let key = try await store.ingest(status: ev(F.status(logMax: 20), at: t0))
        #expect(try await store.sampleCount(key) == 21)
        let first = try await store.currentSeries(key)
        // Everything again: same status, backfill over the full range, backfill with explicit range.
        try await store.ingest(status: ev(F.status(logMax: 20), at: t0))
        let r = await store.backfill(key, using: fetcher, range: LogRange(min: 0, max: 20))
        #expect(r.requested == 0 && r.received == 0)   // nothing missing, nothing requested
        #expect(try await store.sampleCount(key) == 21)
        #expect(try await store.currentSeries(key)?.samples == first?.samples)
    }

    @Test func duplicateRecordsInOneStreamAreStoredOnce() async throws {
        final class Dup: LogFetcher {
            func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error> {
                AsyncThrowingStream { c in
                    for s in start...end { c.yield(StoreFixtures.record(s)); c.yield(StoreFixtures.record(s)) }
                    c.finish()
                }
            }
        }
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 9), at: t0))
        let r = await store.backfill(key, using: Dup())
        #expect(try await store.sampleCount(key) == 10)
        #expect(r.received == 9 && r.remaining == 0)          // seq 9 came from the status itself
    }

    // MARK: Sessions

    @Test func newSessionIdSplitsCooksAndClosesTheOldOne() async throws {
        let fetcher = StoreFakeFetcher(seqs: 0...50)
        let store = try makeStore(fetcher: fetcher)
        let k1 = try await store.ingest(status: ev(F.status(logMax: 20, sessionId: 1), at: t0))
        try await store.ingest(status: ev(F.status(logMax: 30, sessionId: 1), at: t0 + 50))
        let k2 = try await store.ingest(status: ev(F.status(logMax: 3, sessionId: 2), at: t0 + 4000))
        #expect(k1 != k2 && k1.sessionId == 1 && k2.sessionId == 2)

        let list = try await store.sessions(serial: F.serial)
        #expect(list.map(\.key) == [k2, k1])              // newest first
        let old = list[1], new = list[0]
        #expect(old.end == t0 + 50)                       // last status of the old cook
        #expect(new.end == nil)
        #expect(old.thumbnail.count == 60)
        #expect(old.sampleCount == 31)
        #expect(new.sampleCount == 4)                      // 0...3 from the fetcher (live fetch for the new session)
        #expect(try await store.currentSession(of: F.serial) == k2)
    }

    @Test func zeroIdCooksStayDistinctByStartTime() async throws {
        let store = try makeStore()
        let a = try await store.ingest(status: ev(F.status(logMax: 100, sessionId: nil), at: t0))
        let b = try await store.ingest(status: ev(F.status(logMax: 5, sessionId: nil), at: t0 + 600))   // max decreased
        #expect(a.sessionId == 0 && b.sessionId == 0 && a != b)
        #expect(try await store.sessions().count == 2)
    }

    @Test func unknownIdLaterKnownRewritesSessionId() async throws {
        let store = try makeStore()
        let a = try await store.ingest(status: ev(F.status(logMax: 10, sessionId: nil), at: t0))
        let b = try await store.ingest(status: ev(F.status(logMax: 11, sessionId: 77), at: t0 + 5))
        #expect(a.sessionId == 0 && b.sessionId == 77 && a.startedAtMs == b.startedAtMs)
        #expect(try await store.sessions().count == 1)
    }

    @Test func kindBecomesPredictiveWhenSetpointEverSet() async throws {
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 1), at: t0))
        #expect(try await store.sessions()[0].kind == .manual)
        let pred = F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 63, seconds: 600)
        try await store.ingest(status: ev(F.status(logMax: 2, prediction: pred), at: t0 + 5))
        try await store.ingest(status: ev(F.status(logMax: 3), at: t0 + 10))   // prediction cancelled again
        #expect(try await store.sessions()[0].kind == .predictive)
        #expect(try await store.sessions()[0].key == key)
    }

    @Test func kindFromBackfilledRecords() async throws {
        let fetcher = StoreFakeFetcher()
        for s in UInt32(0)...5 { fetcher.add(StoreFixtures.record(s, mode: s >= 3 ? .timeToRemoval : .none, setpoint: s >= 3 ? 70 : 0)) }
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 5), at: t0))
        await store.backfill(key, using: fetcher)
        let sum = try await store.sessions()[0]
        #expect(sum.kind == .predictive && sum.setpoint == 70)
    }

    @Test func readySinceSetOnceWhenPredictionDone() async throws {
        let store = try makeStore()
        let predicting = F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 60, seconds: 30)
        let done = F.prediction(state: .removalPredictionDone, mode: .timeToRemoval, setpoint: 60)
        try await store.ingest(status: ev(F.status(logMax: 1, prediction: predicting), at: t0))
        #expect(try await store.sessions()[0].readySince == nil)
        try await store.ingest(status: ev(F.status(logMax: 2, prediction: done), at: t0 + 5))
        try await store.ingest(status: ev(F.status(logMax: 3, prediction: done), at: t0 + 10))
        #expect(try await store.sessions()[0].readySince == t0 + 5)
        try await store.ingest(status: ev(F.status(logMax: 4, prediction: predicting), at: t0 + 15))   // new prediction
        #expect(try await store.sessions()[0].readySince == nil)
    }

    @Test func summaryHasPeakCoreSetpointCountAndLiveThumbnail() async throws {
        let fetcher = StoreFakeFetcher()
        for s in UInt32(0)...9 {
            fetcher.add(StoreFixtures.record(s, core: [20, 25, 30, 41, 37, 33, 35, 36, 38, 39][Int(s)],
                                              mode: .timeToRemoval, setpoint: 60))
        }
        let store = try makeStore(fetcher: fetcher)
        try await store.ingest(status: ev(F.status(logMax: 9), at: t0))
        let s = try await store.sessions()[0]
        #expect(s.peakCore == 41 && s.sampleCount == 10 && s.setpoint == 60)
        #expect(s.end == nil && s.thumbnail.count == 60)       // computed on the fly for the open session
        #expect(s.samplePeriod == 5 && s.nickname == nil)
    }

    @Test func peakCoreFollowsEachSamplesCoreSensor() async throws {
        // Core sensor is T3 for this record: peak must read T3, not T1.
        let vs = try VirtualSensors(core: .t3, surface: .t4, ambient: .t5)
        let temps = try ProbeTemperatures(celsius: [99, 0, 55, 10, 10, 0, 0, 0])
        let rec = LogRecord(sequence: 0, temperatures: temps, prediction: PredictionLog(
            virtualSensors: vs, state: .notInserted, mode: .none, type: .none, setpoint: 0, rawSecondsRemaining: 0, estimatedCore: 0))
        let f = StoreFakeFetcher()
        f.add(rec)
        let store = try makeStore(fetcher: f)
        let key = try await store.ingest(status: ev(F.status(logMax: 1), at: t0))   // the status is seq 1 (core 25)
        #expect(try await store.sessions()[0].peakCore == 55)
        let sample = try #require(try await store.currentSeries(key)?.samples.first)
        #expect(sample.core == 55 && sample.surface == 10 && sample.virtualSensors == vs)
    }

    @Test func renameAndDelete() async throws {
        let store = try makeStore(fetcher: StoreFakeFetcher(seqs: 0...5))
        let key = try await store.ingest(status: ev(F.status(logMax: 5), at: t0))
        try await store.rename(key, nickname: "Brisket")
        #expect(try await store.sessions()[0].nickname == "Brisket")
        try await store.rename(key, nickname: nil)
        #expect(try await store.sessions()[0].nickname == nil)
        try await store.delete(key)
        #expect(try await store.sessions().isEmpty)
        #expect(try await store.sampleCount(key) == 0)
        #expect(try await store.currentSeries(key) == nil)
        #expect(try await store.currentSession(of: F.serial) == nil)
        // The probe is still being heard: the next status starts a fresh row.
        let again = try await store.ingest(status: ev(F.status(logMax: 6), at: t0 + 5))
        #expect(try await store.sessions().map(\.key) == [again])
    }

    @Test func cookNameNamesTheOpenCookAndANewCookStartsUnnamed() async throws {
        let store = try makeStore()
        var names = await store.cookNames.makeAsyncIterator()
        #expect(await names.next() == [:])

        let k1 = try await store.ingest(status: ev(F.status(logMax: 5, sessionId: 1), at: t0))
        #expect(await names.next() == [:], "the cook opened unnamed")
        try await store.setCookName("  Brisket ", for: F.serial)
        #expect(await names.next() == [F.serial: "Brisket"])
        #expect(try await store.cookName(of: F.serial) == "Brisket")
        #expect(try await store.sessions().first?.nickname == "Brisket")

        try await store.ingest(status: ev(F.status(logMax: 1, sessionId: 2), at: t0 + 4000))
        #expect(await names.next() == [:], "a charger cycle starts a new, unnamed cook")
        #expect(try await store.sessions().map(\.nickname) == [nil, "Brisket"])

        try await store.rename(k1, nickname: "Old brisket")
        #expect(await names.next() == [:], "renaming an ended cook changes no current name")
        try await store.setCookName("", for: F.serial)
        #expect(await names.next() == [:])
    }

    @Test func aNameGivenBeforeTheFirstStatusGoesToTheNextCook() async throws {
        let store = try makeStore()
        try await store.setCookName("Ribs", for: F.serial)
        #expect(try await store.cookName(of: F.serial) == "Ribs")
        let key = try await store.ingest(status: ev(F.status(logMax: 3, sessionId: 9), at: t0))
        #expect(try await store.sessions().first { $0.key == key }?.nickname == "Ribs")

        try await store.endCurrentSession(of: F.serial)
        #expect(try await store.cookName(of: F.serial) == nil, "the cook ended")
    }

    @Test func cookNamesSurviveARestart() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("colby-\(UUID().uuidString).sqlite").path
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        do {
            let store = try HistoryStore(path: path, clock: TestClock())
            try await store.ingest(status: ev(F.status(logMax: 10, sessionId: 4), at: t0))
            try await store.setCookName("Pork shoulder", for: F.serial)
        }
        let store = try HistoryStore(path: path, clock: TestClock())
        var names = await store.cookNames.makeAsyncIterator()
        #expect(await names.next() == [F.serial: "Pork shoulder"], "known before the probe is heard again")
        try await store.setCookName("Pulled pork", for: F.serial)
        let k = try await store.ingest(status: ev(F.status(logMax: 12, sessionId: 4), at: t0 + 60))
        #expect(try await store.sessions().first { $0.key == k }?.nickname == "Pulled pork")
    }

    @Test func endCurrentSessionClosesAndComputesThumbnail() async throws {
        let store = try makeStore(fetcher: StoreFakeFetcher(seqs: 0...9))
        let key = try await store.ingest(status: ev(F.status(logMax: 9), at: t0))
        try await store.endCurrentSession(of: F.serial)
        let s = try await store.sessions()[0]
        #expect(s.end == t0 && s.thumbnail.count == 60 && s.key == key)
        #expect(try await store.currentSession(of: F.serial) == nil)
        let next = try await store.ingest(status: ev(F.status(logMax: 10), at: t0 + 5))
        #expect(next != key)
    }

    @Test func sessionsFilterBySerial() async throws {
        let store = try makeStore()
        let other = ProbeSerial(2)
        try await store.ingest(status: ev(F.status(logMax: 1), at: t0))
        try await store.ingest(status: ev(F.status(logMax: 1), at: t0, serial: other))
        #expect(try await store.sessions().count == 2)
        #expect(try await store.sessions(serial: other).map(\.key.serial) == [other])
    }

    @Test func openSessionResumesAfterRestartAndSplitsOnNewId() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("colby-\(UUID().uuidString).sqlite").path
        defer { for ext in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + ext) } }
        let k1: SessionKey
        do {
            let store = try HistoryStore(path: path, clock: TestClock())
            k1 = try await store.ingest(status: ev(F.status(logMax: 10, sessionId: 4), at: t0))
        }
        do {
            let store = try HistoryStore(path: path, clock: TestClock())
            let k = try await store.ingest(status: ev(F.status(logMax: 12, sessionId: 4), at: t0 + 3600))
            #expect(k == k1)                                   // same cook continues
            let k2 = try await store.ingest(status: ev(F.status(logMax: 1, sessionId: 5), at: t0 + 7200))
            #expect(k2 != k1)
            let list = try await store.sessions()
            #expect(list.count == 2 && list[1].end == t0 + 3600)
        }
    }

    // MARK: Series stream

    @Test func seriesStreamReplaysThenUpdatesAndFinishesOnDelete() async throws {
        let fetcher = StoreFakeFetcher(seqs: 0...40)
        let store = try makeStore(fetcher: fetcher)
        let clock = TestClock()
        let key = try await store.ingest(status: ev(F.status(logMax: 4), at: t0))
        let stream = await store.series(key)
        let log = StoreLog<TemperatureSeries>()
        let done = StoreLog<Bool>()
        let task = Task {
            for await s in stream { log.add(s) }
            done.add(true)
        }
        await settle(clock) { log.count >= 1 }
        #expect(log.items[0].samples.count == 5)
        try await store.ingest(status: ev(F.status(logMax: 9), at: t0 + 25))
        await settle(clock) { log.last?.samples.count == 10 }
        #expect(log.last?.samples.count == 10)
        // Anchor-only change (no new records) re-publishes with moved times.
        try await store.ingest(status: ev(F.status(logMax: 9), at: t0 + 30))
        await settle(clock) { log.last?.anchorTime == t0 + 30 }
        #expect(log.last?.anchorTime == t0 + 30)
        try await store.delete(key)
        await settle(clock) { done.count == 1 }
        #expect(done.count == 1)
        task.cancel()
        // Unknown session: empty, finished.
        var n = 0
        for await _ in await store.series(key) { n += 1 }
        #expect(n == 0)
    }

    // MARK: Downsampling

    private func series(count: Int, spikeAt: Int? = nil, seqStep: UInt32 = 1) -> TemperatureSeries {
        let key = SessionKey(serial: F.serial, sessionId: 1, startedAt: t0)
        let samples = (0..<count).map { i -> TemperatureSample in
            let seq = UInt32(i) * seqStep
            let c = i == spikeAt ? 250.0 : 50 + Double(i % 7)
            let t = try! ProbeTemperatures(celsius: [c, 0, 0, c - 10, c - 20, 0, 0, 0])
            return TemperatureSample(
                seq: seq, time: t0 + Double(seq) * 5, temperatures: t.celsius, virtualSensors: F.virtual(),
                prediction: StoreFixtures.record(seq).prediction)
        }
        return TemperatureSeries(key: key, samplePeriod: 5, anchorSeq: samples.last?.seq ?? 0, anchorTime: t0, samples: samples)
    }

    @Test func downsamplingKeepsSpikesAndRespectsMax() {
        let s = series(count: 10_000, spikeAt: 5123)
        let d = s.downsampled(maxPoints: 200)
        #expect(d.count <= 200 && d.count >= 190)
        #expect(d.map(\.core.max).max() == 250)                       // spike survives
        #expect(d.first { $0.core.max == 250 }?.core.min ?? 0 < 250)    // min/max band, not a point
        #expect(d.reduce(0) { $0 + $1.sampleCount } == 10_000)
        #expect(d.first?.firstSeq == 0 && d.last?.lastSeq == 9_999)
        #expect(zip(d, d.dropFirst()).allSatisfy { $0.lastSeq < $1.firstSeq && $0.endTime <= $1.startTime })
        #expect(d.allSatisfy { $0.surface.max == $0.core.max - 10 || $0.surface.max < $0.core.max })
    }

    @Test func downsamplingBelowMaxIsOneBucketPerSample() {
        let s = series(count: 30)
        let d = s.downsampled(maxPoints: 100)
        #expect(d.count == 30 && d.allSatisfy { $0.sampleCount == 1 && $0.core.min == $0.core.max })
        #expect(s.downsampled(maxPoints: 0).isEmpty)
        #expect(TemperatureSeries(key: s.key, samplePeriod: 5, anchorSeq: 0, anchorTime: t0, samples: []).downsampled(maxPoints: 10).isEmpty)
    }

    @Test func downsamplingWithHolesSkipsEmptyBuckets() {
        let s = series(count: 50, seqStep: 100)     // seqs 0,100,...,4900; 100-wide holes
        let d = s.downsampled(maxPoints: 1000)
        #expect(d.count == 50)
        let d2 = s.downsampled(maxPoints: 10)
        #expect(d2.count == 10 && d2.reduce(0) { $0 + $1.sampleCount } == 50)
    }

    @Test func downsamplingMaxPointsOneCoversEverything() {
        let s = series(count: 100, spikeAt: 40)
        let d = s.downsampled(maxPoints: 1)
        #expect(d.count == 1 && d[0].core.max == 250 && d[0].sampleCount == 100)
    }

    // MARK: valueAt

    private func valueStore() async throws -> (HistoryStore, SessionKey) {
        let f = StoreFakeFetcher()
        for s in UInt32(0)...10 {
            f.add(StoreFixtures.record(s, core: 20 + Double(s), surface: 100 + Double(s), ambient: 200,
                                       mode: s >= 8 ? .timeToRemoval : .none, setpoint: s >= 8 ? 60 : 0,
                                       state: s >= 8 ? .predicting : .notInserted))
        }
        let store = try makeStore(fetcher: f)
        // seq 10 at t0, 5 s apart. The status is stored as seq 10, so it carries record 10's values.
        let key = try await store.ingest(status: ev(F.status(core: 30, surface: 110, ambient: 200, logMax: 10), at: t0))
        return (store, key)
    }

    @Test func valueAtExactAndInterpolated() async throws {
        let (store, key) = try await valueStore()
        let exact = try #require(try await store.valueAt(key, time: t0 - 25))           // seq 5
        #expect(exact.seq == 5 && exact.core == 25 && exact.surface == 105 && exact.ambient == 200)
        #expect(exact.predictionState == .notInserted)
        let mid = try #require(try await store.valueAt(key, time: t0 - 22.5))           // seq 5.5
        #expect(abs(mid.core - 25.5) < 1e-9 && abs(mid.surface - 105.5) < 1e-9)
        let quarter = try #require(try await store.valueAt(key, time: t0 - 28.75))      // seq 4.25
        #expect(abs(quarter.core - 24.25) < 1e-9 && quarter.seq == 4)
    }

    @Test func valueAtCarriesPredictionStateAndEdges() async throws {
        let (store, key) = try await valueStore()
        let late = try #require(try await store.valueAt(key, time: t0 - 5))            // seq 9
        #expect(late.predictionState == .predicting && late.prediction.setpoint == 60)
        #expect(try await store.valueAt(key, time: t0)?.core == 30)
        #expect(try await store.valueAt(key, time: t0 - 50)?.core == 20)               // first sample
        #expect(try await store.valueAt(key, time: t0 + 1)?.seq == 10)                 // within half a period past the end
        #expect(try await store.valueAt(key, time: t0 + 10) == nil)
        #expect(try await store.valueAt(key, time: t0 - 60) == nil)
    }

    @Test func valueAtAcrossAHoleUsesNearest() async throws {
        let f = StoreFakeFetcher()
        f.add(StoreFixtures.record(0, core: 20))
        f.add(StoreFixtures.record(100, core: 120))
        let store = try makeStore(fetcher: f)
        let key = try await store.ingest(status: ev(F.status(logMax: 100), at: t0))
        // 70 s in: seq 14 of a 100-seq hole; no interpolation across it, nearest is seq 0.
        let v = try #require(try await store.valueAt(key, time: t0 - 430))
        #expect(v.seq == 0 && v.core == 20)
        #expect(try await store.valueAt(key, time: t0 - 20)?.seq == 100)
    }

    @Test func valueAtUsesLatestAnchor() async throws {
        let (store, key) = try await valueStore()
        try await store.ingest(status: ev(F.status(logMax: 10), at: t0 + 100))         // anchor moved: seq 10 now at t0+100
        #expect(try await store.valueAt(key, time: t0 + 100)?.seq == 10)
        #expect(try await store.valueAt(key, time: t0) == nil)
    }

    // MARK: Thumbnail

    @Test func thumbnailHasSixtyPointsAndEndpoints() {
        let s = series(count: 500)
        let th = Thumbnail.make(from: s.samples)
        #expect(th.count == 60)
        #expect(th.first?.core == s.samples.first?.core && th.last?.core == s.samples.last?.core)
        #expect(th[0].surface == s.samples[0].surface && th[0].ambient == s.samples[0].ambient)
    }

    @Test func thumbnailInterpolatesShortAndSingleSeries() {
        let two = Array(series(count: 2).samples)
        let th = Thumbnail.make(from: two)
        #expect(th.count == 60)
        #expect(th.map(\.core).min() == min(two[0].core, two[1].core) && th.map(\.core).max() == max(two[0].core, two[1].core))
        let one = Thumbnail.make(from: [two[0]])
        #expect(one.count == 60 && one.allSatisfy { $0.core == two[0].core })
        #expect(Thumbnail.make(from: []).isEmpty)
    }

    @Test func thumbnailBlobRoundTrips() {
        let th = Thumbnail.make(from: series(count: 100).samples)
        let back = Thumbnail.decode(Thumbnail.encode(th))
        #expect(back.count == 60)
        #expect(zip(th, back).allSatisfy { abs($0.core - $1.core) < 1e-4 })
        #expect(Thumbnail.decode([1, 2, 3]).isEmpty)
    }

    @Test func thumbnailStoredOnSessionEndMatchesComputed() async throws {
        let f = StoreFakeFetcher(seqs: 0...99)
        let store = try makeStore(fetcher: f)
        let k = try await store.ingest(status: ev(F.status(logMax: 99, sessionId: 1), at: t0))
        let expected = Thumbnail.make(from: try #require(try await store.currentSeries(k)).samples)
        try await store.ingest(status: ev(F.status(logMax: 1, sessionId: 2), at: t0 + 10))
        let old = try await store.sessions().first { $0.key == k }!
        #expect(old.thumbnail.count == 60)
        #expect(zip(old.thumbnail, expected).allSatisfy { abs($0.core - $1.core) < 1e-3 && abs($0.ambient - $1.ambient) < 1e-3 })
    }

    // MARK: Live fetch

    @Test func liveFetchRequestsOnlyNewSeqsWhenMaxAdvances() async throws {
        let f = StoreFakeFetcher(seqs: 0...100)
        let store = try makeStore(fetcher: f)
        // Each status is stored as the record at its max, so only seqs below it are requested.
        let key = try await store.ingest(status: ev(F.status(logMax: 5), at: t0))
        #expect(f.requests == [.init(start: 0, end: 4)])
        try await store.ingest(status: ev(F.status(logMax: 5), at: t0 + 1))      // not advanced
        #expect(f.requests.count == 1)
        try await store.ingest(status: ev(F.status(logMax: 6), at: t0 + 5))      // next seq: nothing to fetch
        #expect(f.requests.count == 1)
        try await store.ingest(status: ev(F.status(logMax: 8), at: t0 + 10))     // seq 7 was skipped
        #expect(f.requests == [.init(start: 0, end: 4), .init(start: 7, end: 7)])
        #expect(try await store.sampleCount(key) == 9)
    }

    @Test func liveFetchIsCappedToOneChunkAndLeavesOlderHolesForBackfill() async throws {
        let f = StoreFakeFetcher(seqs: 0...1000)
        let store = try makeStore(fetcher: f)
        let key = try await store.ingest(status: ev(F.status(logMax: 1000), at: t0))
        #expect(f.requests == [.init(start: 872, end: 999)])
        let r = await store.backfill(key, using: f)
        #expect(r.remaining == 0 && r.received == 872)
        #expect(try await store.sampleCount(key) == 1001)
    }

    @Test func liveFetchFailureKeepsPartialAndSessionState() async throws {
        let f = StoreFakeFetcher(seqs: 0...10)
        f.fail(onRequest: 1)
        let store = try makeStore(fetcher: f)
        let key = try await store.ingest(status: ev(F.status(logMax: 10), at: t0))
        #expect(try await store.sampleCount(key) == 1)       // only the status's own record
        #expect(try await store.sessions().count == 1)       // status handling was not lost
    }

    @Test func explicitFetcherOverridesDefault() async throws {
        let dflt = StoreFakeFetcher(seqs: 0...5)
        let other = StoreFakeFetcher(seqs: 0...5)
        let store = try makeStore(fetcher: dflt)
        try await store.ingest(status: ev(F.status(logMax: 5), at: t0), using: other)
        #expect(dflt.requests.isEmpty && other.requests.count == 1)
    }

    @Test func consumeIngestsStatusEventsFromProbeStore() async throws {
        let clock = TestClock()
        let probes = ProbeStore(clock: clock)
        let store = try HistoryStore(path: ":memory:", clock: clock)
        let events = probes.statusEvents
        let task = Task { await store.consume(events) }
        await clock.settle()
        await probes.ingest(F.observe(.status(F.status(logMax: 3)), kind: .directConnection, at: clock.now()))
        for _ in 0..<500 {
            if (try? await store.sessions().count) == 1 { break }
            await clock.settle()
        }
        #expect(try await store.sessions().count == 1)
        task.cancel()
    }

    // MARK: Backfill

    @Test func backfillRequestsChunksOfOneTwentyEightNewestFirst() async throws {
        let f = StoreFakeFetcher(seqs: 0...299)
        let store = try makeStore()   // no live fetching
        let key = try await store.ingest(status: ev(F.status(logMax: 299), at: t0))
        let r = await store.backfill(key, using: f)
        // seq 299 is the status's own record.
        #expect(f.requests == [.init(start: 171, end: 298), .init(start: 43, end: 170), .init(start: 0, end: 42)])
        #expect(r == BackfillResult(requested: 299, received: 299, remaining: 0, failed: false))
        #expect(try await store.sampleCount(key) == 300)
    }

    @Test func backfillFillsFromTheRight() async throws {
        let f = StoreFakeFetcher(seqs: 0...299)
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 299), at: t0))
        let stream = await store.series(key)
        let log = StoreLog<Int>()
        let clock = TestClock()
        let task = Task { for await s in stream { log.add(s.samples.first.map { Int($0.seq) } ?? -1) } }
        await settle(clock) { log.count >= 1 }
        await store.backfill(key, using: f)
        await settle(clock) { log.last == 0 }
        task.cancel()
        #expect(log.items.filter { $0 >= 0 } == [299, 171, 43, 0])   // earliest stored seq moves left chunk by chunk
    }

    @Test func backfillToleratesPartialResultsAndRetriesOnlyGaps() async throws {
        let f = StoreFakeFetcher(seqs: 0...299)
        f.withhold(100...110)
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 299), at: t0))
        let r1 = await store.backfill(key, using: f)
        #expect(r1.received == 288 && r1.remaining == 11 && !r1.failed)   // plus seq 299 from the status
        #expect(try await store.sampleCount(key) == 289)
        f.release()
        let before = f.requests.count
        let r2 = await store.backfill(key, using: f)
        #expect(Array(f.requests[before...]) == [.init(start: 100, end: 110)])
        #expect(r2 == BackfillResult(requested: 11, received: 11, remaining: 0, failed: false))
        #expect(try await store.sampleCount(key) == 300)
        let r3 = await store.backfill(key, using: f)
        #expect(r3.requested == 0)
    }

    @Test func backfillStopsOnFetcherErrorKeepingWhatArrived() async throws {
        let f = StoreFakeFetcher(seqs: 0...299)
        f.fail(onRequest: 2)
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMax: 299), at: t0))
        let r1 = await store.backfill(key, using: f)
        #expect(r1.failed && r1.received == 128 && r1.remaining == 171)
        #expect(f.requests.count == 2)                          // chunk 3 was not attempted
        f.fail(onRequest: nil)
        let r2 = await store.backfill(key, using: f)
        #expect(!r2.failed && r2.remaining == 0)
        #expect(try await store.sampleCount(key) == 300)
    }

    @Test func backfillIgnoresRecordsOutsideTheRequestedRange() async throws {
        final class Wild: LogFetcher {
            func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error> {
                AsyncThrowingStream { c in
                    for s in 0...(end + 5) { c.yield(StoreFixtures.record(s)) }
                    c.finish()
                }
            }
        }
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMin: 10, logMax: 20), at: t0))
        await store.backfill(key, using: Wild())
        #expect(try await store.currentSeries(key)?.samples.map(\.seq) == Array(10...20))
    }

    @Test func backfillWithoutKnownRangeDoesNothing() async throws {
        let store = try makeStore()
        let ghost = SessionKey(serial: F.serial, sessionId: 9, startedAt: t0)
        let r = await store.backfill(ghost, using: StoreFakeFetcher(seqs: 0...5))
        #expect(r.requested == 0)
    }

    @Test func backfillUsesLogRangeMinAfterWrap() async throws {
        let f = StoreFakeFetcher(seqs: 0...500)
        let store = try makeStore()
        let key = try await store.ingest(status: ev(F.status(logMin: 400, logMax: 500), at: t0))
        await store.backfill(key, using: f)
        #expect(f.requests == [.init(start: 400, end: 499)])
    }

    // MARK: Eight concurrent sessions

    @Test func eightConcurrentSessions() async throws {
        let serials = (1...8).map { ProbeSerial(UInt32($0)) }
        let fetchers = Dictionary(uniqueKeysWithValues: serials.map { ($0, StoreFakeFetcher(seqs: 0...299)) })
        // One shared fetcher that routes by probe.
        final class Router: LogFetcher {
            let by: [ProbeSerial: StoreFakeFetcher]
            init(_ by: [ProbeSerial: StoreFakeFetcher]) { self.by = by }
            func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error> {
                by[probe]!.readLogs(probe: probe, start: start, end: end)
            }
        }
        let router = Router(fetchers)
        let store = try makeStore(fetcher: router)
        var keys: [ProbeSerial: SessionKey] = [:]
        for (i, s) in serials.enumerated() {
            keys[s] = try await store.ingest(status: ev(F.status(logMax: 299, sessionId: UInt32(100 + i)), at: t0 + Double(i), serial: s))
        }
        let finalKeys = keys
        await withTaskGroup(of: Void.self) { g in
            for s in serials { g.addTask { await store.backfill(finalKeys[s]!, using: router) } }
        }
        let list = try await store.sessions()
        #expect(list.count == 8)
        #expect(list.allSatisfy { $0.sampleCount == 300 && $0.thumbnail.count == 60 })
        #expect(Set(list.map(\.key.serial)) == Set(serials))
        for s in serials {
            let series = try #require(try await store.currentSeries(finalKeys[s]!))
            #expect(series.samples.count == 300)
            #expect(series.downsampled(maxPoints: 100).count <= 100)
        }
    }
}
