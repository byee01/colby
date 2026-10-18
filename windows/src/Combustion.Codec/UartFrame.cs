namespace Combustion.Codec;

/// <summary>Which UART dialect: a probe's own UART (no request IDs) or a MeatNet node's (request/response IDs).</summary>
public enum UartVariant { Probe, Node }

public enum UartDirection { Request, Response }

/// <summary>
/// One framed UART message with a verified CRC.
/// <para>
/// Probe header: sync <c>CA FE</c>, CRC u16, type, [success], length. Node header: sync, CRC, type
/// (MSB 1 for responses), request ID u32, [response ID u32, success], length. The CRC covers every
/// byte after itself. Node notifications such as <c>0x45</c> arrive as <c>Request</c>-direction frames.
/// </para>
/// </summary>
public readonly record struct UartFrame : IEquatable<UartFrame>
{
    private readonly byte[]? _payload;

    public UartFrame(
        UartVariant variant, UartDirection direction, byte messageType,
        uint? requestId = null, uint? responseId = null, bool? success = null, byte[]? payload = null)
    {
        Variant = variant;
        Direction = direction;
        MessageType = messageType;
        RequestId = requestId;
        ResponseId = responseId;
        Success = success;
        _payload = payload;
    }

    public UartVariant Variant { get; init; }

    public UartDirection Direction { get; init; }

    /// <summary>Message type with the node response flag (MSB) removed.</summary>
    public byte MessageType { get; init; }

    /// <summary>Node only.</summary>
    public uint? RequestId { get; init; }

    /// <summary>Node responses only.</summary>
    public uint? ResponseId { get; init; }

    /// <summary>Responses only.</summary>
    public bool? Success { get; init; }

    public byte[] Payload
    {
        get => _payload ?? [];
        init => _payload = value;
    }

    /// <summary>Serializes with sync bytes and CRC. Throws if a header field this variant needs is null.</summary>
    public byte[] Encoded()
    {
        var payload = Payload;
        if (payload.Length > 255)
        {
            throw CodecException.OutOfRange("payload.length", payload.Length);
        }
        if (MessageType >= 0x80)
        {
            throw CodecException.OutOfRange("messageType", MessageType);
        }
        var isResponse = Direction == UartDirection.Response;
        var body = new List<byte>(payload.Length + 16)
        {
            Variant == UartVariant.Node && isResponse ? (byte)(MessageType | 0x80) : MessageType,
        };
        if (Variant == UartVariant.Node)
        {
            if (RequestId is not { } requestId) { throw CodecException.MissingField("requestId"); }
            body.AppendU32(requestId);
            if (isResponse)
            {
                if (ResponseId is not { } responseId) { throw CodecException.MissingField("responseId"); }
                body.AppendU32(responseId);
            }
        }
        if (isResponse)
        {
            if (Success is not { } success) { throw CodecException.MissingField("success"); }
            body.Add(success ? (byte)1 : (byte)0);
        }
        body.Add((byte)payload.Length);
        body.AddRange(payload);

        var crc = CombustionCodec.Crc16Ccitt(System.Runtime.InteropServices.CollectionsMarshal.AsSpan(body));
        var output = new List<byte>(body.Count + 4) { 0xCA, 0xFE };
        output.AppendU16(crc);
        output.AddRange(body);
        return output.ToArray();
    }

    public bool Equals(UartFrame other) =>
        Variant == other.Variant && Direction == other.Direction && MessageType == other.MessageType
        && RequestId == other.RequestId && ResponseId == other.ResponseId && Success == other.Success
        && Payload.AsSpan().SequenceEqual(other.Payload);

    public override int GetHashCode()
    {
        var h = new HashCode();
        h.Add(Variant);
        h.Add(Direction);
        h.Add(MessageType);
        h.Add(RequestId);
        h.Add(ResponseId);
        h.Add(Success);
        foreach (var b in Payload)
        {
            h.Add(b);
        }
        return h.ToHashCode();
    }

    public override string ToString() =>
        $"UartFrame({Variant} {Direction} type=0x{MessageType:X2} req={RequestId} resp={ResponseId} ok={Success} payload={Convert.ToHexString(Payload)})";
}
