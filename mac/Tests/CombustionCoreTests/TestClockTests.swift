import CombustionCore
import Foundation
import Testing

final class SyncLog<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func add(_ v: T) { lock.withLock { storage.append(v) } }
    var items: [T] { lock.withLock { storage } }
}

struct TestClockTests {
    @Test func timeMovesOnlyOnAdvance() async {
        let clock = TestClock()
        let w0 = clock.now()
        #expect(clock.monotonic() == .zero)
        await clock.advance(by: .seconds(90))
        #expect(clock.monotonic() == .seconds(90))
        #expect(clock.now().timeIntervalSince(w0) == 90)
        #expect(clock.monotonic() == .seconds(90))
    }

    @Test func sleepersWakeInDeadlineOrder() async {
        let clock = TestClock()
        let log = SyncLog<Int>()
        var tasks: [Task<Void, Never>] = []
        for s in [3, 1, 2] {
            tasks.append(Task {
                try? await clock.sleep(for: .seconds(s))
                log.add(s)
            })
        }
        await clock.settle()
        #expect(clock.sleeperCount == 3)
        await clock.advance(by: .seconds(5))
        for t in tasks { await t.value }
        #expect(log.items == [1, 2, 3])
        #expect(clock.sleeperCount == 0)
        #expect(clock.monotonic() == .seconds(5))
    }

    @Test func equalDeadlinesWakeInRegistrationOrder() async {
        let clock = TestClock()
        let log = SyncLog<String>()
        var tasks: [Task<Void, Never>] = []
        for name in ["a", "b", "c"] {
            tasks.append(Task {
                try? await clock.sleep(for: .seconds(1))
                log.add(name)
            })
            await clock.settle()  // pin registration order
        }
        await clock.advance(by: .seconds(1))
        for t in tasks { await t.value }
        #expect(log.items == ["a", "b", "c"])
    }

    @Test func partialAdvanceDoesNotWakeEarly() async {
        let clock = TestClock()
        let log = SyncLog<String>()
        let t = Task {
            try? await clock.sleep(for: .seconds(10))
            log.add("woke")
        }
        await clock.advance(by: .seconds(9))
        #expect(log.items.isEmpty)
        #expect(clock.sleeperCount == 1)
        await clock.advance(by: .seconds(1))
        await t.value
        #expect(log.items == ["woke"])
    }

    @Test func sleepLoopRunsEveryIterationWithinOneAdvance() async {
        let clock = TestClock()
        let log = SyncLog<Duration>()
        let t = Task {
            for _ in 0..<5 {
                try? await clock.sleep(for: .seconds(1))
                log.add(clock.monotonic())
            }
        }
        await clock.advance(by: .seconds(10))
        await t.value
        #expect(log.items.count == 5)
        #expect(clock.monotonic() == .seconds(10))
    }

    @Test func zeroAndNegativeSleepReturnImmediately() async throws {
        let clock = TestClock()
        try await clock.sleep(for: .zero)
        try await clock.sleep(for: .seconds(-1))
        #expect(clock.sleeperCount == 0)
        #expect(clock.monotonic() == .zero)
    }

    @Test func cancellingASleeperThrowsAndUnregisters() async {
        let clock = TestClock()
        let t = Task { () -> Bool in
            do {
                try await clock.sleep(for: .seconds(60))
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await clock.settle()
        #expect(clock.sleeperCount == 1)
        t.cancel()
        #expect(await t.value)
        #expect(clock.sleeperCount == 0)
        await clock.advance(by: .seconds(120))  // nothing left to fire
    }

    @Test func alreadyCancelledTaskThrowsWithoutRegistering() async {
        let clock = TestClock()
        let t = Task { () -> Bool in
            while !Task.isCancelled { await Task.yield() }
            return (try? await clock.sleep(for: .seconds(1))) == nil
        }
        t.cancel()
        #expect(await t.value)
        #expect(clock.sleeperCount == 0)
    }

    @Test func timerTicksAtEachPeriod() async {
        let clock = TestClock()
        var ticks = clock.timer(every: .seconds(1)).makeAsyncIterator()
        await clock.advance(by: .milliseconds(3500))
        var seen: [Duration] = []
        for _ in 0..<3 { if let t = await ticks.next() { seen.append(t) } }
        #expect(seen == [.seconds(1), .seconds(2), .seconds(3)])
        await clock.advance(by: .milliseconds(500))
        #expect(await ticks.next() == .seconds(4))
    }

    @Test func multipleTimersInterleaveInDeadlineOrder() async {
        let clock = TestClock()
        let log = SyncLog<String>()
        let fast = clock.timer(every: .milliseconds(300))
        let slow = clock.timer(every: .milliseconds(500))
        let a = Task { for await t in fast { log.add("fast@\(t.components.attoseconds / 1_000_000_000_000_000)") } }
        let b = Task { for await t in slow { log.add("slow@\(t.components.attoseconds / 1_000_000_000_000_000)") } }
        await clock.settle()
        await clock.advance(by: .milliseconds(1000))
        a.cancel()
        b.cancel()
        // 300, 500, 600, 900, 1000 (1.0 s reports 0 ms of attoseconds)
        #expect(log.items == ["fast@300", "slow@500", "fast@600", "fast@900", "slow@0"])
    }

    @Test func timerAndSleeperShareOneTimeline() async {
        let clock = TestClock()
        let log = SyncLog<String>()
        let timer = clock.timer(every: .seconds(2))
        let tt = Task { for await _ in timer { log.add("tick") } }
        let st = Task {
            try? await clock.sleep(for: .seconds(3))
            log.add("sleep")
        }
        await clock.settle()
        await clock.advance(by: .seconds(4))
        tt.cancel()
        await st.value
        #expect(log.items == ["tick", "sleep", "tick"])
    }

    @Test func timerUnregistersWhenConsumerStops() async {
        let clock = TestClock()
        let t = Task { for await _ in clock.timer(every: .seconds(1)) {} }
        await clock.settle()
        #expect(clock.timerCount == 1)
        t.cancel()
        await t.value
        await clock.settle()
        #expect(clock.timerCount == 0)
    }

    @Test func nonPositiveTimerPeriodFinishesImmediately() async {
        let clock = TestClock()
        var it = clock.timer(every: .zero).makeAsyncIterator()
        #expect(await it.next() == nil)
    }

    @Test func durationSecondsConversion() {
        #expect(Duration.milliseconds(1500).totalSeconds == 1.5)
    }

    @Test func systemClockMonotonicNeverGoesBackwards() {
        let c = SystemClock()
        let a = c.monotonic()
        let b = c.monotonic()
        #expect(b >= a)
    }
}

struct TestClockWakeGraceTests {
    /// `wakeGrace` is real time spent after each fired sleeper (not after timer ticks), so a woken task
    /// that is slow to reach its next sleep is not overtaken by virtual time.
    @Test func wakeGracePausesAfterEachFiredSleeperOnly() async throws {
        let clock = TestClock(wakeGrace: .milliseconds(20))
        let wakes = SyncLog<Double>()
        let task = Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: .seconds(1)) } catch { return }
                wakes.add(clock.monotonic().totalSeconds)
            }
        }
        while clock.sleeperCount == 0 { await Task.yield() }
        let started = ContinuousClock.now
        await clock.advance(by: .seconds(3))
        let elapsed = ContinuousClock.now - started
        task.cancel()
        #expect(wakes.items == [1, 2, 3])
        #expect(elapsed >= .milliseconds(60))

        // Timer ticks do not pay the grace.
        let ticks = clock.timer(every: .milliseconds(10))
        let counter = SyncLog<Int>()
        let consumer = Task { for await _ in ticks { counter.add(1) } }
        let timerStart = ContinuousClock.now
        await clock.advance(by: .seconds(1)) // 100 ticks
        let timerElapsed = ContinuousClock.now - timerStart
        consumer.cancel()
        #expect(timerElapsed < .milliseconds(1500), "100 ticks at 20 ms each would take 2 s")
    }
}
