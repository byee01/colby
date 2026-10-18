import CombustionCore

/// Decides which recorded write answers an app write. Writes with the same key
/// are considered the same request.
public protocol WriteMatcher: Sendable {
    func key(char: GattUUID, bytes: [UInt8]) -> String
}

/// Default: for UART RX writes, the message type byte at offset 4 of a probe frame
/// (sync 2, CRC 2, type 1). Anything else is keyed on characteristic and full payload.
/// Not valid for MeatNet node frames, whose request ID varies; swap the matcher for those.
public struct MessageTypeWriteMatcher: WriteMatcher {
    public init() {}

    public func key(char: GattUUID, bytes: [UInt8]) -> String {
        if char == .uartRX, bytes.count > 4 { return "\(char)/type:\(HexString.encode([bytes[4]]))" }
        return "\(char)/\(HexString.encode(bytes))"
    }
}
