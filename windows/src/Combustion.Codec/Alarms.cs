namespace Combustion.Codec;

/// <summary>The 11 alarm channels, in wire order (probe spec "Probe Status": T1...T8, Core, Surface, Ambient).</summary>
public enum AlarmChannel
{
    T1, T2, T3, T4, T5, T6, T7, T8, Core, Surface, Ambient,
}

/// <summary>
/// One alarm, a u16 (probe spec "Alarm Status"): bit 1 set, bit 2 tripped, bit 3 alarming,
/// bits 4-16 temperature as <c>raw × 0.1 − 20</c> (−20...799 °C).
/// </summary>
/// <param name="IsSet"></param>
/// <param name="Temperature"></param>
/// <param name="Tripped">Read-only; ignored by the probe on write.</param>
/// <param name="Alarming">Read-only; false after silence.</param>
public readonly record struct Alarm(bool IsSet, double Temperature, bool Tripped = false, bool Alarming = false)
{
    public const double MinTemperature = -20;
    public const double MaxTemperature = 799;

    /// <summary>An alarm that is off, as the probe reports it.</summary>
    public static Alarm Unset => new(false, -20);

    internal static Alarm FromWord(ushort word) =>
        new((word & 1) != 0, (word >> 3) / 10.0 - 20, (word & 2) != 0, (word & 4) != 0);

    internal ushort ToWord(string field)
    {
        if (!(Temperature >= MinTemperature && Temperature <= MaxTemperature))
        {
            throw CodecException.OutOfRange(field, Temperature);
        }
        var raw = Scaling.ScaledRaw(Temperature, field, 10, 0x1FFF, offset: 20);
        return (ushort)((raw << 3) | (IsSet ? 1u : 0u) | (Tripped ? 2u : 0u) | (Alarming ? 4u : 0u));
    }
}

/// <summary>
/// High and low alarms for every channel. Decoding always fills all 11 channels of each;
/// when encoding, a missing channel is sent as <see cref="Alarm.Unset"/>.
/// </summary>
public readonly struct AlarmConfig : IEquatable<AlarmConfig>
{
    public const int PackedSize = 44;

    private static readonly IReadOnlyDictionary<AlarmChannel, Alarm> EmptyMap = new Dictionary<AlarmChannel, Alarm>();

    private readonly IReadOnlyDictionary<AlarmChannel, Alarm>? _high;
    private readonly IReadOnlyDictionary<AlarmChannel, Alarm>? _low;

    public AlarmConfig(IReadOnlyDictionary<AlarmChannel, Alarm>? high = null, IReadOnlyDictionary<AlarmChannel, Alarm>? low = null)
    {
        _high = high;
        _low = low;
    }

    public IReadOnlyDictionary<AlarmChannel, Alarm> High => _high ?? EmptyMap;

    public IReadOnlyDictionary<AlarmChannel, Alarm> Low => _low ?? EmptyMap;

    private static readonly AlarmChannel[] AllChannels = Enum.GetValues<AlarmChannel>();

    /// <summary>Unpacks 44 bytes: 11 high words then 11 low words. The caller has checked the length.</summary>
    internal static AlarmConfig FromPacked(ReadOnlySpan<byte> bytes)
    {
        var high = new Dictionary<AlarmChannel, Alarm>();
        var low = new Dictionary<AlarmChannel, Alarm>();
        foreach (var channel in AllChannels)
        {
            high[channel] = Alarm.FromWord(Le.U16(bytes, (int)channel * 2));
            low[channel] = Alarm.FromWord(Le.U16(bytes, 22 + (int)channel * 2));
        }
        return new AlarmConfig(high, low);
    }

    /// <summary>22 bytes of high alarms then 22 bytes of low alarms; throws <see cref="CodecError.OutOfRange"/> for temperatures outside −20...799 °C.</summary>
    public byte[] Packed()
    {
        var output = new List<byte>(PackedSize);
        foreach (var (kind, alarms) in new[] { ("high", High), ("low", Low) })
        {
            foreach (var channel in AllChannels)
            {
                var alarm = alarms.TryGetValue(channel, out var a) ? a : Alarm.Unset;
                output.AppendU16(alarm.ToWord($"alarm.{kind}.{ChannelName(channel)}"));
            }
        }
        return output.ToArray();
    }

    /// <summary>Lower-camel channel name (<c>t1</c>, <c>core</c>), as in Swift's string interpolation and the fixtures.</summary>
    internal static string ChannelName(AlarmChannel channel) => char.ToLowerInvariant(channel.ToString()[0]) + channel.ToString()[1..];

    public bool Equals(AlarmConfig other) => SameMap(High, other.High) && SameMap(Low, other.Low);

    public override bool Equals(object? obj) => obj is AlarmConfig other && Equals(other);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var channel in AllChannels)
        {
            if (High.TryGetValue(channel, out var hi)) { h.Add(channel); h.Add(hi); }
            if (Low.TryGetValue(channel, out var lo)) { h.Add(-1 - (int)channel); h.Add(lo); }
        }
        return h.ToHashCode();
    }

    public static bool operator ==(AlarmConfig a, AlarmConfig b) => a.Equals(b);
    public static bool operator !=(AlarmConfig a, AlarmConfig b) => !a.Equals(b);

    private static bool SameMap(IReadOnlyDictionary<AlarmChannel, Alarm> a, IReadOnlyDictionary<AlarmChannel, Alarm> b)
    {
        if (a.Count != b.Count)
        {
            return false;
        }
        foreach (var (key, value) in a)
        {
            if (!b.TryGetValue(key, out var other) || !value.Equals(other))
            {
                return false;
            }
        }
        return true;
    }

    public override string ToString() => $"AlarmConfig(high: {High.Count}, low: {Low.Count})";
}
