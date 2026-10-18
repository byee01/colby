namespace Combustion.Codec;

/// <summary>
/// Typed failures of the pure codec (Swift <c>CodecError</c>). Value-equal, so tests can compare them.
/// Core maps these to <c>UartError.Codec</c> and diagnostics counters.
/// </summary>
public abstract record CodecError
{
    private CodecError() { }

    /// <summary>Fewer bytes than the smallest valid encoding of the message.</summary>
    public sealed record TooShort(int Expected, int Actual) : CodecError;

    /// <summary>Not a Combustion packet: bad UART sync bytes or wrong BLE vendor ID.</summary>
    public sealed record BadSync : CodecError;

    /// <summary>UART frame whose CRC does not match its contents.</summary>
    public sealed record BadCrc(ushort Expected, ushort Actual) : CodecError;

    /// <summary>Message type this codec does not decode (or may not send on this variant).</summary>
    public sealed record UnknownMessageType(byte Type) : CodecError;

    /// <summary>A value that does not fit its wire field (validation on encode, or a malformed field on decode).</summary>
    public sealed record OutOfRange(string Field, double Value) : CodecError;

    /// <summary>An encode input that the chosen UART variant requires but the caller did not supply.</summary>
    public sealed record MissingField(string Field) : CodecError;
}

/// <summary>Exception carrying a <see cref="CodecError"/>; every throwing codec function throws this.</summary>
public sealed class CodecException : Exception
{
    public CodecException(CodecError error) : base(error.ToString())
    {
        Error = error;
    }

    public CodecError Error { get; }

    internal static CodecException TooShort(int expected, int actual) => new(new CodecError.TooShort(expected, actual));
    internal static CodecException BadSync() => new(new CodecError.BadSync());
    internal static CodecException UnknownMessageType(byte type) => new(new CodecError.UnknownMessageType(type));
    internal static CodecException OutOfRange(string field, double value) => new(new CodecError.OutOfRange(field, value));
    internal static CodecException MissingField(string field) => new(new CodecError.MissingField(field));
}
