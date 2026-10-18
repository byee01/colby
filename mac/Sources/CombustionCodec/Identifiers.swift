/// Probe serial number: u32 on the wire, shown as 8 uppercase hex characters.
public struct ProbeSerial: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: UInt32

    public init(_ rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// Parses 1 to 8 hex digits, either case.
    public init?(hex: String) {
        guard (1...8).contains(hex.count), let value = UInt32(hex, radix: 16) else { return nil }
        self.rawValue = value
    }

    public var hex: String {
        let digits = String(rawValue, radix: 16, uppercase: true)
        return String(repeating: "0", count: 8 - digits.count) + digits
    }

    public var description: String { hex }

    public static func < (lhs: ProbeSerial, rhs: ProbeSerial) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Thermistor T1 (tip) to T8 (handle end). `rawValue` is the zero-based position.
public enum SensorIndex: UInt8, CaseIterable, Comparable, Sendable {
    case t1, t2, t3, t4, t5, t6, t7, t8

    public static func < (lhs: SensorIndex, rhs: SensorIndex) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Mode/ID byte, bits 1-2 (probe spec "Mode and ID Data").
public enum ProbeMode: UInt8, Sendable {
    case normal = 0
    case instantRead = 1
    case reserved = 2
    case error = 3
}

/// Mode/ID byte, bits 3-5. Only 0 (yellow) and 1 (grey) are defined; the rest keep their raw value.
public enum ProbeColor: Hashable, Sendable {
    case yellow
    case grey
    case unknown(UInt8)

    init(raw: UInt8) {
        switch raw {
        case 0: self = .yellow
        case 1: self = .grey
        default: self = .unknown(raw)
        }
    }

    var raw: UInt8 {
        switch self {
        case .yellow: return 0
        case .grey: return 1
        case .unknown(let n): return n
        }
    }
}

/// Power mode, thermometer preferences bits 1-2.
public enum ProbePowerMode: Hashable, Sendable {
    case normal
    case alwaysOn
    case reserved(UInt8)
}

/// Thermometer preferences byte (probe spec "Thermometer Preferences").
public struct ThermometerPreferences: Hashable, Sendable {
    public var powerMode: ProbePowerMode
    /// Bit 3: transmits at +8 dBm instead of +0 dBm.
    public var highRadioPower: Bool

    public init(powerMode: ProbePowerMode, highRadioPower: Bool) {
        self.powerMode = powerMode
        self.highRadioPower = highRadioPower
    }

    init(byte: UInt8) {
        switch byte & 0b11 {
        case 0: powerMode = .normal
        case 1: powerMode = .alwaysOn
        case let n: powerMode = .reserved(n)
        }
        highRadioPower = byte & 0b100 != 0
    }

    var byte: UInt8 {
        let power: UInt8
        switch powerMode {
        case .normal: power = 0
        case .alwaysOn: power = 1
        case .reserved(let n): power = n & 0b11
        }
        return power | (highRadioPower ? 0b100 : 0)
    }
}

/// Mode/ID byte: mode (bits 1-2), color (3-5), probe identifier (6-8, stored 0-7, shown 1-8).
struct ModeAndId {
    var mode: ProbeMode
    var color: ProbeColor
    var probeNumber: Int

    init(mode: ProbeMode, color: ProbeColor, probeNumber: Int) {
        self.mode = mode
        self.color = color
        self.probeNumber = probeNumber
    }

    init(byte: UInt8) {
        mode = ProbeMode(rawValue: byte & 0b11)!
        color = ProbeColor(raw: (byte >> 2) & 0b111)
        probeNumber = Int(byte >> 5) + 1
    }

    func byte() throws -> UInt8 {
        guard (1...8).contains(probeNumber) else {
            throw CodecError.outOfRange(field: "probeNumber", value: Double(probeNumber))
        }
        guard color.raw <= 7 else {
            throw CodecError.outOfRange(field: "color", value: Double(color.raw))
        }
        return mode.rawValue | color.raw << 2 | UInt8(probeNumber - 1) << 5
    }
}

/// Overheating sensors byte. Bit n (zero-based from the LSB) is sensor T(n+1).
enum OverheatMask {
    static func decode(_ byte: UInt8) -> Set<SensorIndex> {
        Set(SensorIndex.allCases.filter { byte & (1 << $0.rawValue) != 0 })
    }

    static func encode(_ sensors: Set<SensorIndex>) -> UInt8 {
        sensors.reduce(0) { $0 | 1 << $1.rawValue }
    }
}
