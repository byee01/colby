namespace Combustion.Core;

/// <summary>Opaque platform peripheral identifier (BLE address as hex on Windows, CBPeripheral UUID on macOS).</summary>
public readonly record struct PeripheralId(string Raw)
{
    public override string ToString() => Raw;

    public static implicit operator PeripheralId(string raw) => new(raw);
}

public enum BluetoothState { PoweredOn, PoweredOff, Unauthorized, Unsupported }

/// <param name="MfrData">Manufacturer-specific data including the 2-byte company ID (0x09C7, little-endian).</param>
public sealed record RawAdvertisement(PeripheralId Peripheral, byte[] MfrData, int Rssi, DateTimeOffset Time)
{
    public bool Equals(RawAdvertisement? other) =>
        other is not null && Peripheral == other.Peripheral && MfrData.AsSpan().SequenceEqual(other.MfrData) &&
        Rssi == other.Rssi && Time == other.Time;

    public override int GetHashCode() => HashCode.Combine(Peripheral, MfrData.Length, Rssi, Time);
}

/// <summary>Normalized (uppercase) GATT UUID string. Constants from docs/01 §2.</summary>
public readonly record struct GattUuid
{
    public GattUuid(string raw)
    {
        Raw = raw.ToUpperInvariant();
    }

    public string Raw { get; }

    public override string ToString() => Raw;

    public static implicit operator GattUuid(string raw) => new(raw);

    /// <summary>Full 128-bit form; 16-bit short UUIDs expand on the Bluetooth base UUID.</summary>
    public Guid ToGuid() => Raw.Length == 4
        ? Guid.Parse($"0000{Raw}-0000-1000-8000-00805F9B34FB")
        : Guid.Parse(Raw);

    /// <summary>Inverse of <see cref="ToGuid"/>: base-UUID values shorten to 4 hex digits, as CoreBluetooth reports them.</summary>
    public static GattUuid FromGuid(Guid guid)
    {
        var s = guid.ToString("D").ToUpperInvariant();
        return s.StartsWith("0000", StringComparison.Ordinal) && s.EndsWith("-0000-1000-8000-00805F9B34FB", StringComparison.Ordinal)
            ? new GattUuid(s.Substring(4, 4))
            : new GattUuid(s);
    }

    public static readonly GattUuid ProbeStatusService = "00000100-CAAB-3792-3D44-97AE51C1407A";
    public static readonly GattUuid ProbeStatus = "00000101-CAAB-3792-3D44-97AE51C1407A";

    public static readonly GattUuid UartService = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E";
    /// <summary>App writes requests here.</summary>
    public static readonly GattUuid UartRx = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E";
    /// <summary>Responses and node notifications arrive here.</summary>
    public static readonly GattUuid UartTx = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E";

    /// <summary>0x180A on probes; node documentation says 0x181A (unverified).</summary>
    public static readonly GattUuid DeviceInformationService = "180A";
    public static readonly GattUuid ManufacturerName = "2A29";
    public static readonly GattUuid ModelNumber = "2A24";
    public static readonly GattUuid SerialNumber = "2A25";
    public static readonly GattUuid HardwareRevision = "2A27";
    public static readonly GattUuid FirmwareRevision = "2A26";
}

public static class CombustionVendor
{
    /// <summary>Bluetooth company identifier used in manufacturer data.</summary>
    public const ushort CompanyId = 0x09C7;
}

public sealed record GattService(GattUuid Uuid, IReadOnlyList<GattUuid> Characteristics)
{
    public bool Equals(GattService? other) => other is not null && Uuid == other.Uuid && Characteristics.SequenceEqual(other.Characteristics);

    public override int GetHashCode() => HashCode.Combine(Uuid, Characteristics.Count);
}

public enum DisconnectReason { Requested, LinkLost, Timeout, BluetoothOff }

public enum TransportErrorKind { NotPoweredOn, Timeout, ConnectionRefused, AlreadyConnected, Disconnected, CharacteristicNotFound, OperationFailed }

/// <summary>Swift <c>TransportError</c>. Equality is by kind and detail, for tests.</summary>
public sealed class TransportException : Exception
{
    private TransportException(TransportErrorKind kind, string detail)
        : base(detail.Length == 0 ? kind.ToString() : $"{kind}: {detail}")
    {
        Kind = kind;
        Detail = detail;
    }

    public TransportErrorKind Kind { get; }

    public string Detail { get; }

    public static TransportException NotPoweredOn(BluetoothState s) => new(TransportErrorKind.NotPoweredOn, s.ToString());
    public static TransportException Timeout() => new(TransportErrorKind.Timeout, "");
    public static TransportException ConnectionRefused(PeripheralId id) => new(TransportErrorKind.ConnectionRefused, id.Raw);
    public static TransportException AlreadyConnected(PeripheralId id) => new(TransportErrorKind.AlreadyConnected, id.Raw);
    public static TransportException Disconnected() => new(TransportErrorKind.Disconnected, "");
    public static TransportException CharacteristicNotFound(GattUuid c) => new(TransportErrorKind.CharacteristicNotFound, c.Raw);
    public static TransportException OperationFailed(string message) => new(TransportErrorKind.OperationFailed, message);

    public bool Is(TransportErrorKind kind, string? detail = null) => Kind == kind && (detail is null || Detail == detail);
}

/// <summary>
/// Platform boundary (docs/02 §5.1). Only implementations of this touch OS Bluetooth APIs.
/// Stream methods return a new stream per call.
/// </summary>
public interface IBleTransport
{
    /// <summary>Current state first, then changes.</summary>
    AsyncStream<BluetoothState> State();

    AsyncStream<RawAdvertisement> Advertisements();

    Task StartScanAsync();

    Task StopScanAsync();

    Task<IGattConnection> ConnectAsync(PeripheralId id, TimeSpan timeout, CancellationToken ct = default);
}

public interface IGattConnection
{
    PeripheralId Peripheral { get; }

    int Mtu { get; }

    /// <summary>Yields at most one reason, then finishes. New stream per call.</summary>
    AsyncStream<DisconnectReason> Disconnected();

    Task<IReadOnlyList<GattService>> DiscoverAsync(CancellationToken ct = default);

    Task<byte[]> ReadAsync(GattUuid characteristic, CancellationToken ct = default);

    Task WriteAsync(GattUuid characteristic, byte[] bytes, bool withResponse, CancellationToken ct = default);

    /// <summary>Enables notifications. The stream finishes on disconnect.</summary>
    Task<AsyncStream<byte[]>> SubscribeAsync(GattUuid characteristic, CancellationToken ct = default);

    Task CloseAsync();
}
