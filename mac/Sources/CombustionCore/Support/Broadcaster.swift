import Foundation

/// Fan-out for AsyncStream: every call to `stream()` gets its own stream.
/// With `replayLatest`, a new stream first receives the most recent value.
public final class Broadcaster<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UInt64: AsyncStream<Element>.Continuation] = [:]
    private var nextID: UInt64 = 0
    private var latest: Element?
    private var finished = false
    private let replayLatest: Bool

    public init(initial: Element? = nil, replayLatest: Bool = false) {
        self.latest = initial
        self.replayLatest = replayLatest
    }

    public func stream() -> AsyncStream<Element> {
        let (stream, continuation) = AsyncStream<Element>.makeStream()
        let (id, isFinished, replay): (UInt64, Bool, Element?) = lock.withLock {
            let id = nextID
            nextID += 1
            if !finished { continuations[id] = continuation }
            return (id, finished, replayLatest ? latest : nil)
        }
        if let replay { continuation.yield(replay) }
        if isFinished {
            continuation.finish()
        } else {
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { _ = self?.continuations.removeValue(forKey: id) }
            }
        }
        return stream
    }

    public func send(_ value: Element) {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            if replayLatest { latest = value }
            return Array(continuations.values)
        }
        for c in targets { c.yield(value) }
    }

    public func finish() {
        let targets: [AsyncStream<Element>.Continuation] = lock.withLock {
            finished = true
            let all = Array(continuations.values)
            continuations.removeAll()
            return all
        }
        for c in targets { c.finish() }
    }
}
