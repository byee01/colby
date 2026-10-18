using System.Text;

namespace Combustion.Codec;

/// <summary>MeatNet product types (MeatNet spec "Product Type").</summary>
public enum NodeProductType : byte
{
    Repeater = 2,
    Gauge = 3,
    Display = 4,
    Booster = 5,
    Engine = 6,
}

/// <summary>Probe data carried in an advertisement, from a probe directly or repeated by a node.</summary>
/// <param name="Overheating">Null when the overheating byte is absent from the packet.</param>
/// <param name="Preferences">Null when the preferences byte is absent (node-repeated packets have none).</param>
public readonly record struct ProbeAdvertisement(
    ProbeSerial Serial,
    ProbeTemperatures Temperatures,
    ProbeMode Mode,
    ProbeColor Color,
    int ProbeNumber,
    bool BatteryLow,
    VirtualSensors VirtualSensors,
    SensorSet? Overheating = null,
    ThermometerPreferences? Preferences = null);

/// <summary>
/// A node's own advertisement (display, booster, gauge, engine): serial and, for display and
/// booster, the preferences byte. Gauge and engine sensor data is out of v1 scope.
/// </summary>
/// <param name="Serial">Up to 10 characters, trailing NULs removed.</param>
public readonly record struct NodeAdvertisement(NodeProductType ProductType, string Serial, byte? Preferences = null);

public abstract record AdvertisementPacket
{
    private AdvertisementPacket() { }

    public sealed record Probe(ProbeAdvertisement Advertisement) : AdvertisementPacket;

    /// <summary>A probe's data repeated by a node. <c>HopCount</c> is 1...4.</summary>
    public sealed record Repeated(ProbeAdvertisement Advertisement, int HopCount) : AdvertisementPacket;

    public sealed record Node(NodeAdvertisement Advertisement) : AdvertisementPacket;

    public sealed record Unknown(byte ProductType) : AdvertisementPacket;
}

// Manufacturer specific data, including the 2-byte vendor ID (probe spec "Manufacturer Specific Data"):
// 0-1 vendor 0x09C7 little-endian, 2 product type, 3-6 serial, 7-19 raw temperatures, 20 mode/ID,
// 21 battery + virtual sensors, 22 network information, 23 overheating, 24 preferences (probe only).
internal static class Ad
{
    public static readonly byte[] Vendor = [0xC7, 0x09];
    public const int ProductType = 2;
    public const int ProbeSerial = 3;
    public const int Temperatures = 7;
    public const int ModeAndId = 20;
    public const int Battery = 21;
    public const int Network = 22;
    public const int Overheat = 23;
    public const int Preferences = 24;
    public const int NodeSerial = 3;
    public const int NodeSerialLength = 10;
    public const int NodePreferences = 13;
    public const int PacketSize = 25;
}

public static partial class CombustionCodec
{
    private static ProbeAdvertisement ProbeAdvertisementFrom(ReadOnlySpan<byte> b)
    {
        var ident = ModeAndId.FromByte(b[Ad.ModeAndId]);
        return new ProbeAdvertisement(
            new ProbeSerial(Le.U32(b, Ad.ProbeSerial)),
            ProbeTemperatures.FromPacked(b[Ad.Temperatures..Ad.ModeAndId]),
            ident.Mode,
            ident.Color,
            ident.ProbeNumber,
            (b[Ad.Battery] & 1) != 0,
            VirtualSensors.FromBits((uint)(b[Ad.Battery] >> 1)),
            b.Length > Ad.Overheat ? OverheatMask.Decode(b[Ad.Overheat]) : null,
            b.Length > Ad.Preferences ? ThermometerPreferences.FromByte(b[Ad.Preferences]) : null);
    }

    /// <summary>
    /// Decodes manufacturer data as delivered by CoreBluetooth or WinRT (vendor ID first).
    /// Throws <see cref="CodecError.BadSync"/> for a different vendor ID.
    /// </summary>
    public static AdvertisementPacket DecodeAdvertisement(ReadOnlySpan<byte> mfrData)
    {
        if (mfrData.Length <= Ad.ProductType)
        {
            throw CodecException.TooShort(Ad.ProductType + 1, mfrData.Length);
        }
        if (!mfrData[..2].SequenceEqual(Ad.Vendor))
        {
            throw CodecException.BadSync();
        }

        var type = mfrData[Ad.ProductType];
        switch (type)
        {
            case 1:
            case 2:
            {
                var needed = type == 1 ? Ad.Network : Ad.Network + 1;
                if (mfrData.Length < needed)
                {
                    throw CodecException.TooShort(needed, mfrData.Length);
                }
                var probe = ProbeAdvertisementFrom(mfrData);
                return type == 1
                    ? new AdvertisementPacket.Probe(probe)
                    : new AdvertisementPacket.Repeated(probe, HopCount(mfrData[Ad.Network]));
            }
            case >= 3 and <= 6:
            {
                const int end = Ad.NodeSerial + Ad.NodeSerialLength;
                if (mfrData.Length < end)
                {
                    throw CodecException.TooShort(end, mfrData.Length);
                }
                var productType = (NodeProductType)type;
                var hasPreferences = productType is NodeProductType.Display or NodeProductType.Booster;
                var serialBytes = mfrData[Ad.NodeSerial..end];
                var nul = serialBytes.IndexOf((byte)0);
                if (nul >= 0)
                {
                    serialBytes = serialBytes[..nul];
                }
                return new AdvertisementPacket.Node(new NodeAdvertisement(
                    productType,
                    Encoding.UTF8.GetString(serialBytes),
                    hasPreferences && mfrData.Length > Ad.NodePreferences ? mfrData[Ad.NodePreferences] : null));
            }
            default:
                return new AdvertisementPacket.Unknown(type);
        }
    }

    /// <summary>
    /// Builds manufacturer data (vendor ID first): 25 B for a probe, 24 B for a repeated probe unless it
    /// carries preferences, 25 B for node packets.
    /// </summary>
    public static byte[] EncodeAdvertisement(AdvertisementPacket packet)
    {
        switch (packet)
        {
            case AdvertisementPacket.Probe p:
                return EncodeProbeAdvertisement(p.Advertisement, 1, 0);
            case AdvertisementPacket.Repeated r:
                return EncodeProbeAdvertisement(r.Advertisement, 2, NetworkInformation(r.HopCount));
            case AdvertisementPacket.Node n:
            {
                var serial = Encoding.UTF8.GetBytes(n.Advertisement.Serial);
                if (serial.Length > Ad.NodeSerialLength)
                {
                    throw CodecException.OutOfRange("node.serial", serial.Length);
                }
                var output = new byte[Ad.PacketSize];
                Ad.Vendor.CopyTo(output, 0);
                output[Ad.ProductType] = (byte)n.Advertisement.ProductType;
                serial.CopyTo(output, Ad.NodeSerial);
                if (n.Advertisement.Preferences is { } preferences)
                {
                    output[Ad.NodePreferences] = preferences;
                }
                return output;
            }
            case AdvertisementPacket.Unknown u:
                return [Ad.Vendor[0], Ad.Vendor[1], u.ProductType];
            default:
                throw new ArgumentException("Unsupported packet", nameof(packet));
        }
    }

    private static byte[] EncodeProbeAdvertisement(ProbeAdvertisement p, byte productType, byte network)
    {
        var output = new List<byte>(Ad.PacketSize) { Ad.Vendor[0], Ad.Vendor[1], productType };
        output.AppendU32(p.Serial.Raw);
        output.AddRange(p.Temperatures.Packed());
        output.Add(new ModeAndId(p.Mode, p.Color, p.ProbeNumber).ToByte());
        output.Add((byte)((p.BatteryLow ? 1 : 0) | (byte)(p.VirtualSensors.Bits << 1)));
        output.Add(network);
        if (p.Overheating is not null || p.Preferences is not null)
        {
            output.Add(OverheatMask.Encode(p.Overheating ?? SensorSet.Empty));
        }
        if (p.Preferences is { } preferences)
        {
            output.Add(preferences.ToByte());
        }
        return output.ToArray();
    }
}
