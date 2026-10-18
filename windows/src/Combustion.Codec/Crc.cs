namespace Combustion.Codec;

public static partial class CombustionCodec
{
    /// <summary>
    /// CRC-16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no final xor).
    /// Probe spec "Request Header"; MeatNet spec "Request Header" / "Response Header".
    /// </summary>
    public static ushort Crc16Ccitt(ReadOnlySpan<byte> bytes)
    {
        ushort crc = 0xFFFF;
        foreach (var b in bytes)
        {
            crc ^= (ushort)(b << 8);
            for (var i = 0; i < 8; i++)
            {
                crc = (crc & 0x8000) != 0 ? (ushort)((crc << 1) ^ 0x1021) : (ushort)(crc << 1);
            }
        }
        return crc;
    }
}
