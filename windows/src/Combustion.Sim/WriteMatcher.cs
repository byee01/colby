namespace Combustion.Sim;

/// <summary>
/// Decides which recorded write answers an app write. Writes with the same key
/// are considered the same request.
/// </summary>
public interface IWriteMatcher
{
    string Key(GattUuid characteristic, ReadOnlySpan<byte> bytes);
}

/// <summary>
/// Default: for UART RX writes, the message type byte at offset 4 of a probe frame
/// (sync 2, CRC 2, type 1). Anything else is keyed on characteristic and full payload.
/// Not valid for MeatNet node frames, whose request ID varies; swap the matcher for those.
/// </summary>
public sealed class MessageTypeWriteMatcher : IWriteMatcher
{
    public string Key(GattUuid characteristic, ReadOnlySpan<byte> bytes)
    {
        if (characteristic == GattUuid.UartRx && bytes.Length > 4)
        {
            return $"{characteristic}/type:{HexString.Encode(bytes.Slice(4, 1))}";
        }
        return $"{characteristic}/{HexString.Encode(bytes)}";
    }
}
