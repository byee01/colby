public enum FoodSafeMode: Sendable, Hashable { case simplified, integrated }
public enum FoodSafeServing: Sendable, Hashable { case servedImmediately, cookedAndChilled }
public enum FoodSafeState: Sendable, Hashable { case notSafe, safe, safetyImpossible }

/// Food Safe Data (10 bytes) plus Food Safe Status (8 bytes), read-only in v1.
///
/// Data bits: mode 3, product 10, serving 3, threshold 13, z-value 13, reference temp 13, D-value 13,
/// target log reduction 8 (probe spec "Food Safe Data"). The four 13-bit values are `raw × 0.05`.
/// Status bits: state 3, log reduction 8 (`raw × 0.1`), seconds above threshold 16, log sequence 32.
public struct FoodSafe: Sendable, Equatable {
    public static let dataSize = 10
    public static let statusSize = 8

    public var mode: FoodSafeMode
    /// Enum differs by mode; the UI maps it to a label.
    public var product: UInt16
    public var serving: FoodSafeServing
    /// Integrated mode only; nil in simplified mode.
    public var thresholdTemp: Double?
    public var zValue: Double?
    public var referenceTemp: Double?
    public var dValue: Double?
    public var targetLogReduction: Double
    public var state: FoodSafeState
    /// 0 in simplified mode.
    public var logReduction: Double
    public var secondsAboveThreshold: UInt16
    public var logSequence: UInt32

    public init(
        mode: FoodSafeMode, product: UInt16, serving: FoodSafeServing,
        thresholdTemp: Double? = nil, zValue: Double? = nil, referenceTemp: Double? = nil, dValue: Double? = nil,
        targetLogReduction: Double = 0,
        state: FoodSafeState, logReduction: Double = 0, secondsAboveThreshold: UInt16 = 0, logSequence: UInt32 = 0
    ) {
        self.mode = mode
        self.product = product
        self.serving = serving
        self.thresholdTemp = thresholdTemp
        self.zValue = zValue
        self.referenceTemp = referenceTemp
        self.dValue = dValue
        self.targetLogReduction = targetLogReduction
        self.state = state
        self.logReduction = logReduction
        self.secondsAboveThreshold = secondsAboveThreshold
        self.logSequence = logSequence
    }

    /// Returns nil for reserved mode, serving or state values (the Android SDK does the same),
    /// so a newer probe never breaks the rest of the status.
    init?(data: [UInt8], status: [UInt8]) {
        var d = BitReader(data)
        let rawMode = d.read(3)
        let rawProduct = d.read(10)
        let rawServing = d.read(3)
        let threshold = Double(d.read(13)) * 0.05
        let z = Double(d.read(13)) * 0.05
        let reference = Double(d.read(13)) * 0.05
        let dValue = Double(d.read(13)) * 0.05
        let target = Double(d.read(8)) / 10

        var s = BitReader(status)
        let rawState = s.read(3)
        let reduction = Double(s.read(8)) / 10
        let seconds = s.read(16)
        let sequence = s.read(32)

        guard rawMode <= 1, rawServing <= 1, rawState <= 2 else { return nil }
        self.init(
            mode: rawMode == 0 ? .simplified : .integrated,
            product: UInt16(rawProduct),
            serving: rawServing == 0 ? .servedImmediately : .cookedAndChilled,
            thresholdTemp: rawMode == 1 ? threshold : nil,
            zValue: rawMode == 1 ? z : nil,
            referenceTemp: rawMode == 1 ? reference : nil,
            dValue: rawMode == 1 ? dValue : nil,
            targetLogReduction: target,
            state: [.notSafe, .safe, .safetyImpossible][Int(rawState)],
            logReduction: reduction,
            secondsAboveThreshold: UInt16(seconds),
            logSequence: sequence
        )
    }

    /// Packs back into the two wire fields. Integrated values must fit 13 bits at 0.05 (0...409.55).
    public func packed() throws -> (data: [UInt8], status: [UInt8]) {
        func fine(_ value: Double?, _ field: String) throws -> UInt32 {
            try scaledRaw(value ?? 0, field: field, scale: 20, max: 0x1FFF)
        }
        guard product <= 0x3FF else {
            throw CodecError.outOfRange(field: "foodSafe.product", value: Double(product))
        }
        var d = BitWriter(byteCount: Self.dataSize)
        d.write(mode == .simplified ? 0 : 1, bits: 3)
        d.write(UInt32(product), bits: 10)
        d.write(serving == .servedImmediately ? 0 : 1, bits: 3)
        d.write(try fine(thresholdTemp, "foodSafe.thresholdTemp"), bits: 13)
        d.write(try fine(zValue, "foodSafe.zValue"), bits: 13)
        d.write(try fine(referenceTemp, "foodSafe.referenceTemp"), bits: 13)
        d.write(try fine(dValue, "foodSafe.dValue"), bits: 13)
        d.write(try scaledRaw(targetLogReduction, field: "foodSafe.targetLogReduction", scale: 10, max: 255), bits: 8)

        var s = BitWriter(byteCount: Self.statusSize)
        s.write(state == .notSafe ? 0 : state == .safe ? 1 : 2, bits: 3)
        s.write(try scaledRaw(logReduction, field: "foodSafe.logReduction", scale: 10, max: 255), bits: 8)
        s.write(UInt32(secondsAboveThreshold), bits: 16)
        s.write(logSequence, bits: 32)
        return (d.bytes, s.bytes)
    }
}
