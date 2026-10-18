/// The 11 alarm channels, in wire order (probe spec "Probe Status": T1...T8, Core, Surface, Ambient).
public enum AlarmChannel: Int, CaseIterable, Hashable, Sendable {
    case t1, t2, t3, t4, t5, t6, t7, t8, core, surface, ambient
}

/// One alarm, a u16 (probe spec "Alarm Status"): bit 1 set, bit 2 tripped, bit 3 alarming,
/// bits 4-16 temperature as `raw × 0.1 − 20` (−20...799 °C).
public struct Alarm: Sendable, Equatable {
    public static let temperatureRange: ClosedRange<Double> = -20...799

    public var isSet: Bool
    public var temperature: Double
    /// Read-only; ignored by the probe on write.
    public var tripped: Bool
    /// Read-only; false after silence.
    public var alarming: Bool

    public init(isSet: Bool, temperature: Double, tripped: Bool = false, alarming: Bool = false) {
        self.isSet = isSet
        self.temperature = temperature
        self.tripped = tripped
        self.alarming = alarming
    }

    /// An alarm that is off, as the probe reports it.
    public static let unset = Alarm(isSet: false, temperature: -20)

    init(word: UInt16) {
        isSet = word & 1 != 0
        tripped = word & 2 != 0
        alarming = word & 4 != 0
        temperature = Double(word >> 3) / 10 - 20
    }

    func word(field: String) throws -> UInt16 {
        guard Self.temperatureRange.contains(temperature) else {
            throw CodecError.outOfRange(field: field, value: temperature)
        }
        let raw = try scaledRaw(temperature, field: field, offset: 20, scale: 10, max: 0x1FFF)
        return UInt16(raw) << 3 | (isSet ? 1 : 0) | (tripped ? 2 : 0) | (alarming ? 4 : 0)
    }
}

/// High and low alarms for every channel. Decoding always fills all 11 channels of each;
/// when encoding, a missing channel is sent as `Alarm.unset`.
public struct AlarmConfig: Sendable, Equatable {
    public static let packedSize = 44

    public var high: [AlarmChannel: Alarm]
    public var low: [AlarmChannel: Alarm]

    public init(high: [AlarmChannel: Alarm] = [:], low: [AlarmChannel: Alarm] = [:]) {
        self.high = high
        self.low = low
    }

    /// Unpacks 44 bytes: 11 high words then 11 low words. The caller has checked the length.
    init(packed bytes: [UInt8]) {
        func words(from start: Int) -> [AlarmChannel: Alarm] {
            Dictionary(uniqueKeysWithValues: AlarmChannel.allCases.map {
                ($0, Alarm(word: bytes.u16(at: start + $0.rawValue * 2)))
            })
        }
        high = words(from: 0)
        low = words(from: 22)
    }

    /// 22 bytes of high alarms then 22 bytes of low alarms; throws `outOfRange` for temperatures outside −20...799 °C.
    public func packed() throws -> [UInt8] {
        var out = [UInt8]()
        for (kind, alarms) in [("high", high), ("low", low)] {
            for channel in AlarmChannel.allCases {
                let alarm = alarms[channel] ?? .unset
                out.appendU16(try alarm.word(field: "alarm.\(kind).\(channel)"))
            }
        }
        return out
    }
}
