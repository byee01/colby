import CombustionCodec
import Foundation

/// Detects the start of a new cook from successive full statuses of one probe. docs/02 §6.2. Pure.
///
/// Rules:
/// 1. First status ever seen: new session (`initial`).
/// 2. `sessionId` non-zero and different from the current non-zero id: new session.
/// 3. Otherwise, when the id is 0 on either side (old firmware or node), fallback rules:
///    - `logRange.max` is lower than the previous max: new session;
///    - the probe was missing for more than `gapThreshold` (10 min) and returns with `logRange.min`
///      lower than before (log reset): new session.
/// 4. Current id is 0 and a non-zero id appears (and no fallback rule fires): same session, id adopted.
///
/// Limitation: after a long gap with identical `min` (e.g. 0 both times) and a higher max, the session
/// is treated as continuing; only a session id or a max/min regression can tell cooks apart.
public struct SessionTracker: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case initial, sessionIdChanged, logRangeRegressed, returnedAfterGap
    }

    public enum Decision: Sendable, Equatable {
        case newSession(Reason)
        case continuing
        /// Same session, but its id (previously unknown, 0) is now known.
        case adoptedSessionId(UInt32)
    }

    public static let defaultGapThreshold: TimeInterval = 600

    public let gapThreshold: TimeInterval
    /// nil before the first observation; 0 when the id is unknown.
    public private(set) var currentSessionId: UInt32?
    public private(set) var lastRange: LogRange?
    public private(set) var lastSeen: Date?

    public init(gapThreshold: TimeInterval = SessionTracker.defaultGapThreshold) {
        self.gapThreshold = gapThreshold
    }

    /// Continue a session loaded from storage.
    public init(restoring sessionId: UInt32, logRange: LogRange, lastSeen: Date,
                gapThreshold: TimeInterval = SessionTracker.defaultGapThreshold) {
        self.gapThreshold = gapThreshold
        self.currentSessionId = sessionId
        self.lastRange = logRange
        self.lastSeen = lastSeen
    }

    /// `sessionId` is 0 when the status carried none.
    public mutating func observe(sessionId: UInt32, logRange: LogRange, at time: Date) -> Decision {
        defer {
            lastRange = logRange
            lastSeen = time
        }
        guard let current = currentSessionId else {
            currentSessionId = sessionId
            return .newSession(.initial)
        }
        if sessionId != 0, current != 0, sessionId != current {
            currentSessionId = sessionId
            return .newSession(.sessionIdChanged)
        }
        if sessionId == 0 || current == 0 {
            if let reason = fallbackReason(logRange, at: time) {
                currentSessionId = sessionId
                return .newSession(reason)
            }
        }
        if current == 0, sessionId != 0 {
            currentSessionId = sessionId
            return .adoptedSessionId(sessionId)
        }
        return .continuing
    }

    private func fallbackReason(_ range: LogRange, at time: Date) -> Reason? {
        guard let last = lastRange else { return nil }
        if range.max < last.max { return .logRangeRegressed }
        if let seen = lastSeen, time.timeIntervalSince(seen) > gapThreshold, range.min < last.min {
            return .returnedAfterGap
        }
        return nil
    }
}
