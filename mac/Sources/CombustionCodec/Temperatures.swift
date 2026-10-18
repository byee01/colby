/// Eight 13-bit raw thermistor readings (13 bytes on the wire, probe spec "Raw Temperature Data").
/// `°C = raw × 0.05 − 20`. Stores raw counts so encode and decode are exact.
/// In Instant Read mode only T1 is meaningful (the instant read temperature); the rest are 0 (−20 °C).
public struct ProbeTemperatures: Sendable, Equatable {
    public static let sensorCount = 8
    public static let packedSize = 13
    public static let maxRaw: UInt16 = 0x1FFF

    public let raw: [UInt16]

    public init(raw: [UInt16]) throws {
        guard raw.count == Self.sensorCount else {
            throw CodecError.outOfRange(field: "temperatures.count", value: Double(raw.count))
        }
        if let bad = raw.first(where: { $0 > Self.maxRaw }) {
            throw CodecError.outOfRange(field: "temperatures.raw", value: Double(bad))
        }
        self.raw = raw
    }

    /// Rounds each value to the nearest 0.05 °C step.
    public init(celsius: [Double]) throws {
        try self.init(raw: celsius.map {
            UInt16(try scaledRaw($0, field: "temperature", offset: 20, scale: 20, max: UInt32(Self.maxRaw)))
        })
    }

    /// Unpacks 13 bytes; the caller has checked the length.
    init(packed bytes: [UInt8]) {
        var reader = BitReader(bytes)
        raw = (0..<Self.sensorCount).map { _ in UInt16(reader.read(13)) }
    }

    public var celsius: [Double] { raw.map(Self.celsius(fromRaw:)) }

    public subscript(sensor: SensorIndex) -> Double {
        Self.celsius(fromRaw: raw[Int(sensor.rawValue)])
    }

    public static func celsius(fromRaw raw: UInt16) -> Double {
        Double(raw) / 20 - 20
    }

    public func packed() -> [UInt8] {
        var writer = BitWriter(byteCount: Self.packedSize)
        for value in raw { writer.write(UInt32(value), bits: 13) }
        return writer.bytes
    }
}

/// Virtual sensor selection, 7 bits (probe spec "Virtual Sensors"): core 3 bits, surface 2, ambient 2.
/// Core is T1...T6, surface T4...T7, ambient T5...T8.
public struct VirtualSensors: Hashable, Sendable {
    public var core: SensorIndex
    public var surface: SensorIndex
    public var ambient: SensorIndex

    public init(core: SensorIndex, surface: SensorIndex, ambient: SensorIndex) throws {
        guard core.rawValue <= SensorIndex.t6.rawValue else {
            throw CodecError.outOfRange(field: "virtualSensors.core", value: Double(core.rawValue))
        }
        guard (SensorIndex.t4.rawValue...SensorIndex.t7.rawValue).contains(surface.rawValue) else {
            throw CodecError.outOfRange(field: "virtualSensors.surface", value: Double(surface.rawValue))
        }
        guard ambient.rawValue >= SensorIndex.t5.rawValue else {
            throw CodecError.outOfRange(field: "virtualSensors.ambient", value: Double(ambient.rawValue))
        }
        self.core = core
        self.surface = surface
        self.ambient = ambient
    }

    /// Decodes 7 bits. Core values 6 and 7 are undefined; like the Android SDK they read as T1.
    init(bits: UInt32) {
        let rawCore = UInt8(bits & 0b111)
        core = rawCore <= 5 ? SensorIndex(rawValue: rawCore)! : .t1
        surface = SensorIndex(rawValue: UInt8((bits >> 3) & 0b11) + 3)!
        ambient = SensorIndex(rawValue: UInt8((bits >> 5) & 0b11) + 4)!
    }

    var bits: UInt32 {
        UInt32(core.rawValue) | UInt32(surface.rawValue - 3) << 3 | UInt32(ambient.rawValue - 4) << 5
    }

    public func temperatures(from temperatures: ProbeTemperatures) -> (core: Double, surface: Double, ambient: Double) {
        (temperatures[core], temperatures[surface], temperatures[ambient])
    }
}
