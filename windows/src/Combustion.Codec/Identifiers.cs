using System.Collections;
using System.Globalization;

namespace Combustion.Codec;

/// <summary>Probe serial number: u32 on the wire, shown as 8 uppercase hex characters.</summary>
public readonly record struct ProbeSerial(uint Raw) : IComparable<ProbeSerial>
{
    /// <summary>Parses 1 to 8 hex digits, either case; null when invalid.</summary>
    public static ProbeSerial? FromHex(string? hex)
    {
        if (hex is null || hex.Length is < 1 or > 8 || !hex.All(Uri.IsHexDigit))
        {
            return null;
        }
        return new ProbeSerial(uint.Parse(hex, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture));
    }

    public string Hex => Raw.ToString("X8", CultureInfo.InvariantCulture);

    public override string ToString() => Hex;

    public int CompareTo(ProbeSerial other) => Raw.CompareTo(other.Raw);

    public static bool operator <(ProbeSerial a, ProbeSerial b) => a.Raw < b.Raw;
    public static bool operator >(ProbeSerial a, ProbeSerial b) => a.Raw > b.Raw;
    public static bool operator <=(ProbeSerial a, ProbeSerial b) => a.Raw <= b.Raw;
    public static bool operator >=(ProbeSerial a, ProbeSerial b) => a.Raw >= b.Raw;
}

/// <summary>Thermistor T1 (tip) to T8 (handle end). The value is the zero-based position.</summary>
public enum SensorIndex : byte
{
    T1, T2, T3, T4, T5, T6, T7, T8,
}

/// <summary>A set of sensors (Swift <c>Set&lt;SensorIndex&gt;</c>), stored as the wire bitmask; enumerates in T1...T8 order.</summary>
public readonly record struct SensorSet : IEnumerable<SensorIndex>
{
    public SensorSet(byte mask)
    {
        Mask = mask;
    }

    public SensorSet(IEnumerable<SensorIndex> sensors)
    {
        byte mask = 0;
        foreach (var s in sensors)
        {
            mask |= (byte)(1 << (int)s);
        }
        Mask = mask;
    }

    public static SensorSet Of(params SensorIndex[] sensors) => new(sensors);

    public static SensorSet Empty => default;

    /// <summary>Bit n is sensor T(n+1).</summary>
    public byte Mask { get; }

    public bool Contains(SensorIndex sensor) => (Mask & (1 << (int)sensor)) != 0;

    public int Count => System.Numerics.BitOperations.PopCount(Mask);

    public IEnumerator<SensorIndex> GetEnumerator()
    {
        for (var i = 0; i < 8; i++)
        {
            if ((Mask & (1 << i)) != 0)
            {
                yield return (SensorIndex)i;
            }
        }
    }

    IEnumerator IEnumerable.GetEnumerator() => GetEnumerator();

    public override string ToString() => "{" + string.Join(", ", this) + "}";
}

/// <summary>Mode/ID byte, bits 1-2 (probe spec "Mode and ID Data").</summary>
public enum ProbeMode : byte
{
    Normal = 0,
    InstantRead = 1,
    Reserved = 2,
    Error = 3,
}

/// <summary>Mode/ID byte, bits 3-5. Only 0 (yellow) and 1 (grey) are defined; the rest keep their raw value.</summary>
public readonly record struct ProbeColor(byte Raw)
{
    public static ProbeColor Yellow => new(0);
    public static ProbeColor Grey => new(1);

    public static ProbeColor Unknown(byte n) => new(n);

    public override string ToString() => Raw switch
    {
        0 => "Yellow",
        1 => "Grey",
        _ => $"Unknown({Raw})",
    };
}

/// <summary>Power mode, thermometer preferences bits 1-2. 0 normal, 1 always on, anything else is reserved.</summary>
public readonly record struct ProbePowerMode(byte Raw)
{
    public static ProbePowerMode Normal => new(0);
    public static ProbePowerMode AlwaysOn => new(1);

    public static ProbePowerMode Reserved(byte n) => new(n);

    public override string ToString() => Raw switch
    {
        0 => "Normal",
        1 => "AlwaysOn",
        _ => $"Reserved({Raw})",
    };
}

/// <summary>Thermometer preferences byte (probe spec "Thermometer Preferences").</summary>
/// <param name="PowerMode">Bits 1-2.</param>
/// <param name="HighRadioPower">Bit 3: transmits at +8 dBm instead of +0 dBm.</param>
public readonly record struct ThermometerPreferences(ProbePowerMode PowerMode, bool HighRadioPower)
{
    internal static ThermometerPreferences FromByte(byte b) => new(new ProbePowerMode((byte)(b & 0b11)), (b & 0b100) != 0);

    internal byte ToByte() => (byte)((PowerMode.Raw & 0b11) | (HighRadioPower ? 0b100 : 0));
}

/// <summary>Mode/ID byte: mode (bits 1-2), color (3-5), probe identifier (6-8, stored 0-7, shown 1-8).</summary>
internal readonly record struct ModeAndId(ProbeMode Mode, ProbeColor Color, int ProbeNumber)
{
    public static ModeAndId FromByte(byte b) =>
        new((ProbeMode)(b & 0b11), new ProbeColor((byte)((b >> 2) & 0b111)), (b >> 5) + 1);

    public byte ToByte()
    {
        if (ProbeNumber is < 1 or > 8)
        {
            throw CodecException.OutOfRange("probeNumber", ProbeNumber);
        }
        if (Color.Raw > 7)
        {
            throw CodecException.OutOfRange("color", Color.Raw);
        }
        return (byte)((byte)Mode | (Color.Raw << 2) | ((ProbeNumber - 1) << 5));
    }
}

/// <summary>Overheating sensors byte. Bit n (zero-based from the LSB) is sensor T(n+1).</summary>
internal static class OverheatMask
{
    public static SensorSet Decode(byte b) => new(b);

    public static byte Encode(SensorSet sensors) => sensors.Mask;
}
