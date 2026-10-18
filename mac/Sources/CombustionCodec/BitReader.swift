/// Reads LSB-first packed fields. The specs number bits from 1 at the LSB of byte 0,
/// so fields are read in order from the LSB: "bits 1-4" is `read(4)`, then "bits 5-6" is `read(2)`.
struct BitReader {
    private let bytes: [UInt8]
    private var position = 0

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Reads `count` bits (at most 32) and advances. Callers check the length first.
    mutating func read(_ count: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<count {
            let bit = (bytes[position >> 3] >> UInt8(position & 7)) & 1
            value |= UInt32(bit) << UInt32(i)
            position += 1
        }
        return value
    }

}

/// Writes LSB-first packed fields into a zeroed buffer of fixed size.
struct BitWriter {
    private(set) var bytes: [UInt8]
    private var position = 0

    init(byteCount: Int) {
        bytes = [UInt8](repeating: 0, count: byteCount)
    }

    /// Writes the low `count` bits of `value` (at most 32) and advances.
    mutating func write(_ value: UInt32, bits count: Int) {
        for i in 0..<count {
            if (value >> UInt32(i)) & 1 == 1 {
                bytes[position >> 3] |= 1 << UInt8(position & 7)
            }
            position += 1
        }
    }

}

extension Array where Element == UInt8 {
    func u16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(u16(at: offset)) | UInt32(u16(at: offset + 2)) << 16
    }

    mutating func appendU16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendU32(_ value: UInt32) {
        appendU16(UInt16(truncatingIfNeeded: value))
        appendU16(UInt16(truncatingIfNeeded: value >> 16))
    }
}

/// Rounds a scaled value to the nearest integer and range-checks it for a wire field.
func scaledRaw(_ value: Double, field: String, offset: Double = 0, scale: Double, max: UInt32) throws -> UInt32 {
    let raw = ((value + offset) * scale).rounded()
    guard raw >= 0, raw <= Double(max) else {
        throw CodecError.outOfRange(field: field, value: value)
    }
    return UInt32(raw)
}
