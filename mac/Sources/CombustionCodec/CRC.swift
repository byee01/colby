/// CRC-16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no final xor).
/// Probe spec "Request Header"; MeatNet spec "Request Header" / "Response Header".
public func crc16Ccitt(_ bytes: some Sequence<UInt8>) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in bytes {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}
