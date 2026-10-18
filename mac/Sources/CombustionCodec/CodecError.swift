/// Typed failures of the pure codec. Core maps these to `UartError.codec` and diagnostics counters.
public enum CodecError: Error, Equatable, Sendable {
    /// Fewer bytes than the smallest valid encoding of the message.
    case tooShort(expected: Int, actual: Int)
    /// Not a Combustion packet: bad UART sync bytes or wrong BLE vendor ID.
    case badSync
    /// UART frame whose CRC does not match its contents.
    case badCrc(expected: UInt16, actual: UInt16)
    /// Message type this codec does not decode (or may not send on this variant).
    case unknownMessageType(UInt8)
    /// A value that does not fit its wire field (validation on encode, or a malformed field on decode).
    case outOfRange(field: String, value: Double)
    /// An encode input that the chosen UART variant requires but the caller did not supply.
    case missingField(String)
}
