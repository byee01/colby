/// One record from Read Logs: sequence number, 8 raw temperatures, prediction log (24 B on the wire).
public struct LogRecord: Sendable, Equatable {
    public static let packedSize = 24

    public var sequence: UInt32
    public var temperatures: ProbeTemperatures
    public var prediction: PredictionLog

    public init(sequence: UInt32, temperatures: ProbeTemperatures, prediction: PredictionLog) {
        self.sequence = sequence
        self.temperatures = temperatures
        self.prediction = prediction
    }
}

/// Which Device Information string a node relays for a probe.
public enum ProbeInfoKind: Sendable, Hashable {
    case firmware, hardware, model

    /// Fixed string field size in bytes (MeatNet spec 0x46, 0x47, 0x48).
    var fieldSize: Int {
        switch self {
        case .firmware: return 20
        case .hardware: return 16
        case .model: return 50
        }
    }
}

public struct UartResponse: Sendable, Equatable {
    public enum Body: Sendable, Equatable {
        /// `probe` is set for node responses only.
        case sessionInfo(probe: ProbeSerial?, SessionInfo)
        case logRecord(probe: ProbeSerial?, LogRecord)
        case revision(probe: ProbeSerial?, kind: ProbeInfoKind, text: String)
        /// Acknowledgement without a decoded payload; also what every failed response (`success == false`) becomes.
        case ack
    }

    public var messageType: UInt8
    public var success: Bool
    /// Node only.
    public var requestId: UInt32?
    /// Node only.
    public var responseId: UInt32?
    public var body: Body

    public init(messageType: UInt8, success: Bool, requestId: UInt32? = nil, responseId: UInt32? = nil, body: Body) {
        self.messageType = messageType
        self.success = success
        self.requestId = requestId
        self.responseId = responseId
        self.body = body
    }
}

/// Responses with no payload we read (set ID/color, food safe, power mode, reset, set prediction, alarms).
private let ackOnlyTypes: Set<UInt8> = [0x01, 0x02, 0x05, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C]

private func infoKind(_ type: UInt8) -> ProbeInfoKind? {
    switch type {
    case UartMessageType.probeFirmware: return .firmware
    case UartMessageType.probeHardware: return .hardware
    case UartMessageType.probeModel: return .model
    default: return nil
    }
}

/// Interprets a response-direction frame. A failed response (`success == 0`) decodes as `.ack`
/// whatever its payload. Trailing payload bytes are ignored.
public func decodeResponse(_ frame: UartFrame) throws -> UartResponse {
    guard frame.direction == .response else { throw CodecError.unknownMessageType(frame.messageType) }
    let type = frame.messageType
    let isNode = frame.variant == .node
    let kind = isNode ? infoKind(type) : nil
    let known = ackOnlyTypes.contains(type) || type == UartMessageType.readSessionInfo
        || type == UartMessageType.readLogs || kind != nil
    guard known else { throw CodecError.unknownMessageType(type) }

    let success = frame.success ?? false
    func response(_ body: UartResponse.Body) -> UartResponse {
        UartResponse(messageType: type, success: success, requestId: frame.requestId, responseId: frame.responseId, body: body)
    }
    guard success, !ackOnlyTypes.contains(type) else { return response(.ack) }

    let p = frame.payload
    let lead = isNode ? 4 : 0
    func probe() -> ProbeSerial? { isNode ? ProbeSerial(p.u32(at: 0)) : nil }
    switch type {
    case UartMessageType.readSessionInfo:
        try requirePayload(frame, atLeast: lead + 6)
        return response(.sessionInfo(probe: probe(), SessionInfo(sessionId: p.u32(at: lead), samplePeriodMs: p.u16(at: lead + 4))))
    case UartMessageType.readLogs:
        try requirePayload(frame, atLeast: lead + LogRecord.packedSize)
        let record = LogRecord(
            sequence: p.u32(at: lead),
            temperatures: ProbeTemperatures(packed: Array(p[(lead + 4)..<(lead + 17)])),
            prediction: PredictionLog(packed: Array(p[(lead + 17)..<(lead + 24)])))
        return response(.logRecord(probe: probe(), record))
    default:
        let infoKind = kind!
        try requirePayload(frame, atLeast: lead + infoKind.fieldSize)
        let text = p[lead..<(lead + infoKind.fieldSize)].prefix { $0 != 0 }
        return response(.revision(probe: probe(), kind: infoKind, text: String(decoding: text, as: UTF8.self)))
    }
}

/// Builds a response frame, as a simulated probe or node would send it.
/// Node responses need `requestId` and `responseId`; their payloads lead with the probe serial.
public func encodeResponse(_ response: UartResponse, variant: UartVariant) throws -> [UInt8] {
    var payload = [UInt8]()
    func lead(_ probe: ProbeSerial?) throws {
        if variant == .node {
            guard let probe else { throw CodecError.missingField("probe") }
            payload.appendU32(probe.rawValue)
        }
    }
    switch response.body {
    case .ack:
        break
    case .sessionInfo(let probe, let info):
        try lead(probe)
        payload.appendU32(info.sessionId)
        payload.appendU16(info.samplePeriodMs)
    case .logRecord(let probe, let record):
        try lead(probe)
        payload.appendU32(record.sequence)
        payload += record.temperatures.packed()
        payload += try record.prediction.packed()
    case .revision(let probe, let kind, let text):
        try lead(probe)
        let bytes = Array(text.utf8)
        guard bytes.count <= kind.fieldSize else {
            throw CodecError.outOfRange(field: "revision.text", value: Double(bytes.count))
        }
        payload += bytes + [UInt8](repeating: 0, count: kind.fieldSize - bytes.count)
    }
    return try UartFrame(
        variant: variant, direction: .response, messageType: response.messageType,
        requestId: response.requestId, responseId: response.responseId, success: response.success, payload: payload
    ).encoded()
}
