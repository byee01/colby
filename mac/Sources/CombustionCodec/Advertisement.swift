/// MeatNet product types (MeatNet spec "Product Type").
public enum NodeProductType: UInt8, Sendable, Hashable {
    case repeater = 2, gauge = 3, display = 4, booster = 5, engine = 6
}

/// Probe data carried in an advertisement, from a probe directly or repeated by a node.
public struct ProbeAdvertisement: Sendable, Equatable {
    public var serial: ProbeSerial
    public var temperatures: ProbeTemperatures
    public var mode: ProbeMode
    public var color: ProbeColor
    public var probeNumber: Int
    public var batteryLow: Bool
    public var virtualSensors: VirtualSensors
    /// nil when the overheating byte is absent from the packet.
    public var overheating: Set<SensorIndex>?
    /// nil when the preferences byte is absent (node-repeated packets have none).
    public var preferences: ThermometerPreferences?

    public init(
        serial: ProbeSerial, temperatures: ProbeTemperatures, mode: ProbeMode, color: ProbeColor,
        probeNumber: Int, batteryLow: Bool, virtualSensors: VirtualSensors,
        overheating: Set<SensorIndex>? = nil, preferences: ThermometerPreferences? = nil
    ) {
        self.serial = serial
        self.temperatures = temperatures
        self.mode = mode
        self.color = color
        self.probeNumber = probeNumber
        self.batteryLow = batteryLow
        self.virtualSensors = virtualSensors
        self.overheating = overheating
        self.preferences = preferences
    }
}

/// A node's own advertisement (display, booster, gauge, engine): serial and, for display and
/// booster, the preferences byte. Gauge and engine sensor data is out of v1 scope.
public struct NodeAdvertisement: Sendable, Equatable {
    public var productType: NodeProductType
    /// Up to 10 characters, trailing NULs removed.
    public var serial: String
    public var preferences: UInt8?

    public init(productType: NodeProductType, serial: String, preferences: UInt8? = nil) {
        self.productType = productType
        self.serial = serial
        self.preferences = preferences
    }
}

public enum AdvertisementPacket: Sendable, Equatable {
    case probe(ProbeAdvertisement)
    /// A probe's data repeated by a node. `hopCount` is 1...4.
    case repeated(ProbeAdvertisement, hopCount: Int)
    case node(NodeAdvertisement)
    case unknown(productType: UInt8)
}

// Manufacturer specific data, including the 2-byte vendor ID (probe spec "Manufacturer Specific Data"):
// 0-1 vendor 0x09C7 little-endian, 2 product type, 3-6 serial, 7-19 raw temperatures, 20 mode/ID,
// 21 battery + virtual sensors, 22 network information, 23 overheating, 24 preferences (probe only).
private enum Ad {
    static let vendor: [UInt8] = [0xC7, 0x09]
    static let productType = 2
    static let probeSerial = 3
    static let temperatures = 7
    static let modeAndId = 20
    static let battery = 21
    static let network = 22
    static let overheat = 23
    static let preferences = 24
    static let nodeSerial = 3
    static let nodeSerialLength = 10
    static let nodePreferences = 13
    static let packetSize = 25
}

private func probeAdvertisement(_ b: [UInt8]) -> ProbeAdvertisement {
    let ident = ModeAndId(byte: b[Ad.modeAndId])
    return ProbeAdvertisement(
        serial: ProbeSerial(b.u32(at: Ad.probeSerial)),
        temperatures: ProbeTemperatures(packed: Array(b[Ad.temperatures..<Ad.modeAndId])),
        mode: ident.mode,
        color: ident.color,
        probeNumber: ident.probeNumber,
        batteryLow: b[Ad.battery] & 1 != 0,
        virtualSensors: VirtualSensors(bits: UInt32(b[Ad.battery] >> 1)),
        overheating: b.count > Ad.overheat ? OverheatMask.decode(b[Ad.overheat]) : nil,
        preferences: b.count > Ad.preferences ? ThermometerPreferences(byte: b[Ad.preferences]) : nil
    )
}

/// Decodes manufacturer data as delivered by CoreBluetooth or WinRT (vendor ID first).
/// Throws `badSync` for a different vendor ID.
public func decodeAdvertisement(_ mfrData: [UInt8]) throws -> AdvertisementPacket {
    guard mfrData.count > Ad.productType else {
        throw CodecError.tooShort(expected: Ad.productType + 1, actual: mfrData.count)
    }
    guard Array(mfrData[0..<2]) == Ad.vendor else { throw CodecError.badSync }

    let type = mfrData[Ad.productType]
    switch type {
    case 1, 2:
        let needed = type == 1 ? Ad.network : Ad.network + 1
        guard mfrData.count >= needed else {
            throw CodecError.tooShort(expected: needed, actual: mfrData.count)
        }
        let probe = probeAdvertisement(mfrData)
        return type == 1 ? .probe(probe) : .repeated(probe, hopCount: hopCount(networkInformation: mfrData[Ad.network]))
    case 3...6:
        let end = Ad.nodeSerial + Ad.nodeSerialLength
        guard mfrData.count >= end else {
            throw CodecError.tooShort(expected: end, actual: mfrData.count)
        }
        let productType = NodeProductType(rawValue: type)!
        let hasPreferences = productType == .display || productType == .booster
        let serialBytes = mfrData[Ad.nodeSerial..<end].prefix { $0 != 0 }
        return .node(NodeAdvertisement(
            productType: productType,
            serial: String(decoding: serialBytes, as: UTF8.self),
            preferences: hasPreferences && mfrData.count > Ad.nodePreferences ? mfrData[Ad.nodePreferences] : nil
        ))
    default:
        return .unknown(productType: type)
    }
}

/// Builds manufacturer data (vendor ID first): 25 B for a probe, 24 B for a repeated probe unless it
/// carries preferences, 25 B for node packets.
public func encodeAdvertisement(_ packet: AdvertisementPacket) throws -> [UInt8] {
    switch packet {
    case .probe(let probe):
        return try encodeProbeAdvertisement(probe, productType: 1, network: 0)
    case .repeated(let probe, let hops):
        return try encodeProbeAdvertisement(probe, productType: 2, network: try networkInformation(hopCount: hops))
    case .node(let node):
        let serial = Array(node.serial.utf8)
        guard serial.count <= Ad.nodeSerialLength else {
            throw CodecError.outOfRange(field: "node.serial", value: Double(serial.count))
        }
        var out = Ad.vendor + [node.productType.rawValue] + serial
        out += [UInt8](repeating: 0, count: Ad.packetSize - out.count)
        if let preferences = node.preferences { out[Ad.nodePreferences] = preferences }
        return out
    case .unknown(let type):
        return Ad.vendor + [type]
    }
}

private func encodeProbeAdvertisement(_ p: ProbeAdvertisement, productType: UInt8, network: UInt8) throws -> [UInt8] {
    var out = Ad.vendor + [productType]
    out.appendU32(p.serial.rawValue)
    out += p.temperatures.packed()
    out.append(try ModeAndId(mode: p.mode, color: p.color, probeNumber: p.probeNumber).byte())
    out.append((p.batteryLow ? 1 : 0) | UInt8(p.virtualSensors.bits) << 1)
    out.append(network)
    if p.overheating != nil || p.preferences != nil {
        out.append(OverheatMask.encode(p.overheating ?? []))
    }
    if let preferences = p.preferences { out.append(preferences.byte) }
    return out
}
