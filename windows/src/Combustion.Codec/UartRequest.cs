namespace Combustion.Codec;

/// <summary>Message types used in v1 (probe spec "Messages", MeatNet spec "Messages").</summary>
public static class UartMessageType
{
    public const byte ReadSessionInfo = 0x03;
    public const byte ReadLogs = 0x04;
    public const byte SetPrediction = 0x05;
    public const byte SetAlarms = 0x0B;
    public const byte SilenceAlarms = 0x0C;
    public const byte ProbeStatus = 0x45;
    public const byte ProbeFirmware = 0x46;
    public const byte ProbeHardware = 0x47;
    public const byte ProbeModel = 0x48;
    /// <summary>Node heartbeat (network topology); payload not decoded.</summary>
    public const byte Heartbeat = 0x49;
}

/// <summary>A command to a probe. Over a node every request also names the probe (<c>EncodeRequest(probe:)</c>).</summary>
public abstract record UartRequest
{
    private UartRequest() { }

    public abstract byte MessageType { get; }

    public sealed record ReadSessionInfo : UartRequest
    {
        public override byte MessageType => UartMessageType.ReadSessionInfo;
    }

    public sealed record ReadLogs(uint Start, uint End) : UartRequest
    {
        public override byte MessageType => UartMessageType.ReadLogs;
    }

    public sealed record SetPrediction(double Setpoint, PredictionMode Mode) : UartRequest
    {
        public override byte MessageType => UartMessageType.SetPrediction;
    }

    public sealed record SetAlarms(AlarmConfig Config) : UartRequest
    {
        public override byte MessageType => UartMessageType.SetAlarms;
    }

    public sealed record SilenceAlarms : UartRequest
    {
        public override byte MessageType => UartMessageType.SilenceAlarms;
    }

    /// <summary>Node only: the probe's firmware string, relayed from its Device Information service.</summary>
    public sealed record ReadProbeFirmware : UartRequest
    {
        public override byte MessageType => UartMessageType.ProbeFirmware;
    }

    /// <summary>Node only: the probe's hardware string.</summary>
    public sealed record ReadProbeHardware : UartRequest
    {
        public override byte MessageType => UartMessageType.ProbeHardware;
    }

    /// <summary>Node only: the probe's model string.</summary>
    public sealed record ReadProbeModel : UartRequest
    {
        public override byte MessageType => UartMessageType.ProbeModel;
    }
}

/// <summary>A request read back from a frame (used by simulators and round-trip tests).</summary>
public readonly record struct UartRequestMessage(ProbeSerial? Probe, UartRequest Request, uint? RequestId);

public static partial class CombustionCodec
{
    /// <summary>Node Silence Alarms payload (MeatNet spec): global u8, product type u8, probe serial u32, node serial 10 B.</summary>
    private const int SilenceAlarmsNodePayloadSize = 16;

    private const byte ProbeProductType = 1;

    private static byte[] RequestPayload(UartRequest request)
    {
        var output = new List<byte>();
        switch (request)
        {
            case UartRequest.ReadLogs r:
                output.AppendU32(r.Start);
                output.AppendU32(r.End);
                break;
            case UartRequest.SetPrediction p:
                output.AppendU16(EncodeSetPredictionData(p.Setpoint, p.Mode));
                break;
            case UartRequest.SetAlarms a:
                output.AddRange(a.Config.Packed());
                break;
        }
        return output.ToArray();
    }

    /// <summary>
    /// Builds the bytes to write to the UART RX characteristic.
    /// <list type="bullet">
    /// <item>probe variant: <paramref name="probe"/> and <paramref name="requestId"/> are ignored; the node-only reads throw <c>UnknownMessageType</c>.</item>
    /// <item>node variant: <paramref name="probe"/> and <paramref name="requestId"/> are required, and the probe serial leads the payload.</item>
    /// </list>
    /// </summary>
    public static byte[] EncodeRequest(UartVariant variant, UartRequest request, ProbeSerial? probe = null, uint? requestId = null)
    {
        var payload = RequestPayload(request);
        if (variant == UartVariant.Probe)
        {
            if (request is UartRequest.ReadProbeFirmware or UartRequest.ReadProbeHardware or UartRequest.ReadProbeModel)
            {
                throw CodecException.UnknownMessageType(request.MessageType);
            }
        }
        else
        {
            if (probe is not { } serial) { throw CodecException.MissingField("probe"); }
            var head = new List<byte>();
            if (request is UartRequest.SilenceAlarms)
            {
                head.Add(0);
                head.Add(ProbeProductType);
                head.AppendU32(serial.Raw);
                head.AddRange(new byte[10]);
            }
            else
            {
                head.AppendU32(serial.Raw);
                head.AddRange(payload);
            }
            payload = head.ToArray();
        }
        return new UartFrame(
            variant, UartDirection.Request, request.MessageType,
            requestId: variant == UartVariant.Node ? requestId : null, payload: payload).Encoded();
    }

    internal static void RequirePayload(UartFrame frame, int atLeast)
    {
        if (frame.Payload.Length < atLeast)
        {
            throw CodecException.TooShort(atLeast, frame.Payload.Length);
        }
    }

    /// <summary>Reads a request back from a frame, the inverse of <see cref="EncodeRequest"/>.</summary>
    public static UartRequestMessage DecodeRequest(UartFrame frame)
    {
        if (frame.Direction != UartDirection.Request)
        {
            throw CodecException.UnknownMessageType(frame.MessageType);
        }
        var isNode = frame.Variant == UartVariant.Node;
        var lead = isNode ? 4 : 0;
        var p = frame.Payload;

        UartRequest request;
        switch (frame.MessageType)
        {
            case UartMessageType.ReadSessionInfo:
                RequirePayload(frame, lead);
                request = new UartRequest.ReadSessionInfo();
                break;
            case UartMessageType.ReadLogs:
                RequirePayload(frame, lead + 8);
                request = new UartRequest.ReadLogs(Le.U32(p, lead), Le.U32(p, lead + 4));
                break;
            case UartMessageType.SetPrediction:
            {
                RequirePayload(frame, lead + 2);
                var (setpoint, mode) = DecodeSetPredictionData(Le.U16(p, lead));
                request = new UartRequest.SetPrediction(setpoint, mode);
                break;
            }
            case UartMessageType.SetAlarms:
                RequirePayload(frame, lead + AlarmConfig.PackedSize);
                request = new UartRequest.SetAlarms(AlarmConfig.FromPacked(p.AsSpan(lead, AlarmConfig.PackedSize)));
                break;
            case UartMessageType.SilenceAlarms:
                RequirePayload(frame, isNode ? SilenceAlarmsNodePayloadSize : 0);
                request = new UartRequest.SilenceAlarms();
                break;
            case UartMessageType.ProbeFirmware when isNode:
                RequirePayload(frame, lead);
                request = new UartRequest.ReadProbeFirmware();
                break;
            case UartMessageType.ProbeHardware when isNode:
                RequirePayload(frame, lead);
                request = new UartRequest.ReadProbeHardware();
                break;
            case UartMessageType.ProbeModel when isNode:
                RequirePayload(frame, lead);
                request = new UartRequest.ReadProbeModel();
                break;
            default:
                throw CodecException.UnknownMessageType(frame.MessageType);
        }

        ProbeSerial? probe = null;
        if (isNode)
        {
            if (frame.MessageType == UartMessageType.SilenceAlarms)
            {
                // Global silence (flag 1) names no probe.
                probe = p[0] == 0 ? new ProbeSerial(Le.U32(p, 2)) : null;
            }
            else
            {
                probe = new ProbeSerial(Le.U32(p, 0));
            }
        }
        return new UartRequestMessage(probe, request, frame.RequestId);
    }
}
