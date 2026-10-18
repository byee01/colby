using System.Text;

namespace Combustion.Codec;

/// <summary>One record from Read Logs: sequence number, 8 raw temperatures, prediction log (24 B on the wire).</summary>
public readonly record struct LogRecord(uint Sequence, ProbeTemperatures Temperatures, PredictionLog Prediction)
{
    public const int PackedSize = 24;
}

/// <summary>Which Device Information string a node relays for a probe.</summary>
public enum ProbeInfoKind { Firmware, Hardware, Model }

internal static class ProbeInfoKinds
{
    /// <summary>Fixed string field size in bytes (MeatNet spec 0x46, 0x47, 0x48).</summary>
    public static int FieldSize(this ProbeInfoKind kind) => kind switch
    {
        ProbeInfoKind.Firmware => 20,
        ProbeInfoKind.Hardware => 16,
        _ => 50,
    };
}

/// <summary>Decoded response payload (Swift <c>UartResponse.Body</c>).</summary>
public abstract record ResponseBody
{
    private ResponseBody() { }

    /// <summary><c>Probe</c> is set for node responses only.</summary>
    public sealed record SessionInfoBody(ProbeSerial? Probe, SessionInfo Info) : ResponseBody;

    public sealed record LogRecordBody(ProbeSerial? Probe, LogRecord Record) : ResponseBody;

    public sealed record RevisionBody(ProbeSerial? Probe, ProbeInfoKind Kind, string Text) : ResponseBody;

    /// <summary>Acknowledgement without a decoded payload; also what every failed response (<c>Success == false</c>) becomes.</summary>
    public sealed record Ack : ResponseBody;
}

/// <param name="RequestId">Node only.</param>
/// <param name="ResponseId">Node only.</param>
public readonly record struct UartResponse(
    byte MessageType, bool Success, ResponseBody Body, uint? RequestId = null, uint? ResponseId = null);

public static partial class CombustionCodec
{
    /// <summary>Responses with no payload we read (set ID/color, food safe, power mode, reset, set prediction, alarms).</summary>
    private static readonly HashSet<byte> AckOnlyTypes = [0x01, 0x02, 0x05, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C];

    private static ProbeInfoKind? InfoKind(byte type) => type switch
    {
        UartMessageType.ProbeFirmware => ProbeInfoKind.Firmware,
        UartMessageType.ProbeHardware => ProbeInfoKind.Hardware,
        UartMessageType.ProbeModel => ProbeInfoKind.Model,
        _ => null,
    };

    /// <summary>
    /// Interprets a response-direction frame. A failed response (<c>success == 0</c>) decodes as <c>Ack</c>
    /// whatever its payload. Trailing payload bytes are ignored.
    /// </summary>
    public static UartResponse DecodeResponse(UartFrame frame)
    {
        if (frame.Direction != UartDirection.Response)
        {
            throw CodecException.UnknownMessageType(frame.MessageType);
        }
        var type = frame.MessageType;
        var isNode = frame.Variant == UartVariant.Node;
        var kind = isNode ? InfoKind(type) : null;
        var known = AckOnlyTypes.Contains(type) || type == UartMessageType.ReadSessionInfo
            || type == UartMessageType.ReadLogs || kind is not null;
        if (!known)
        {
            throw CodecException.UnknownMessageType(type);
        }

        var success = frame.Success ?? false;
        UartResponse Response(ResponseBody body) => new(type, success, body, frame.RequestId, frame.ResponseId);
        if (!success || AckOnlyTypes.Contains(type))
        {
            return Response(new ResponseBody.Ack());
        }

        var p = frame.Payload;
        var lead = isNode ? 4 : 0;
        ProbeSerial? Probe() => isNode ? new ProbeSerial(Le.U32(p, 0)) : null;
        switch (type)
        {
            case UartMessageType.ReadSessionInfo:
                RequirePayload(frame, lead + 6);
                return Response(new ResponseBody.SessionInfoBody(Probe(), new SessionInfo(Le.U32(p, lead), Le.U16(p, lead + 4))));
            case UartMessageType.ReadLogs:
            {
                RequirePayload(frame, lead + LogRecord.PackedSize);
                var record = new LogRecord(
                    Le.U32(p, lead),
                    ProbeTemperatures.FromPacked(p.AsSpan(lead + 4, 13)),
                    PredictionLog.FromPacked(p.AsSpan(lead + 17, 7)));
                return Response(new ResponseBody.LogRecordBody(Probe(), record));
            }
            default:
            {
                var infoKind = kind!.Value;
                var size = infoKind.FieldSize();
                RequirePayload(frame, lead + size);
                var text = p.AsSpan(lead, size);
                var nul = text.IndexOf((byte)0);
                if (nul >= 0)
                {
                    text = text[..nul];
                }
                return Response(new ResponseBody.RevisionBody(Probe(), infoKind, Encoding.UTF8.GetString(text)));
            }
        }
    }

    /// <summary>
    /// Builds a response frame, as a simulated probe or node would send it.
    /// Node responses need <c>RequestId</c> and <c>ResponseId</c>; their payloads lead with the probe serial.
    /// </summary>
    public static byte[] EncodeResponse(UartResponse response, UartVariant variant)
    {
        var payload = new List<byte>();
        void Lead(ProbeSerial? probe)
        {
            if (variant == UartVariant.Node)
            {
                if (probe is not { } serial) { throw CodecException.MissingField("probe"); }
                payload.AppendU32(serial.Raw);
            }
        }
        switch (response.Body)
        {
            case ResponseBody.Ack:
                break;
            case ResponseBody.SessionInfoBody s:
                Lead(s.Probe);
                payload.AppendU32(s.Info.SessionId);
                payload.AppendU16(s.Info.SamplePeriodMs);
                break;
            case ResponseBody.LogRecordBody l:
                Lead(l.Probe);
                payload.AppendU32(l.Record.Sequence);
                payload.AddRange(l.Record.Temperatures.Packed());
                payload.AddRange(l.Record.Prediction.Packed());
                break;
            case ResponseBody.RevisionBody r:
            {
                Lead(r.Probe);
                var bytes = Encoding.UTF8.GetBytes(r.Text);
                var size = r.Kind.FieldSize();
                if (bytes.Length > size)
                {
                    throw CodecException.OutOfRange("revision.text", bytes.Length);
                }
                payload.AddRange(bytes);
                payload.AddRange(new byte[size - bytes.Length]);
                break;
            }
            default:
                throw new ArgumentException("Unsupported body", nameof(response));
        }
        return new UartFrame(
            variant, UartDirection.Response, response.MessageType,
            response.RequestId, response.ResponseId, response.Success, payload.ToArray()).Encoded();
    }
}
