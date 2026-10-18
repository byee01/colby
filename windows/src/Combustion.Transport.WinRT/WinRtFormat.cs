using System.Globalization;
using Combustion.Core;

namespace Combustion.Transport.WinRT;

/// <summary>
/// Pure helpers for the WinRT transport. They use no WinRT types, so the file could be linked into a
/// platform-neutral test project; for now it is untested on Linux because this project targets a Windows TFM.
/// </summary>
public static class WinRtFormat
{
    private const ulong AddressMask = 0xFFFF_FFFF_FFFF;

    /// <summary>The 48-bit Bluetooth address as 12 uppercase hex digits, most significant byte first ("C2A1B3D4E5F6").</summary>
    public static PeripheralId FormatPeripheralId(ulong address) =>
        new((address & AddressMask).ToString("X12", CultureInfo.InvariantCulture));

    /// <summary>Inverse of <see cref="FormatPeripheralId"/>. False for anything that is not exactly 12 hex digits
    /// (for example a CoreBluetooth UUID from a macOS trace).</summary>
    public static bool TryParsePeripheralId(PeripheralId id, out ulong address)
    {
        address = 0;
        var raw = id.Raw;
        if (raw is null || raw.Length != 12)
        {
            return false;
        }
        return ulong.TryParse(raw, NumberStyles.AllowHexSpecifier, CultureInfo.InvariantCulture, out address);
    }

    /// <summary>
    /// Manufacturer data as CoreBluetooth delivers it: the company ID little-endian, then the payload.
    /// WinRT splits the company ID off into <c>BluetoothLEManufacturerData.CompanyId</c>; Core expects it in front.
    /// </summary>
    public static byte[] AssembleManufacturerData(ushort companyId, ReadOnlySpan<byte> payload)
    {
        var bytes = new byte[payload.Length + 2];
        bytes[0] = (byte)(companyId & 0xFF);
        bytes[1] = (byte)(companyId >> 8);
        payload.CopyTo(bytes.AsSpan(2));
        return bytes;
    }

    /// <summary>127 dBm means "RSSI not available" (filtered as in the CoreBluetooth transport).</summary>
    public static bool IsRssiAvailable(int rssi) => rssi != 127;
}
