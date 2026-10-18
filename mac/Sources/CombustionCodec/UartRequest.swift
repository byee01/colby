/// Message types used in v1 (probe spec "Messages", MeatNet spec "Messages").
public enum UartMessageType {
    public static let readSessionInfo: UInt8 = 0x03
    public static let readLogs: UInt8 = 0x04
    public static let setPrediction: UInt8 = 0x05
    public static let setAlarms: UInt8 = 0x0B
    public static let silenceAlarms: UInt8 = 0x0C
    public static let probeStatus: UInt8 = 0x45
    public static let probeFirmware: UInt8 = 0x46
    public static let probeHardware: UInt8 = 0x47
    public static let probeModel: UInt8 = 0x48
    /// Node notification; payload (network topology) is not decoded.
    public static let heartbeat: UInt8 = 0x49
}

/// A command to a probe. Over a node every request also names the probe (`encodeRequest(probe:)`).
public enum UartRequest: Sendable, Equatable {
    case readSessionInfo
    case readLogs(start: UInt32, end: UInt32)
    case setPrediction(setpoint: Double, mode: PredictionMode)
    case setAlarms(AlarmConfig)
    case silenceAlarms
    /// Node only: the probe's firmware, hardware and model strings, relayed from its Device Information service.
    case readProbeFirmware, readProbeHardware, readProbeModel

    public var messageType: UInt8 {
        switch self {
        case .readSessionInfo: return UartMessageType.readSessionInfo
        case .readLogs: return UartMessageType.readLogs
        case .setPrediction: return UartMessageType.setPrediction
        case .setAlarms: return UartMessageType.setAlarms
        case .silenceAlarms: return UartMessageType.silenceAlarms
        case .readProbeFirmware: return UartMessageType.probeFirmware
        case .readProbeHardware: return UartMessageType.probeHardware
        case .readProbeModel: return UartMessageType.probeModel
        }
    }
}

/// A request read back from a frame (used by simulators and round-trip tests).
public struct UartRequestMessage: Sendable, Equatable {
    public var probe: ProbeSerial?
    public var request: UartRequest
    public var requestId: UInt32?

    public init(probe: ProbeSerial?, request: UartRequest, requestId: UInt32?) {
        self.probe = probe
        self.request = request
        self.requestId = requestId
    }
}

/// Node Silence Alarms payload (MeatNet spec): global u8, product type u8, probe serial u32, node serial 10 B.
private let silenceAlarmsNodePayloadSize = 16
private let probeProductType: UInt8 = 1

private func requestPayload(_ request: UartRequest) throws -> [UInt8] {
    var out = [UInt8]()
    switch request {
    case .readSessionInfo, .readProbeFirmware, .readProbeHardware, .readProbeModel:
        break
    case .readLogs(let start, let end):
        out.appendU32(start)
        out.appendU32(end)
    case .setPrediction(let setpoint, let mode):
        out.appendU16(try encodeSetPredictionData(setpoint: setpoint, mode: mode))
    case .setAlarms(let config):
        out = try config.packed()
    case .silenceAlarms:
        break
    }
    return out
}

/// Builds the bytes to write to the UART RX characteristic.
///
/// - probe variant: `probe` and `requestId` are ignored; the node-only reads throw `unknownMessageType`.
/// - node variant: `probe` and `requestId` are required, and the probe serial leads the payload.
public func encodeRequest(
    variant: UartVariant, _ request: UartRequest, probe: ProbeSerial? = nil, requestId: UInt32? = nil
) throws -> [UInt8] {
    var payload = try requestPayload(request)
    if variant == .probe {
        switch request {
        case .readProbeFirmware, .readProbeHardware, .readProbeModel:
            throw CodecError.unknownMessageType(request.messageType)
        default:
            break
        }
    } else {
        guard let probe else { throw CodecError.missingField("probe") }
        if case .silenceAlarms = request {
            payload = [0, probeProductType]
            payload.appendU32(probe.rawValue)
            payload += [UInt8](repeating: 0, count: 10)
        } else {
            var head = [UInt8]()
            head.appendU32(probe.rawValue)
            payload = head + payload
        }
    }
    return try UartFrame(
        variant: variant, direction: .request, messageType: request.messageType,
        requestId: variant == .node ? requestId : nil, payload: payload
    ).encoded()
}

func requirePayload(_ frame: UartFrame, atLeast count: Int) throws {
    guard frame.payload.count >= count else {
        throw CodecError.tooShort(expected: count, actual: frame.payload.count)
    }
}

/// Reads a request back from a frame, the inverse of `encodeRequest`.
public func decodeRequest(_ frame: UartFrame) throws -> UartRequestMessage {
    guard frame.direction == .request else { throw CodecError.unknownMessageType(frame.messageType) }
    let isNode = frame.variant == .node
    let lead = isNode ? 4 : 0
    let p = frame.payload

    let request: UartRequest
    switch frame.messageType {
    case UartMessageType.readSessionInfo:
        try requirePayload(frame, atLeast: lead)
        request = .readSessionInfo
    case UartMessageType.readLogs:
        try requirePayload(frame, atLeast: lead + 8)
        request = .readLogs(start: p.u32(at: lead), end: p.u32(at: lead + 4))
    case UartMessageType.setPrediction:
        try requirePayload(frame, atLeast: lead + 2)
        let (setpoint, mode) = decodeSetPredictionData(p.u16(at: lead))
        request = .setPrediction(setpoint: setpoint, mode: mode)
    case UartMessageType.setAlarms:
        try requirePayload(frame, atLeast: lead + AlarmConfig.packedSize)
        request = .setAlarms(AlarmConfig(packed: Array(p[lead..<(lead + AlarmConfig.packedSize)])))
    case UartMessageType.silenceAlarms:
        try requirePayload(frame, atLeast: isNode ? silenceAlarmsNodePayloadSize : 0)
        request = .silenceAlarms
    case UartMessageType.probeFirmware where isNode:
        try requirePayload(frame, atLeast: lead)
        request = .readProbeFirmware
    case UartMessageType.probeHardware where isNode:
        try requirePayload(frame, atLeast: lead)
        request = .readProbeHardware
    case UartMessageType.probeModel where isNode:
        try requirePayload(frame, atLeast: lead)
        request = .readProbeModel
    default:
        throw CodecError.unknownMessageType(frame.messageType)
    }

    var probe: ProbeSerial?
    if isNode {
        if frame.messageType == UartMessageType.silenceAlarms {
            // Global silence (flag 1) names no probe.
            probe = p[0] == 0 ? ProbeSerial(p.u32(at: 2)) : nil
        } else {
            probe = ProbeSerial(p.u32(at: 0))
        }
    }
    return UartRequestMessage(probe: probe, request: request, requestId: frame.requestId)
}
