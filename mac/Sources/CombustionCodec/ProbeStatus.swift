/// Which wire size to produce when encoding a status. `legacy` omits session ID and sample period
/// (94 B probe GATT, 99 B node `0x45`); `current` includes them (100 B / 105 B).
public enum StatusLayout: Sendable {
    case legacy, current
}

/// Everything in a Probe Status notification (probe spec "Probe status"), shared by the GATT
/// characteristic and the node `0x45` message. Fields past the minimum 30 bytes are nil when the
/// payload is too short to carry them.
public struct ProbeStatusPayload: Sendable, Equatable {
    public var logRange: LogRange
    public var temperatures: ProbeTemperatures
    public var mode: ProbeMode
    public var color: ProbeColor
    /// 1...8 (wire value 0-7 plus one).
    public var probeNumber: Int
    public var batteryLow: Bool
    public var virtualSensors: VirtualSensors
    public var prediction: PredictionStatus
    public var foodSafe: FoodSafe?
    public var overheating: Set<SensorIndex>?
    public var preferences: ThermometerPreferences?
    public var alarms: AlarmConfig?
    /// nil when the fields are absent (old firmware or old node) or the session ID is 0.
    public var session: SessionInfo?

    public init(
        logRange: LogRange, temperatures: ProbeTemperatures, mode: ProbeMode, color: ProbeColor,
        probeNumber: Int, batteryLow: Bool, virtualSensors: VirtualSensors, prediction: PredictionStatus,
        foodSafe: FoodSafe? = nil, overheating: Set<SensorIndex>? = nil,
        preferences: ThermometerPreferences? = nil, alarms: AlarmConfig? = nil, session: SessionInfo? = nil
    ) {
        self.logRange = logRange
        self.temperatures = temperatures
        self.mode = mode
        self.color = color
        self.probeNumber = probeNumber
        self.batteryLow = batteryLow
        self.virtualSensors = virtualSensors
        self.prediction = prediction
        self.foodSafe = foodSafe
        self.overheating = overheating
        self.preferences = preferences
        self.alarms = alarms
        self.session = session
    }
}

/// A decoded node `0x45` message.
public struct NodeProbeStatus: Sendable, Equatable {
    public var serial: ProbeSerial
    public var status: ProbeStatusPayload
    /// 1...4 repeater network hops from the probe.
    public var hopCount: Int

    public init(serial: ProbeSerial, status: ProbeStatusPayload, hopCount: Int) {
        self.serial = serial
        self.status = status
        self.hopCount = hopCount
    }
}

// Offsets within the status, excluding the node's leading serial (probe spec "Probe status",
// MeatNet spec "Probe Status (0x45)"). The node message inserts one Network Information byte after
// Food Safe Status; everything after it shifts by one.
private enum Offset {
    static let temperatures = 8
    static let modeAndId = 21
    static let batteryAndVirtual = 22
    static let prediction = 23
    static let foodSafeData = 30
    static let foodSafeStatus = 40
    static let afterFoodSafe = 48
    static let minimum = 30
    /// Old nodes (35 B payload) send Network Information straight after the prediction status.
    static let legacyNodeNetwork = 30
}

private func parseStatus(_ b: [UInt8], networkByte: Bool) throws -> ProbeStatusPayload {
    guard b.count >= Offset.minimum else {
        throw CodecError.tooShort(expected: Offset.minimum, actual: b.count)
    }
    let ident = ModeAndId(byte: b[Offset.modeAndId])
    let battery = b[Offset.batteryAndVirtual]
    let foodSafe = b.count >= Offset.afterFoodSafe
        ? FoodSafe(
            data: Array(b[Offset.foodSafeData..<Offset.foodSafeStatus]),
            status: Array(b[Offset.foodSafeStatus..<Offset.afterFoodSafe]))
        : nil

    let base = Offset.afterFoodSafe + (networkByte ? 1 : 0)
    let alarmsEnd = base + 2 + AlarmConfig.packedSize
    return ProbeStatusPayload(
        logRange: LogRange(min: b.u32(at: 0), max: b.u32(at: 4)),
        temperatures: ProbeTemperatures(packed: Array(b[Offset.temperatures..<Offset.modeAndId])),
        mode: ident.mode,
        color: ident.color,
        probeNumber: ident.probeNumber,
        batteryLow: battery & 1 != 0,
        virtualSensors: VirtualSensors(bits: UInt32(battery >> 1)),
        prediction: PredictionStatus(packed: Array(b[Offset.prediction..<Offset.foodSafeData])),
        foodSafe: foodSafe,
        overheating: b.count > base ? OverheatMask.decode(b[base]) : nil,
        preferences: b.count > base + 1 ? ThermometerPreferences(byte: b[base + 1]) : nil,
        alarms: b.count >= alarmsEnd ? AlarmConfig(packed: Array(b[(base + 2)..<alarmsEnd])) : nil,
        session: b.count >= alarmsEnd + 6 ? sessionInfo(b, at: alarmsEnd) : nil
    )
}

private func sessionInfo(_ b: [UInt8], at offset: Int) -> SessionInfo? {
    let id = b.u32(at: offset)
    return id == 0 ? nil : SessionInfo(sessionId: id, samplePeriodMs: b.u16(at: offset + 4))
}

/// Decodes the probe's Probe Status characteristic: 94 B (firmware without session fields) or 100 B.
/// Trailing bytes beyond the known layout are ignored.
public func decodeProbeStatus(_ bytes: [UInt8]) throws -> ProbeStatusPayload {
    try parseStatus(bytes, networkByte: false)
}

/// Decodes the payload of a node `0x45` Probe Status message: probe serial, status, hop count.
/// 99 B (node without session fields) or 105 B; a 35 B payload from the oldest nodes is also accepted.
public func decodeNodeProbeStatus(_ bytes: [UInt8]) throws -> NodeProbeStatus {
    guard bytes.count >= 4 + Offset.minimum + 1 else {
        throw CodecError.tooShort(expected: 4 + Offset.minimum + 1, actual: bytes.count)
    }
    let rest = Array(bytes[4...])
    let networkOffset: Int
    if rest.count == Offset.legacyNodeNetwork + 1 {
        networkOffset = Offset.legacyNodeNetwork
    } else {
        networkOffset = Offset.afterFoodSafe
        guard rest.count > networkOffset else {
            throw CodecError.tooShort(expected: 4 + networkOffset + 1, actual: bytes.count)
        }
    }
    return NodeProbeStatus(
        serial: ProbeSerial(bytes.u32(at: 0)),
        status: try parseStatus(rest, networkByte: true),
        hopCount: hopCount(networkInformation: rest[networkOffset])
    )
}

/// Network Information byte. The hop count (0 = 1 hop ... 3 = 4 hops) is in the top two bits:
/// the MeatNet spec says bits 1-2 but both Combustion SDKs shift by 6. See docs/01 discrepancy notes.
func hopCount(networkInformation byte: UInt8) -> Int {
    Int(byte >> 6) + 1
}

func networkInformation(hopCount: Int) throws -> UInt8 {
    guard (1...4).contains(hopCount) else {
        throw CodecError.outOfRange(field: "hopCount", value: Double(hopCount))
    }
    return UInt8(hopCount - 1) << 6
}

private func statusBytes(_ s: ProbeStatusPayload, networkByte: UInt8?, layout: StatusLayout) throws -> [UInt8] {
    guard let foodSafe = s.foodSafe else { throw CodecError.missingField("foodSafe") }
    guard let overheating = s.overheating else { throw CodecError.missingField("overheating") }
    guard let preferences = s.preferences else { throw CodecError.missingField("preferences") }
    guard let alarms = s.alarms else { throw CodecError.missingField("alarms") }
    let ident = try ModeAndId(mode: s.mode, color: s.color, probeNumber: s.probeNumber).byte()

    var out = [UInt8]()
    out.appendU32(s.logRange.min)
    out.appendU32(s.logRange.max)
    out += s.temperatures.packed()
    out.append(ident)
    out.append((s.batteryLow ? 1 : 0) | UInt8(s.virtualSensors.bits) << 1)
    out += try s.prediction.packed()
    let food = try foodSafe.packed()
    out += food.data + food.status
    if let networkByte { out.append(networkByte) }
    out.append(OverheatMask.encode(overheating))
    out.append(preferences.byte)
    out += try alarms.packed()
    if layout == .current {
        out.appendU32(s.session?.sessionId ?? 0)
        out.appendU16(s.session?.samplePeriodMs ?? 0)
    }
    return out
}

/// Encodes a probe GATT status. Requires `foodSafe`, `overheating`, `preferences` and `alarms`.
/// A nil `session` is written as zeros.
public func encodeProbeStatus(_ status: ProbeStatusPayload, layout: StatusLayout = .current) throws -> [UInt8] {
    try statusBytes(status, networkByte: nil, layout: layout)
}

/// Encodes the payload of a node `0x45` message.
public func encodeNodeProbeStatus(_ status: NodeProbeStatus, layout: StatusLayout = .current) throws -> [UInt8] {
    var out = [UInt8]()
    out.appendU32(status.serial.rawValue)
    out += try statusBytes(status.status, networkByte: try networkInformation(hopCount: status.hopCount), layout: layout)
    return out
}
