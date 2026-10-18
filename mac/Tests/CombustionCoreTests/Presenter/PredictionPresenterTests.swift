import CombustionCodec
import CombustionCore
import Foundation
import Testing

/// docs/02 §7: the iOS `PredictionManager` rules, on a `TestClock`.
struct PredictionPresenterTests {
    typealias F = StoreFixtures

    private struct Rig {
        let clock = TestClock()
        let store: ProbeStore
        let presenter: PredictionPresenter
        let views = StoreLog<PredictionView>()

        init() async {
            store = ProbeStore(clock: clock)
            presenter = PredictionPresenter(probes: store, clock: clock)
            let stream = presenter.predictions(F.serial)
            let log = views
            Task { for await v in stream { log.add(v) } }
            await clock.settle()
        }

        /// Feeds one status straight to the presenter, as the store's status stream would.
        func status(_ state: PredictionState = .predicting, type: PredictionType? = nil, seconds: UInt32, seq: UInt32,
                    mode: PredictionMode = .timeToRemoval, setpoint: Double = 60, est: Double = 40) async {
            var p = F.prediction(state: state, mode: mode, setpoint: setpoint, seconds: seconds, est: est)
            if let type { p.type = type }
            await presenter.ingest(ProbeStatusEvent(
                serial: F.serial, status: F.status(logMax: seq, prediction: p), receivedAt: clock.now()))
            await clock.settle()
        }

        var latest: PredictionView? { views.last }

        /// The view as of now, computed on demand (does not depend on a timer tick having been delivered yet).
        func shown() async -> PredictionView? { await presenter.view(for: F.serial) }

        /// Moves time, then gives the timer's consumer task extra turns to run (a loaded multi-threaded executor
        /// can lag the clock by more than one `settle`).
        func advance(_ d: Duration) async {
            await clock.advance(by: d)
            for _ in 0..<4 { await clock.settle() }
        }
    }

    // MARK: Above 300 s

    @Test func aboveFiveMinutesRoundsTo15sAndMovesOnlyEveryThirdSeq() async {
        let rig = await Rig()
        await rig.status(seconds: 1000, seq: 3)
        #expect((await rig.shown())?.secondsRemaining == 1005)   // nearest 15 s
        await rig.advance(.seconds(5))
        await rig.status(seconds: 995, seq: 4)
        await rig.advance(.seconds(5))
        await rig.status(seconds: 990, seq: 5)
        #expect((await rig.shown())?.secondsRemaining == 1005, "seq 4 and 5 do not move the number")
        await rig.advance(.seconds(5))
        await rig.status(seconds: 985, seq: 6)
        #expect((await rig.shown())?.secondsRemaining == 990)    // seq % 3 == 0
    }

    @Test func firstStatusSetsTheNumberEvenOffSequence() async {
        let rig = await Rig()
        await rig.status(seconds: 1234, seq: 7)
        #expect((await rig.shown())?.secondsRemaining == 1230)
    }

    @Test func nilUnlessPredictingAndWithinFourHours() async {
        let rig = await Rig()
        await rig.status(.warming, seconds: 600, seq: 0)
        #expect((await rig.shown())?.state == .warming)
        #expect((await rig.shown())?.secondsRemaining == nil)
        await rig.status(seconds: 14_401, seq: 1)
        #expect((await rig.shown())?.secondsRemaining == nil)
        await rig.status(seconds: 14_400, seq: 3)
        #expect((await rig.shown())?.secondsRemaining == 14_400)
        await rig.status(.removalPredictionDone, seconds: 0, seq: 4)
        #expect((await rig.shown())?.secondsRemaining == nil)
    }

    // MARK: At or below 300 s

    @Test func belowFiveMinutesCountsDownLinearlyBetweenStatuses() async {
        let rig = await Rig()
        await rig.status(seconds: 300, seq: 0)
        #expect((await rig.shown())?.secondsRemaining == 300)
        // Aims at raw - 5 s by the next status: one second per second.
        for elapsed in 1...5 {
            await rig.advance(.seconds(1))
            #expect((await rig.shown())?.secondsRemaining == UInt32(300 - elapsed), "after \(elapsed) s")
        }
        // The next status confirms it; the countdown carries on.
        await rig.status(seconds: 295, seq: 1)
        #expect((await rig.shown())?.secondsRemaining == 295)
        await rig.advance(.seconds(5))
        #expect((await rig.shown())?.secondsRemaining == 290)
    }

    @Test func countdownStopsAtTheAimIfTheNextStatusIsLate() async {
        let rig = await Rig()
        await rig.status(seconds: 100, seq: 0)
        await rig.advance(.seconds(9))
        #expect((await rig.shown())?.secondsRemaining == 95, "does not run on past raw - 5 s")
    }

    @Test func countdownIsSmoothWhenEnteringTheLastFiveMinutes() async {
        let rig = await Rig()
        await rig.status(seconds: 315, seq: 3)
        #expect((await rig.shown())?.secondsRemaining == 315)
        await rig.advance(.seconds(5))
        await rig.status(seconds: 310, seq: 4)  // still above 300: held
        #expect((await rig.shown())?.secondsRemaining == 315)
        await rig.advance(.seconds(5))
        await rig.status(seconds: 300, seq: 5)  // at 300: starts from what is on screen and eases to raw - 5
        #expect((await rig.shown())?.secondsRemaining == 315)
        await rig.advance(.seconds(5))
        #expect((await rig.shown())?.secondsRemaining == 295)
    }

    // MARK: readyAt, readySince, stale, percent

    @Test func readyAtIsCompletionTimeAndStaysPutWhileTheCountdownHolds() async {
        let rig = await Rig()
        let t0 = rig.clock.now()
        await rig.status(seconds: 1000, seq: 3)
        #expect((await rig.shown())?.readyAt == t0.addingTimeInterval(1005))
        await rig.advance(.seconds(5))
        await rig.status(seconds: 995, seq: 4)
        #expect((await rig.shown())?.readyAt == t0.addingTimeInterval(1005), "held number, held completion time")

        let low = await Rig()
        let t1 = low.clock.now()
        await low.status(seconds: 200, seq: 0)
        #expect((await low.shown())?.readyAt == t1.addingTimeInterval(200))
        await low.advance(.seconds(5))
        await low.status(seconds: 195, seq: 1)
        #expect((await low.shown())?.readyAt == t1.addingTimeInterval(200), "the estimate did not move")
    }

    @Test func readySinceIsWhenTheStateBecameDone() async {
        let rig = await Rig()
        await rig.status(seconds: 5, seq: 0)
        #expect((await rig.shown())?.readySince == nil)
        await rig.advance(.seconds(5))
        let done = rig.clock.now()
        await rig.status(.removalPredictionDone, seconds: 0, seq: 1)
        #expect((await rig.shown())?.readySince == done)
        await rig.advance(.seconds(5))
        await rig.status(.removalPredictionDone, seconds: 0, seq: 2)
        #expect((await rig.shown())?.readySince == done, "stays at the first done status")
        await rig.status(.inserted, seconds: 0, seq: 3, mode: .none)
        #expect((await rig.shown())?.readySince == nil)
    }

    @Test func staleAfterFifteenSecondsWithoutStatus() async {
        let rig = await Rig()
        await rig.status(seconds: 1000, seq: 3)
        #expect((await rig.shown())?.isStale == false)
        await rig.advance(.seconds(14))
        #expect((await rig.shown())?.isStale == false)
        await rig.advance(.seconds(1))
        #expect((await rig.shown())?.isStale == true)
        #expect((await rig.shown())?.secondsRemaining == 1005, "the last known number stays")
        await rig.status(seconds: 980, seq: 6)
        #expect((await rig.shown())?.isStale == false)
    }

    @Test func percentToRemovalComesFromTheStatus() async {
        let rig = await Rig()
        await rig.status(seconds: 600, seq: 0, setpoint: 60, est: 40)   // heat start 20: (40 - 20) / (60 - 20)
        #expect((await rig.shown())?.percentToRemoval == 50)
        #expect((await rig.shown())?.setpoint == 60)
        #expect((await rig.shown())?.estimatedCore == 40)
    }

    // MARK: Streams

    @Test func streamEmitsEachChangeOnceAndTheStaleFlip() async {
        let rig = await Rig()
        await rig.status(seconds: 100, seq: 0)
        await rig.advance(.seconds(5))
        await rig.status(seconds: 95, seq: 1)
        await rig.advance(.seconds(5))
        await rig.status(seconds: 90, seq: 2)
        await rig.advance(.seconds(20))
        await settle(rig.clock) { rig.latest?.isStale == true }
        let numbers = rig.views.items.map(\.secondsRemaining)
        #expect(numbers.first == 100)
        #expect(numbers.last == 85, "ran on to raw - 5 s")
        #expect(zip(rig.views.items, rig.views.items.dropFirst()).allSatisfy { $0 != $1 }, "no repeated emissions")
        #expect(numbers.count >= 15, "one emission per second of countdown, not per 200 ms tick: \(numbers.count)")
        #expect(numbers.count <= 25)
        #expect(rig.latest?.isStale == true, "the stale flip is emitted too")
        // A late subscriber gets the current view first.
        var it = rig.presenter.predictions(F.serial).makeAsyncIterator()
        #expect(await it.next()?.isStale == true)
    }

    @Test func updatesCarryEveryProbe() async {
        let rig = await Rig()
        let updates = StoreLog<PredictionUpdate>()
        let stream = rig.presenter.updates
        Task { for await u in stream { updates.add(u) } }
        await rig.clock.settle()
        let other = ProbeSerial(0x1000_0002)
        await rig.status(seconds: 1000, seq: 3)
        await rig.presenter.ingest(ProbeStatusEvent(
            serial: other, status: F.status(logMax: 3, prediction: F.prediction(state: .predicting, mode: .timeToRemoval, seconds: 500)),
            receivedAt: rig.clock.now()))
        await settle(rig.clock) { updates.count >= 2 }
        #expect(Set(updates.items.map(\.serial)) == [F.serial, other])
    }

    // MARK: Wiring

    @Test func readsStatusesFromTheProbeStore() async {
        let rig = await Rig()
        await rig.presenter.start()
        await rig.clock.settle()
        let p = F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 60, seconds: 900, est: 40)
        await rig.store.ingest(F.observe(.status(F.status(logMax: 3, prediction: p)), kind: .directConnection, at: rig.clock.now()))
        await settle(rig.clock) { rig.latest != nil }
        #expect(rig.latest?.secondsRemaining == 900)
        #expect(await rig.presenter.view(for: F.serial)?.secondsRemaining == 900)
        await rig.presenter.stop()
    }

    @Test func idleProbeCostsNoTicker() async {
        let rig = await Rig()
        await rig.status(seconds: 1000, seq: 3)
        #expect(rig.clock.timerCount == 1, "only the 1 s stale watcher; no 200 ms ticker above five minutes")
        #expect(rig.clock.sleeperCount == 0)
        await rig.advance(.seconds(20))
        #expect(rig.clock.timerCount == 0, "stale: nothing left to watch")
        await rig.status(seconds: 1000, seq: 3)
        #expect(rig.clock.timerCount == 1)
        await rig.presenter.stop()
        await rig.clock.settle()
        #expect(rig.clock.timerCount == 0)
    }

    // MARK: Matches the Display (M5 exit criterion, unit level)

    /// The probe counts down 1 s per second and reports every 5 s. The Display rounds to 15 s and moves every
    /// third status, so against the probe's own number it is off by up to 7.5 s (rounding) plus 15 s (held for
    /// three statuses) = 22.5 s; the last five minutes follow the probe to within a few seconds. Matching the
    /// Display's rounding is the point (02 §7); this pins the error that rounding implies.
    @Test func countdownTracksTheProbeOverACook() async {
        let rig = await Rig()
        let total = 2400
        var worst = 0.0
        var worstLast5 = 0.0
        var detail = ""
        for second in 0..<total {
            if second % 5 == 0 { await rig.status(seconds: UInt32(total - second), seq: UInt32(second / 5)) }
            if let shown = (await rig.shown())?.secondsRemaining {
                let error = abs(Double(shown) - Double(total - second))
                worst = max(worst, error)
                if total - second <= 290 {
                    if error > worstLast5 { detail = "second \(second): shown \(shown), truth \(total - second)" }
                    worstLast5 = max(worstLast5, error)
                }
            }
            await rig.advance(.seconds(1))
        }
        #expect(worst <= 22.5, "worst error \(worst) s")
        #expect(worstLast5 <= 6, "worst error in the last five minutes \(worstLast5) s (\(detail))")
        #expect((await rig.shown())?.secondsRemaining != nil)
    }
}
