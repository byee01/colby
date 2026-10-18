/// Prediction state, 4 bits (probe spec "Prediction State"). Reserved values 5-14 and 15 all read as `unknown`.
public enum PredictionState: Sendable, Hashable {
    case notInserted, inserted, warming, predicting, removalPredictionDone, unknown

    init(raw: UInt32) {
        switch raw {
        case 0: self = .notInserted
        case 1: self = .inserted
        case 2: self = .warming
        case 3: self = .predicting
        case 4: self = .removalPredictionDone
        default: self = .unknown
        }
    }

    var raw: UInt32 {
        switch self {
        case .notInserted: return 0
        case .inserted: return 1
        case .warming: return 2
        case .predicting: return 3
        case .removalPredictionDone: return 4
        case .unknown: return 15
        }
    }
}

/// Prediction mode, 2 bits. Value 3 is reserved.
public enum PredictionMode: UInt8, Sendable, Hashable {
    case none = 0, timeToRemoval = 1, removalAndResting = 2, reserved = 3
}

/// Prediction type, 2 bits: what "seconds remaining" counts down to. Value 3 is reserved.
public enum PredictionType: UInt8, Sendable, Hashable {
    case none = 0, removal = 1, resting = 2, reserved = 3
}

/// Largest prediction set point: 10 bits of 0.1 °C.
public let maxPredictionSetpoint = 102.3

private func tenths(_ value: Double, field: String, offset: Double = 0, max: UInt32) throws -> UInt32 {
    try scaledRaw(value, field: field, offset: offset, scale: 10, max: max)
}

/// Prediction status, 7 bytes (probe spec "Prediction Status"):
/// state 4, mode 2, type 2, set point 10, heat start 10, seconds 17, estimated core 11 bits.
public struct PredictionStatus: Sendable, Equatable {
    public static let packedSize = 7

    public var state: PredictionState
    public var mode: PredictionMode
    public var type: PredictionType
    /// °C, 0.1 steps.
    public var setpoint: Double
    /// °C, core temperature when heating started.
    public var heatStart: Double
    /// As sent by the probe, 0...131071.
    public var rawSecondsRemaining: UInt32
    /// °C, `raw × 0.1 − 20`.
    public var estimatedCore: Double

    public init(
        state: PredictionState, mode: PredictionMode, type: PredictionType,
        setpoint: Double, heatStart: Double, rawSecondsRemaining: UInt32, estimatedCore: Double
    ) {
        self.state = state
        self.mode = mode
        self.type = type
        self.setpoint = setpoint
        self.heatStart = heatStart
        self.rawSecondsRemaining = rawSecondsRemaining
        self.estimatedCore = estimatedCore
    }

    /// `(estCore − heatStart) / (setpoint − heatStart)` as 0...100, nil when the span is not positive.
    public var percentToRemoval: Double? {
        let span = setpoint - heatStart
        guard span > 0 else { return nil }
        return min(100, max(0, (estimatedCore - heatStart) / span * 100))
    }

    init(packed bytes: [UInt8]) {
        var reader = BitReader(bytes)
        state = PredictionState(raw: reader.read(4))
        mode = PredictionMode(rawValue: UInt8(reader.read(2)))!
        type = PredictionType(rawValue: UInt8(reader.read(2)))!
        setpoint = Double(reader.read(10)) / 10
        heatStart = Double(reader.read(10)) / 10
        rawSecondsRemaining = reader.read(17)
        estimatedCore = Double(reader.read(11)) / 10 - 20
    }

    public func packed() throws -> [UInt8] {
        var writer = BitWriter(byteCount: Self.packedSize)
        writer.write(state.raw, bits: 4)
        writer.write(UInt32(mode.rawValue), bits: 2)
        writer.write(UInt32(type.rawValue), bits: 2)
        writer.write(try tenths(setpoint, field: "prediction.setpoint", max: 1023), bits: 10)
        writer.write(try tenths(heatStart, field: "prediction.heatStart", max: 1023), bits: 10)
        guard rawSecondsRemaining <= 0x1FFFF else {
            throw CodecError.outOfRange(field: "prediction.seconds", value: Double(rawSecondsRemaining))
        }
        writer.write(rawSecondsRemaining, bits: 17)
        writer.write(try tenths(estimatedCore, field: "prediction.estimatedCore", offset: 20, max: 2047), bits: 11)
        return writer.bytes
    }
}

/// Prediction log, 7 bytes inside log records (probe spec "Prediction Log"):
/// virtual sensors 7, state 4, mode 2, type 2, set point 10, seconds 17, estimated core 11 bits, 3 reserved.
public struct PredictionLog: Sendable, Equatable {
    public static let packedSize = 7

    public var virtualSensors: VirtualSensors
    public var state: PredictionState
    public var mode: PredictionMode
    public var type: PredictionType
    public var setpoint: Double
    public var rawSecondsRemaining: UInt32
    public var estimatedCore: Double

    public init(
        virtualSensors: VirtualSensors, state: PredictionState, mode: PredictionMode, type: PredictionType,
        setpoint: Double, rawSecondsRemaining: UInt32, estimatedCore: Double
    ) {
        self.virtualSensors = virtualSensors
        self.state = state
        self.mode = mode
        self.type = type
        self.setpoint = setpoint
        self.rawSecondsRemaining = rawSecondsRemaining
        self.estimatedCore = estimatedCore
    }

    init(packed bytes: [UInt8]) {
        var reader = BitReader(bytes)
        virtualSensors = VirtualSensors(bits: reader.read(7))
        state = PredictionState(raw: reader.read(4))
        mode = PredictionMode(rawValue: UInt8(reader.read(2)))!
        type = PredictionType(rawValue: UInt8(reader.read(2)))!
        setpoint = Double(reader.read(10)) / 10
        rawSecondsRemaining = reader.read(17)
        estimatedCore = Double(reader.read(11)) / 10 - 20
    }

    public func packed() throws -> [UInt8] {
        var writer = BitWriter(byteCount: Self.packedSize)
        writer.write(virtualSensors.bits, bits: 7)
        writer.write(state.raw, bits: 4)
        writer.write(UInt32(mode.rawValue), bits: 2)
        writer.write(UInt32(type.rawValue), bits: 2)
        writer.write(try tenths(setpoint, field: "predictionLog.setpoint", max: 1023), bits: 10)
        guard rawSecondsRemaining <= 0x1FFFF else {
            throw CodecError.outOfRange(field: "predictionLog.seconds", value: Double(rawSecondsRemaining))
        }
        writer.write(rawSecondsRemaining, bits: 17)
        writer.write(try tenths(estimatedCore, field: "predictionLog.estimatedCore", offset: 20, max: 2047), bits: 11)
        return writer.bytes
    }
}

/// Set Prediction Data, u16 little-endian (probe spec "Set Prediction Data"): set point 10 bits (0.1 °C), mode 2 bits.
func encodeSetPredictionData(setpoint: Double, mode: PredictionMode) throws -> UInt16 {
    guard mode != .reserved else {
        throw CodecError.outOfRange(field: "prediction.mode", value: Double(mode.rawValue))
    }
    let raw = try tenths(setpoint, field: "prediction.setpoint", max: 1023)
    return UInt16(raw) | UInt16(mode.rawValue) << 10
}

func decodeSetPredictionData(_ value: UInt16) -> (setpoint: Double, mode: PredictionMode) {
    (Double(value & 0x3FF) / 10, PredictionMode(rawValue: UInt8((value >> 10) & 0b11))!)
}
