import Foundation

/// Deterministic clock. Time moves only in `advance(by:)`.
///
/// Guarantees of `advance(by:)`:
/// - Sleepers and timer ticks fire in deadline order (ties: registration order),
///   and `monotonic()`/`now()` read the deadline of the entry being fired.
/// - After each fired sleeper, `advance` waits until that sleeper's `sleep(for:)`
///   call has returned, then yields to the scheduler `settleYields` more times so
///   the resumed task can run until its next suspension and (for loops) register
///   its next sleep, which is then honoured in the same `advance` if due.
/// - Work that hops through other actors or I/O after waking is not awaited;
///   call `settle()` for more scheduler turns, or await the result you need.
/// - `advance` begins with a `settle()` so tasks spawned just before it can
///   register their sleeps first.
public final class TestClock: Clock, @unchecked Sendable {
    private enum Kind {
        case sleeper(CheckedContinuation<Void, Error>)
        case timer(AsyncStream<Duration>.Continuation, period: Duration)
    }

    private struct Entry {
        var id: UInt64
        var deadline: Duration
        var kind: Kind
    }

    private let lock = NSLock()
    private let startDate: Date
    private var offset: Duration = .zero
    private var entries: [Entry] = []
    private var nextID: UInt64 = 0
    private var pendingWakes = 0

    public static let defaultStart = Date(timeIntervalSince1970: 1_700_000_000)
    public static let settleYields = 8

    public init(start: Date = TestClock.defaultStart) {
        self.startDate = start
    }

    public func now() -> Date {
        startDate.addingTimeInterval(monotonic().totalSeconds)
    }

    public func monotonic() -> Duration {
        lock.withLock { offset }
    }

    /// Sleepers currently waiting.
    public var sleeperCount: Int {
        lock.withLock { entries.filter { if case .sleeper = $0.kind { true } else { false } }.count }
    }

    /// Timers currently live.
    public var timerCount: Int {
        lock.withLock { entries.filter { if case .timer = $0.kind { true } else { false } }.count }
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard duration > .zero else { return }
        let id = lock.withLock { () -> UInt64 in
            defer { nextID += 1 }
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let accepted: Bool = lock.withLock {
                    if Task.isCancelled { return false }
                    entries.append(Entry(id: id, deadline: offset + duration, kind: .sleeper(c)))
                    return true
                }
                if !accepted { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let removed: Entry? = lock.withLock {
                guard let i = entries.firstIndex(where: { $0.id == id }) else { return nil }
                return entries.remove(at: i)
            }
            if case .sleeper(let c)? = removed?.kind { c.resume(throwing: CancellationError()) }
        }
        lock.withLock { pendingWakes -= 1 }
    }

    public func timer(every period: Duration) -> AsyncStream<Duration> {
        AsyncStream { continuation in
            guard period > .zero else {
                continuation.finish()
                return
            }
            let id = lock.withLock { () -> UInt64 in
                let id = nextID
                nextID += 1
                entries.append(Entry(id: id, deadline: offset + period, kind: .timer(continuation, period: period)))
                return id
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { self?.entries.removeAll { $0.id == id } }
            }
        }
    }

    /// Give other tasks a few scheduler turns.
    public func settle() async {
        for _ in 0..<Self.settleYields { await Task.yield() }
    }

    public func advance(by duration: Duration) async {
        precondition(duration >= .zero, "TestClock cannot go backwards")
        await settle()
        let target = lock.withLock { offset + duration }
        while let fire = fireNext(upTo: target) {
            fire()
            while lock.withLock({ pendingWakes }) > 0 { await Task.yield() }
            await settle()
        }
        lock.withLock { offset = target }
        await settle()
    }

    /// Pops the earliest due entry, moves time to its deadline and returns the
    /// action that wakes it (run outside the lock).
    private func fireNext(upTo target: Duration) -> (() -> Void)? {
        lock.withLock {
            var best: Int?
            for (i, e) in entries.enumerated() where e.deadline <= target {
                if let b = best {
                    let cur = entries[b]
                    if e.deadline < cur.deadline || (e.deadline == cur.deadline && e.id < cur.id) { best = i }
                } else {
                    best = i
                }
            }
            guard let i = best else { return nil }
            let entry = entries[i]
            offset = max(offset, entry.deadline)
            switch entry.kind {
            case .sleeper(let c):
                entries.remove(at: i)
                pendingWakes += 1
                return { c.resume() }
            case .timer(let c, let period):
                entries[i].deadline = entry.deadline + period
                let at = entry.deadline
                return { c.yield(at) }
            }
        }
    }
}
