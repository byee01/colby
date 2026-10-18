namespace Combustion.Codec;

/// <summary>
/// Reads LSB-first packed fields. The specs number bits from 1 at the LSB of byte 0,
/// so fields are read in order from the LSB: "bits 1-4" is <c>Read(4)</c>, then "bits 5-6" is <c>Read(2)</c>.
/// </summary>
internal ref struct BitReader
{
    private readonly ReadOnlySpan<byte> _bytes;
    private int _position;

    public BitReader(ReadOnlySpan<byte> bytes)
    {
        _bytes = bytes;
        _position = 0;
    }

    /// <summary>Reads <paramref name="count"/> bits (at most 32) and advances. Callers check the length first.</summary>
    public uint Read(int count)
    {
        uint value = 0;
        for (var i = 0; i < count; i++)
        {
            var bit = (uint)((_bytes[_position >> 3] >> (_position & 7)) & 1);
            value |= bit << i;
            _position++;
        }
        return value;
    }
}

/// <summary>Writes LSB-first packed fields into a zeroed buffer of fixed size.</summary>
internal struct BitWriter
{
    private readonly byte[] _bytes;
    private int _position;

    public BitWriter(int byteCount)
    {
        _bytes = new byte[byteCount];
        _position = 0;
    }

    public readonly byte[] Bytes => _bytes;

    /// <summary>Writes the low <paramref name="count"/> bits of <paramref name="value"/> (at most 32) and advances.</summary>
    public void Write(uint value, int count)
    {
        for (var i = 0; i < count; i++)
        {
            if (((value >> i) & 1) == 1)
            {
                _bytes[_position >> 3] |= (byte)(1 << (_position & 7));
            }
            _position++;
        }
    }
}

/// <summary>Little-endian reads and appends.</summary>
internal static class Le
{
    public static ushort U16(ReadOnlySpan<byte> b, int offset) => (ushort)(b[offset] | (b[offset + 1] << 8));

    public static uint U32(ReadOnlySpan<byte> b, int offset) => U16(b, offset) | ((uint)U16(b, offset + 2) << 16);

    public static void AppendU16(this List<byte> list, ushort value)
    {
        list.Add((byte)value);
        list.Add((byte)(value >> 8));
    }

    public static void AppendU32(this List<byte> list, uint value)
    {
        list.AppendU16((ushort)value);
        list.AppendU16((ushort)(value >> 16));
    }
}

internal static class Scaling
{
    /// <summary>Rounds a scaled value half away from zero and range-checks it for a wire field.</summary>
    public static uint ScaledRaw(double value, string field, double scale, uint max, double offset = 0)
    {
        var raw = Math.Round((value + offset) * scale, MidpointRounding.AwayFromZero);
        if (!(raw >= 0 && raw <= max))
        {
            throw CodecException.OutOfRange(field, value);
        }
        return (uint)raw;
    }
}
