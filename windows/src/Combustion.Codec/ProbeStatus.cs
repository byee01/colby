namespace Combustion.Codec;

/// <summary>
/// Which wire size to produce when encoding a status. <c>Legacy</c> omits session ID and sample period
/// (94 B probe GATT, 99 B node <c>0x45</c>); <c>Current</c> includes them (100 B / 105 B).
/// </summary>
public enum StatusLayout { Legacy, Current }

/// <summary>
/// Everything in a Probe Status notification (probe spec "Probe status"), shared by the GATT
/// characteristic and the node <c>0x45</c> message. Fields past the minimum 30 bytes are null when the
/// payload is too short to carry them.
/// </summary>
/// <param name="ProbeNumber">1...8 (wire value 0-7 plus one).</param>
/// <param name="Session">Null when the fields are absent (old firmware or old node) or the session ID is 0.</param>
public readonly record struct ProbeStatusPayload(
    LogRange LogRange,
    ProbeTemperatures Temperatures,
    ProbeMode Mode,
    ProbeColor Color,
    int ProbeNumber,
    bool BatteryLow,
    VirtualSensors VirtualSensors,
    PredictionStatus Prediction,
    FoodSafe? FoodSafe = null,
    SensorSet? Overheating = null,
    ThermometerPreferences? Preferences = null,
    AlarmConfig? Alarms = null,
    SessionInfo? Session = null);

/// <summary>A decoded node <c>0x45</c> message.</summary>
/// <param name="HopCount">1...4 repeater network hops from the probe.</param>
public readonly record struct NodeProbeStatus(ProbeSerial Serial, ProbeStatusPayload Status, int HopCount);

// Offsets within the status, excluding the node's leading serial (probe spec "Probe status",
// MeatNet spec "Probe Status (0x45)"). The node message inserts one Network Information byte after
// Food Safe Status; everything after it shifts by one.
internal static class StatusOffset
{
    public const int Temperatures = 8;
    public const int ModeAndId = 21;
    public const int BatteryAndVirtual = 22;
    public const int Prediction = 23;
    public const int FoodSafeData = 30;
    public const int FoodSafeStatus = 40;
    public const int AfterFoodSafe = 48;
    public const int Minimum = 30;

    /// <summary>Old nodes (35 B payload) send Network Information straight after the prediction status.</summary>
    public const int LegacyNodeNetwork = 30;
}

public static partial class CombustionCodec
{
    private static ProbeStatusPayload ParseStatus(ReadOnlySpan<byte> b, bool networkByte)
    {
        if (b.Length < StatusOffset.Minimum)
        {
            throw CodecException.TooShort(StatusOffset.Minimum, b.Length);
        }
        var ident = ModeAndId.FromByte(b[StatusOffset.ModeAndId]);
        var battery = b[StatusOffset.BatteryAndVirtual];
        var foodSafe = b.Length >= StatusOffset.AfterFoodSafe
            ? FoodSafe.FromPacked(b[StatusOffset.FoodSafeData..StatusOffset.FoodSafeStatus], b[StatusOffset.FoodSafeStatus..StatusOffset.AfterFoodSafe])
            : null;

        var baseOffset = StatusOffset.AfterFoodSafe + (networkByte ? 1 : 0);
        var alarmsEnd = baseOffset + 2 + AlarmConfig.PackedSize;
        return new ProbeStatusPayload(
            new LogRange(Le.U32(b, 0), Le.U32(b, 4)),
            ProbeTemperatures.FromPacked(b[StatusOffset.Temperatures..StatusOffset.ModeAndId]),
            ident.Mode,
            ident.Color,
            ident.ProbeNumber,
            (battery & 1) != 0,
            VirtualSensors.FromBits((uint)(battery >> 1)),
            PredictionStatus.FromPacked(b[StatusOffset.Prediction..StatusOffset.FoodSafeData]),
            foodSafe,
            b.Length > baseOffset ? OverheatMask.Decode(b[baseOffset]) : null,
            b.Length > baseOffset + 1 ? ThermometerPreferences.FromByte(b[baseOffset + 1]) : null,
            b.Length >= alarmsEnd ? AlarmConfig.FromPacked(b[(baseOffset + 2)..alarmsEnd]) : null,
            b.Length >= alarmsEnd + 6 ? SessionInfoAt(b, alarmsEnd) : null);
    }

    private static SessionInfo? SessionInfoAt(ReadOnlySpan<byte> b, int offset)
    {
        var id = Le.U32(b, offset);
        return id == 0 ? null : new SessionInfo(id, Le.U16(b, offset + 4));
    }

    /// <summary>
    /// Decodes the probe's Probe Status characteristic: 94 B (firmware without session fields) or 100 B.
    /// Trailing bytes beyond the known layout are ignored.
    /// </summary>
    public static ProbeStatusPayload DecodeProbeStatus(ReadOnlySpan<byte> bytes) => ParseStatus(bytes, networkByte: false);

    /// <summary>
    /// Decodes the payload of a node <c>0x45</c> Probe Status message: probe serial, status, hop count.
    /// 99 B (node without session fields) or 105 B; a 35 B payload from the oldest nodes is also accepted.
    /// </summary>
    public static NodeProbeStatus DecodeNodeProbeStatus(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length < 4 + StatusOffset.Minimum + 1)
        {
            throw CodecException.TooShort(4 + StatusOffset.Minimum + 1, bytes.Length);
        }
        var rest = bytes[4..];
        int networkOffset;
        if (rest.Length == StatusOffset.LegacyNodeNetwork + 1)
        {
            networkOffset = StatusOffset.LegacyNodeNetwork;
        }
        else
        {
            networkOffset = StatusOffset.AfterFoodSafe;
            if (rest.Length <= networkOffset)
            {
                throw CodecException.TooShort(4 + networkOffset + 1, bytes.Length);
            }
        }
        return new NodeProbeStatus(
            new ProbeSerial(Le.U32(bytes, 0)),
            ParseStatus(rest, networkByte: true),
            HopCount(rest[networkOffset]));
    }

    /// <summary>
    /// Network Information byte. The hop count (0 = 1 hop ... 3 = 4 hops) is in the top two bits:
    /// the MeatNet spec says bits 1-2 but both Combustion SDKs shift by 6. See docs/01 discrepancy notes.
    /// </summary>
    internal static int HopCount(byte networkInformation) => (networkInformation >> 6) + 1;

    internal static byte NetworkInformation(int hopCount)
    {
        if (hopCount is < 1 or > 4)
        {
            throw CodecException.OutOfRange("hopCount", hopCount);
        }
        return (byte)((hopCount - 1) << 6);
    }

    private static byte[] StatusBytes(ProbeStatusPayload s, byte? networkByte, StatusLayout layout)
    {
        if (s.FoodSafe is not { } foodSafe) { throw CodecException.MissingField("foodSafe"); }
        if (s.Overheating is not { } overheating) { throw CodecException.MissingField("overheating"); }
        if (s.Preferences is not { } preferences) { throw CodecException.MissingField("preferences"); }
        if (s.Alarms is not { } alarms) { throw CodecException.MissingField("alarms"); }
        var ident = new ModeAndId(s.Mode, s.Color, s.ProbeNumber).ToByte();

        var output = new List<byte>(105);
        output.AppendU32(s.LogRange.Min);
        output.AppendU32(s.LogRange.Max);
        output.AddRange(s.Temperatures.Packed());
        output.Add(ident);
        output.Add((byte)((s.BatteryLow ? 1 : 0) | (byte)(s.VirtualSensors.Bits << 1)));
        output.AddRange(s.Prediction.Packed());
        var food = foodSafe.Packed();
        output.AddRange(food.Data);
        output.AddRange(food.Status);
        if (networkByte is { } network)
        {
            output.Add(network);
        }
        output.Add(OverheatMask.Encode(overheating));
        output.Add(preferences.ToByte());
        output.AddRange(alarms.Packed());
        if (layout == StatusLayout.Current)
        {
            output.AppendU32(s.Session?.SessionId ?? 0);
            output.AppendU16(s.Session?.SamplePeriodMs ?? 0);
        }
        return output.ToArray();
    }

    /// <summary>Encodes a probe GATT status. Requires <c>FoodSafe</c>, <c>Overheating</c>, <c>Preferences</c> and <c>Alarms</c>. A null <c>Session</c> is written as zeros.</summary>
    public static byte[] EncodeProbeStatus(ProbeStatusPayload status, StatusLayout layout = StatusLayout.Current) =>
        StatusBytes(status, null, layout);

    /// <summary>Encodes the payload of a node <c>0x45</c> message.</summary>
    public static byte[] EncodeNodeProbeStatus(NodeProbeStatus status, StatusLayout layout = StatusLayout.Current)
    {
        var output = new List<byte>(105);
        output.AppendU32(status.Serial.Raw);
        output.AddRange(StatusBytes(status.Status, NetworkInformation(status.HopCount), layout));
        return output.ToArray();
    }
}
