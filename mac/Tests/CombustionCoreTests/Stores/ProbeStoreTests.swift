import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

struct ProbeStoreTests {
    typealias F = StoreFixtures

    private func makeStore(_ clock: TestClock) -> ProbeStore { ProbeStore(clock: clock) }

    // MARK: Primary source order

    @Test func primaryOrderDirectNodeAdvertisementNodeAdvertisement() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let t = clock.now()
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .nodeAdvertisement, via: "N1", hop: 1, at: t))
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: t))
        var snap = await store.snapshot(of: F.serial)!
        #expect(snap.link.primary?.kind == .advertisement)
        await store.ingest(F.observe(.status(F.status()), kind: .nodeConnection, via: "N2", hop: 3, at: t))
        await store.ingest(F.observe(.status(F.status()), kind: .nodeConnection, via: "N1", hop: 2, at: t))
        snap = await store.snapshot(of: F.serial)!
        #expect(snap.link.primary?.kind == .nodeConnection)
        #expect(snap.link.primary?.via == "N1")   // lowest hop count
        await store.ingest(F.observe(.status(F.status()), kind: .directConnection, at: t))
        snap = await store.snapshot(of: F.serial)!
        #expect(snap.link.primary?.kind == .directConnection)
        #expect(snap.link.sources.map(\.kind) == [.directConnection, .nodeConnection, .nodeConnection, .advertisement, .nodeAdvertisement])
        #expect(snap.link.sources[1].via == "N1" && snap.link.sources[2].via == "N2")
    }

    @Test func sourceUpdatedInPlaceNotDuplicated() async {
        let clock = TestClock()
        let store = makeStore(clock)
        for _ in 0..<3 {
            await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: clock.now()))
        }
        #expect(await store.snapshot(of: F.serial)!.link.sources.count == 1)
    }

    // MARK: Field merge

    @Test func statusOnlyFieldsSurviveAdvertisements() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let pred = F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 60, seconds: 900, est: 40)
        await store.ingest(F.observe(.status(F.status(logMax: 7, prediction: pred)), kind: .directConnection, at: clock.now()))
        await clock.advance(by: .seconds(1))
        await store.ingest(F.observe(.advertisement(F.advertisement(core: 33)), kind: .advertisement, at: clock.now()))
        let snap = await store.snapshot(of: F.serial)!
        #expect(snap.prediction == pred)
        #expect(snap.alarms != nil)
        #expect(snap.session?.logRange == LogRange(min: 0, max: 7))
        #expect(snap.session?.info?.sessionId == 1)
        #expect(snap.virtual.core == 33)   // temperatures from the fresher advertisement
    }

    @Test func advertisementOnlyHasNoStatusFields() async {
        let clock = TestClock()
        let store = makeStore(clock)
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: clock.now()))
        let snap = await store.snapshot(of: F.serial)!
        #expect(snap.prediction == nil && snap.alarms == nil && snap.foodSafe == nil && snap.session == nil)
    }

    @Test func statusFieldsFromFreshestConnection() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let old = F.prediction(state: .warming, mode: .timeToRemoval, setpoint: 60)
        let new = F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 65)
        let t = clock.now()
        await store.ingest(F.observe(.status(F.status(prediction: old)), kind: .directConnection, at: t))
        await store.ingest(F.observe(.status(F.status(prediction: new)), kind: .nodeConnection, via: "N", hop: 1, at: t.addingTimeInterval(1)))
        #expect(await store.snapshot(of: F.serial)!.prediction == new)
        // A late, older direct status does not override.
        await store.ingest(F.observe(.status(F.status(prediction: old)), kind: .directConnection, at: t.addingTimeInterval(0.5)))
        #expect(await store.snapshot(of: F.serial)!.prediction == new)
    }

    @Test func temperaturesFromFreshestOfAnyKind() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let t = clock.now()
        await store.ingest(F.observe(.status(F.status(core: 50)), kind: .directConnection, at: t))
        await store.ingest(F.observe(.advertisement(F.advertisement(core: 51)), kind: .advertisement, at: t.addingTimeInterval(0.1)))
        #expect(await store.snapshot(of: F.serial)!.virtual.core == 51)
        // Older node advertisement ignored.
        await store.ingest(F.observe(.advertisement(F.advertisement(core: 10)), kind: .nodeAdvertisement, via: "N", hop: 1, at: t.addingTimeInterval(-5)))
        let snap = await store.snapshot(of: F.serial)!
        #expect(snap.virtual.core == 51)
        #expect(snap.receivedAt == t.addingTimeInterval(0.1))
        #expect(snap.link.sources.count == 3)   // but the stale-timestamped observation still counts as a live path
    }

    @Test func snapshotBuiltFromStatusFields() async {
        let clock = TestClock()
        let store = makeStore(clock)
        await store.ingest(F.observe(.status(F.status(core: 60, surface: 70, ambient: 200, batteryLow: true)), kind: .directConnection, at: clock.now()))
        let s = await store.snapshot(of: F.serial)!
        #expect(s.serial == F.serial && s.probeNumber == 1 && s.color == .yellow && s.mode == .normal)
        #expect(s.temperatures.count == 8 && s.temperatures.allSatisfy { $0 != nil })
        #expect(s.virtual.core == 60 && s.virtual.surface == 70 && s.virtual.ambient == 200)
        #expect(s.virtual.coreSensor == .t1 && s.virtual.surfaceSensor == .t4 && s.virtual.ambientSensor == .t5)
        #expect(s.batteryLow && s.instantRead == nil)
    }

    // MARK: Source drop, offline

    @Test func sourceDroppedAfterTenSeconds() async {
        let clock = TestClock()
        let store = makeStore(clock)
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: clock.now()))
        await clock.advance(by: .seconds(9))
        #expect(await store.snapshot(of: F.serial)!.link.sources.count == 1)
        await clock.advance(by: .seconds(1))
        #expect(await store.snapshot(of: F.serial)!.link.sources.isEmpty)
    }

    @Test func refreshedSourceSurvivesAndOnlyStaleOneDrops() async {
        let clock = TestClock()
        let store = makeStore(clock)
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: clock.now()))
        await store.ingest(F.observe(.status(F.status()), kind: .directConnection, at: clock.now()))
        await clock.advance(by: .seconds(6))
        await store.ingest(F.observe(.status(F.status()), kind: .directConnection, at: clock.now()))
        await clock.advance(by: .seconds(6))   // t = 12: advertisement 12 s old, direct 6 s old
        let s = await store.snapshot(of: F.serial)!
        #expect(s.link.sources.map(\.kind) == [.directConnection])
        #expect(s.link.primary?.kind == .directConnection)
    }

    @Test func offlineProbeIsKeptWithLastKnownData() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let pred = F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 60, seconds: 300)
        await store.ingest(F.observe(.status(F.status(core: 44, prediction: pred)), kind: .directConnection, at: clock.now()))
        await clock.advance(by: .seconds(30))
        let latest = await store.probes.first { $0[F.serial]?.link.sources.isEmpty == true }
        let s = try! #require(latest?[F.serial])
        #expect(s.isOffline && s.link.primary == nil)
        #expect(s.virtual.core == 44 && s.prediction == pred)
    }

    @Test func probeOnlineAgainAfterOffline() async {
        let clock = TestClock()
        let store = makeStore(clock)
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: clock.now()))
        await clock.advance(by: .seconds(20))
        await store.ingest(F.observe(.advertisement(F.advertisement(core: 30)), kind: .advertisement, at: clock.now()))
        let s = await store.snapshot(of: F.serial)!
        #expect(s.link.sources.count == 1 && s.virtual.core == 30)
    }

    // MARK: Instant Read

    @Test func instantReadPath() async {
        let clock = TestClock()
        let store = makeStore(clock)
        func feed(_ v: Double, mode: ProbeMode = .instantRead) async {
            await store.ingest(F.observe(.advertisement(F.advertisement(mode: mode, t1: v)), kind: .advertisement, at: clock.now()))
            await clock.advance(by: .milliseconds(83))
        }
        await feed(20.0)
        var s = await store.snapshot(of: F.serial)!
        #expect(s.mode == .instantRead)
        #expect(s.temperatures[0] == 20.0)
        #expect(s.temperatures[1...].allSatisfy { $0 == nil })
        #expect(s.instantRead == 20.0)
        #expect(s.virtual.core == 20.0)          // core sensor is T1
        #expect(s.virtual.surface == nil && s.virtual.ambient == nil)
        await feed(20.3)                          // inside deadband
        #expect(await store.snapshot(of: F.serial)!.instantRead == 20.0)
        await feed(20.7)                          // > 20.55
        #expect(await store.snapshot(of: F.serial)!.instantRead == 21.0)
        await feed(25, mode: .normal)             // a Normal packet fills T1-T8 but Instant Read stays on
        s = await store.snapshot(of: F.serial)!
        #expect(s.mode == .instantRead && s.instantRead == 21.0)
        #expect(s.temperatures.allSatisfy { $0 != nil })
        for _ in 0..<60 { await feed(25, mode: .normal) }   // 5 s without Instant Read
        s = await store.snapshot(of: F.serial)!
        #expect(s.mode == .normal)
        #expect(s.instantRead == nil && s.instantReadFahrenheit == nil)
        await feed(30.0)                          // filter restarted: rounds, no memory of 21
        #expect(await store.snapshot(of: F.serial)!.instantRead == 30.0)
    }

    /// Captured on fw v2.3.3 (spec/replays/idle-interleaved-modes): Instant Read and Normal packets alternate.
    /// Surface and ambient must not blank and the mode must not flip with each packet.
    @Test func interleavedModesKeepAllSensorsAndInstantRead() async {
        let clock = TestClock()
        let store = makeStore(clock)
        for i in 0..<40 {
            let mode: ProbeMode = i % 3 == 2 ? .normal : .instantRead
            await store.ingest(F.observe(.advertisement(F.advertisement(mode: mode, t1: 23.5)), kind: .advertisement,
                                         at: clock.now()))
            await clock.advance(by: .milliseconds(250))
            guard i >= 2 else { continue }
            let s = await store.snapshot(of: F.serial)!
            #expect(s.mode == .instantRead)
            #expect(s.instantRead == 24.0)
            #expect(s.temperatures.allSatisfy { $0 != nil })
            #expect(s.virtual.surface != nil && s.virtual.ambient != nil)
        }
    }

    /// The real capture: every advert of `spec/replays/idle-interleaved-modes` at its recorded time. It has
    /// stretches of 5 s and more with only Normal packets, so Instant Read may lapse there, but the mode must not
    /// follow each packet (it did ~70 times in 2 min before) and the Normal sensors must never blank.
    @Test func capturedInterleavedAdvertsGiveAStableSnapshot() async throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/replays/idle-interleaved-modes")
        let adverts = try ReplayReader(directory: dir).events.filter { $0.type == .adv }
        #expect(adverts.count > 300)
        let clock = TestClock()
        let store = makeStore(clock)
        var elapsed = 0.0
        var checked = 0
        var modeChanges = 0
        var lastMode: ProbeMode?
        for event in adverts {
            await clock.advance(by: .seconds(event.t - elapsed))
            elapsed = event.t
            guard case .probe(let ad) = try decodeAdvertisement(event.bytes) else { continue }
            await store.ingest(F.observe(.advertisement(ad), kind: .advertisement, at: clock.now(), serial: ad.serial))
            // The capture starts with 15 s of Instant Read only.
            guard event.t > 16, let s = await store.snapshot(of: ad.serial) else { continue }
            #expect(s.virtual.core != nil && s.virtual.surface != nil && s.virtual.ambient != nil)
            #expect((s.mode == .instantRead) == (s.instantRead != nil))
            if let lastMode, lastMode != s.mode { modeChanges += 1 }
            lastMode = s.mode
            checked += 1
        }
        #expect(checked > 250)
        #expect(modeChanges <= 10)
    }

    @Test func instantReadFilterMatchesAndroidSdkBehaviour() {
        var f = InstantReadFilter()
        f.addReading(nil)
        #expect(f.celsius == nil && f.fahrenheit == nil)
        f.addReading(20.0)
        #expect(f.celsius == 20.0 && f.fahrenheit == 68.0)
        f.addReading(20.2)
        #expect(f.celsius == 20.0 && f.fahrenheit == 68.0)
        f.addReading(19.68)
        #expect(f.celsius == 20.0 && f.fahrenheit == 68.0)
        // 20.5 is inside the 0.55 band for C, but 68.9 °F leaves the 0.59 °F... (68 + 0.5 + 0.09 = 68.59)
        f.addReading(20.5)
        #expect(f.celsius == 20.0 && f.fahrenheit == 69.0)
        f.addReading(21.0)   // > 20.55
        #expect(f.celsius == 21.0 && f.fahrenheit == 70.0)
        f.addReading(nil)
        #expect(f.celsius == nil)
        f.addReading(-0.5)   // Kotlin roundToInt: halves toward +inf
        #expect(f.celsius == 0.0 || f.celsius == -0.0)
    }

    // MARK: Status events

    @Test func statusEventsOnlyForAcceptedStatuses() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let log = StoreLog<ProbeStatusEvent>()
        let events = store.statusEvents
        let task = Task { for await e in events { log.add(e) } }
        await clock.settle()
        let t = clock.now()
        await store.ingest(F.observe(.advertisement(F.advertisement()), kind: .advertisement, at: t))
        await store.ingest(F.observe(.status(F.status(logMax: 5)), kind: .directConnection, at: t.addingTimeInterval(1)))
        await store.ingest(F.observe(.status(F.status(logMax: 4)), kind: .nodeConnection, via: "N", hop: 1, at: t.addingTimeInterval(0.5)))   // older
        await store.ingest(F.observe(.status(F.status(logMax: 6)), kind: .nodeConnection, via: "N", hop: 1, at: t.addingTimeInterval(2)))
        await settle(clock) { log.count >= 2 }
        task.cancel()
        #expect(log.items.map(\.status.logRange.max) == [5, 6])
        #expect(log.items.allSatisfy { $0.serial == F.serial })
        #expect(log.items.map(\.receivedAt) == [t.addingTimeInterval(1), t.addingTimeInterval(2)])
    }

    // MARK: Streams and coalescing

    @Test func firstUpdateIsEmittedImmediately() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let log = StoreLog<[ProbeSerial: ProbeSnapshot]>()
        let stream = store.probes
        let task = Task { for await m in stream { log.add(m) } }
        await clock.settle()
        #expect(log.items.last?.isEmpty == true)     // replayed initial value
        await store.ingest(F.observe(.advertisement(F.advertisement(core: 31)), kind: .advertisement, at: clock.now()))
        await settle(clock) { log.last?[F.serial] != nil }   // no time advance
        #expect(log.last?[F.serial]?.virtual.core == 31)
        task.cancel()
    }

    @Test func perProbeStreamStartsNilThenFollowsAndReplaysLatest() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let s1 = await store.probe(F.serial)
        let log = StoreLog<ProbeSnapshot?>()
        let task = Task { for await v in s1 { log.add(v) } }
        await clock.settle()
        #expect(log.count == 1 && log.items[0] == nil)
        await store.ingest(F.observe(.advertisement(F.advertisement(core: 22)), kind: .advertisement, at: clock.now()))
        await settle(clock) { log.last??.virtual.core == 22 }
        #expect(log.last??.virtual.core == 22)
        // New subscriber gets the latest value first.
        let late = await store.probe(F.serial)
        let first = await late.first { _ in true }
        #expect(first??.virtual.core == 22)
        task.cancel()
    }

    @Test func coalescesToTenHertzAndDeliversLastValue() async {
        let clock = TestClock()
        let store = makeStore(clock)
        struct Emit: Sendable { var at: Duration; var core: Double? }
        let log = StoreLog<Emit>()
        let stream = await store.probe(F.serial)
        let task = Task { for await v in stream { if let v { log.add(Emit(at: clock.monotonic(), core: v.virtual.core)) } } }
        await clock.settle()
        for i in 0..<50 {
            await store.ingest(F.observe(.advertisement(F.advertisement(core: 20 + Double(i))), kind: .advertisement, at: clock.now()))
            await clock.advance(by: .milliseconds(83))
        }
        await clock.advance(by: .milliseconds(100))
        // Scheduler slack only: a flush timer registered after the last advance needs time to move once more.
        for _ in 0..<50 where log.last?.core != 69 { await clock.advance(by: .milliseconds(10)) }
        task.cancel()

        let emits = log.items
        #expect(emits.first?.core == 20)                     // first observation emitted as-is (immediacy: see firstUpdateIsEmittedImmediately)
        #expect(emits.count <= 43)                            // 4.15 s at 10 Hz
        #expect(emits.count >= 30)                            // and not starved (harness timing may skip a slot)
        // (Per-emit spacing is not asserted: the consumer's clock reading can lag the flush by up to one
        // advance step. The count bound over 4.15 s is the 10 Hz check.)
        #expect(emits.last?.core == 69)                       // last value delivered
        // Never a value from the future / out of order.
        let cores = emits.compactMap(\.core)
        #expect(cores == cores.sorted())
    }

    @Test func mapStreamCoalescesAcrossProbes() async {
        let clock = TestClock()
        let store = makeStore(clock)
        let log = StoreLog<[ProbeSerial: ProbeSnapshot]>()
        let stream = store.probes
        let task = Task { for await m in stream { log.add(m) } }
        await clock.settle()
        let serials = (1...8).map { ProbeSerial(UInt32($0)) }
        for round in 0..<5 {
            for s in serials {
                await store.ingest(F.observe(.advertisement(F.advertisement(serial: s, core: 20 + Double(round))), kind: .advertisement, at: clock.now(), serial: s))
            }
            await clock.advance(by: .milliseconds(10))
        }
        await clock.advance(by: .milliseconds(100))
        for _ in 0..<50 where log.last?.count != 8 || log.last?.values.allSatisfy({ $0.virtual.core == 24 }) != true { await clock.advance(by: .milliseconds(10)) }
        task.cancel()
        #expect(log.count <= 4)    // initial {}, immediate first, one coalesced flush at 100 ms
        let final = log.last!
        #expect(final.count == 8)
        #expect(final.values.allSatisfy { $0.virtual.core == 24 })
    }

    // MARK: Follow

    @Test func followUnfollowPublishesAndPersists() async throws {
        let clock = TestClock()
        let history = try HistoryStore(path: ":memory:", clock: clock)
        let store = ProbeStore(clock: clock, persistence: history)
        let log = StoreLog<Set<ProbeSerial>>()
        let stream = store.followed
        let task = Task { for await s in stream { log.add(s) } }
        await store.start()
        await store.follow(F.serial)
        await store.follow(ProbeSerial(2))
        await store.unfollow(ProbeSerial(2))
        for _ in 0..<200 where log.last != [F.serial] { await clock.settle() }
        #expect(log.last == [F.serial])
        #expect(await store.followedSerials() == [F.serial])
        task.cancel()

        let reopened = ProbeStore(clock: clock, persistence: history)
        await reopened.start()
        #expect(await reopened.followedSerials() == [F.serial])
    }

    @Test func followWithoutPersistenceWorks() async {
        let store = makeStore(TestClock())
        await store.follow(F.serial)
        #expect(await store.followedSerials() == [F.serial])
        await store.unfollow(F.serial)
        #expect(await store.followedSerials().isEmpty)
    }

    @Test func eightProbesAtOnce() async {
        let clock = TestClock()
        let store = makeStore(clock)
        for i in 1...8 {
            let s = ProbeSerial(UInt32(i))
            await store.ingest(F.observe(.status(F.status(core: Double(i) * 10)), kind: .directConnection, at: clock.now(), serial: s))
        }
        let all = await store.snapshots()
        #expect(all.count == 8)
        #expect(all[ProbeSerial(3)]?.virtual.core == 30)
    }
}
