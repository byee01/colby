/// Range of log sequence numbers held by the probe (two u32, min then max).
public struct LogRange: Sendable, Equatable {
    public var min: UInt32
    public var max: UInt32

    public init(min: UInt32, max: UInt32) {
        self.min = min
        self.max = max
    }
}

/// Session ID (u32) and log sample period (u16 ms). Probe spec "Session ID".
/// Status decoders return nil instead of a `SessionInfo` with `sessionId == 0` (0 means "not supplied");
/// the Read Session Information response reports the raw value.
public struct SessionInfo: Sendable, Equatable {
    public var sessionId: UInt32
    public var samplePeriodMs: UInt16

    public init(sessionId: UInt32, samplePeriodMs: UInt16) {
        self.sessionId = sessionId
        self.samplePeriodMs = samplePeriodMs
    }

    /// `sessionId == 0` is the reserved "not supplied" value.
    public var isSupplied: Bool { sessionId != 0 }
}
