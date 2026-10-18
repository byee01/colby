namespace Combustion.Codec;

/// <summary>
/// Eight 13-bit raw thermistor readings (13 bytes on the wire, probe spec "Raw Temperature Data").
/// <c>°C = raw × 0.05 − 20</c>. Stores raw counts so encode and decode are exact.
/// In Instant Read mode only T1 is meaningful (the instant read temperature); the rest are 0 (−20 °C).
/// </summary>
public sealed class ProbeTemperatures : IEquatable<ProbeTemperatures>
{
    public const int SensorCount = 8;
    public const int PackedSize = 13;
    public const ushort MaxRaw = 0x1FFF;

    private readonly ushort[] _raw;

    private ProbeTemperatures(ushort[] raw)
    {
        _raw = raw;
    }

    /// <summary>Raw counts, one per sensor.</summary>
    public IReadOnlyList<ushort> Raw => _raw;

    public static ProbeTemperatures FromRaw(IEnumerable<ushort> raw)
    {
        var values = raw.ToArray();
        if (values.Length != SensorCount)
        {
            throw CodecException.OutOfRange("temperatures.count", values.Length);
        }
        foreach (var v in values)
        {
            if (v > MaxRaw)
            {
                throw CodecException.OutOfRange("temperatures.raw", v);
            }
        }
        return new ProbeTemperatures(values);
    }

    /// <summary>Rounds each value to the nearest 0.05 °C step.</summary>
    public static ProbeTemperatures FromCelsius(IEnumerable<double> celsius) =>
        FromRaw(celsius.Select(c => (ushort)Scaling.ScaledRaw(c, "temperature", 20, MaxRaw, offset: 20)).ToArray());

    /// <summary>Unpacks 13 bytes; the caller has checked the length.</summary>
    internal static ProbeTemperatures FromPacked(ReadOnlySpan<byte> bytes)
    {
        var reader = new BitReader(bytes);
        var raw = new ushort[SensorCount];
        for (var i = 0; i < SensorCount; i++)
        {
            raw[i] = (ushort)reader.Read(13);
        }
        return new ProbeTemperatures(raw);
    }

    public IReadOnlyList<double> Celsius => _raw.Select(CelsiusFromRaw).ToArray();

    public double this[SensorIndex sensor] => CelsiusFromRaw(_raw[(int)sensor]);

    public static double CelsiusFromRaw(ushort raw) => raw / 20.0 - 20;

    public byte[] Packed()
    {
        var writer = new BitWriter(PackedSize);
        foreach (var value in _raw)
        {
            writer.Write(value, 13);
        }
        return writer.Bytes;
    }

    public bool Equals(ProbeTemperatures? other) => other is not null && _raw.AsSpan().SequenceEqual(other._raw);

    public override bool Equals(object? obj) => Equals(obj as ProbeTemperatures);

    public override int GetHashCode()
    {
        var h = new HashCode();
        foreach (var v in _raw)
        {
            h.Add(v);
        }
        return h.ToHashCode();
    }

    public override string ToString() => "[" + string.Join(", ", _raw.Select(v => CelsiusFromRaw(v).ToString("0.##", System.Globalization.CultureInfo.InvariantCulture))) + "] °C";
}

/// <summary>
/// Virtual sensor selection, 7 bits (probe spec "Virtual Sensors"): core 3 bits, surface 2, ambient 2.
/// Core is T1...T6, surface T4...T7, ambient T5...T8.
/// </summary>
public readonly record struct VirtualSensors
{
    public VirtualSensors(SensorIndex core, SensorIndex surface, SensorIndex ambient)
    {
        if (core > SensorIndex.T6)
        {
            throw CodecException.OutOfRange("virtualSensors.core", (byte)core);
        }
        if (surface is < SensorIndex.T4 or > SensorIndex.T7)
        {
            throw CodecException.OutOfRange("virtualSensors.surface", (byte)surface);
        }
        if (ambient < SensorIndex.T5)
        {
            throw CodecException.OutOfRange("virtualSensors.ambient", (byte)ambient);
        }
        Core = core;
        Surface = surface;
        Ambient = ambient;
    }

    public SensorIndex Core { get; init; }
    public SensorIndex Surface { get; init; }
    public SensorIndex Ambient { get; init; }

    /// <summary>Decodes 7 bits. Core values 6 and 7 are undefined; like the Android SDK they read as T1.</summary>
    internal static VirtualSensors FromBits(uint bits)
    {
        var rawCore = (byte)(bits & 0b111);
        return new VirtualSensors(
            rawCore <= 5 ? (SensorIndex)rawCore : SensorIndex.T1,
            (SensorIndex)(((bits >> 3) & 0b11) + 3),
            (SensorIndex)(((bits >> 5) & 0b11) + 4));
    }

    internal uint Bits => (uint)Core | ((uint)(Surface - 3) << 3) | ((uint)(Ambient - 4) << 5);

    public (double Core, double Surface, double Ambient) Temperatures(ProbeTemperatures temperatures) =>
        (temperatures[Core], temperatures[Surface], temperatures[Ambient]);
}
