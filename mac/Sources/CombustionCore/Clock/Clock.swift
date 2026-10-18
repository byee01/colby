import Foundation

/// Injectable time (docs/02 §15). Nothing outside `SystemClock` may call
/// `Date()`, `Task.sleep` or `Timer`.
///
/// Note: this shadows `Swift.Clock` inside modules that import CombustionCore.
public protocol Clock: Sendable {
    /// Wall clock (UTC).
    func now() -> Date
    /// Interval time since an arbitrary origin; never jumps.
    func monotonic() -> Duration
    /// Cancellable. Throws `CancellationError` if the task is cancelled.
    func sleep(for duration: Duration) async throws
    /// Ticks every `period`; each element is the monotonic time of the tick.
    /// The stream ends when its consumer stops iterating.
    func timer(every period: Duration) -> AsyncStream<Duration>
}

extension Duration {
    /// Seconds as a Double (for traces and replay timestamps).
    public var totalSeconds: Double {
        let c = components
        return Double(c.seconds) + Double(c.attoseconds) * 1e-18
    }
}

public struct SystemClock: Clock {
    private let origin = ContinuousClock.now

    public init() {}

    public func now() -> Date { Date() }

    public func monotonic() -> Duration { ContinuousClock.now - origin }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }

    public func timer(every period: Duration) -> AsyncStream<Duration> {
        let origin = self.origin
        return AsyncStream { continuation in
            guard period > .zero else {
                continuation.finish()
                return
            }
            let task = Task {
                var next = ContinuousClock.now
                while !Task.isCancelled {
                    next = next + period
                    do { try await Task.sleep(until: next, clock: .continuous) } catch { break }
                    continuation.yield(ContinuousClock.now - origin)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
