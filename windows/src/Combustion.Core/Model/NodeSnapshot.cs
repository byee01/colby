using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Firmware, hardware and model strings of a device, read from its Device Information service.
/// Any field is null until read (or if the device does not provide it). docs/02 §3.</summary>
public sealed record DeviceInfo(string? Firmware = null, string? Hardware = null, string? Model = null)
{
    public bool IsEmpty => Firmware is null && Hardware is null && Model is null;
}

/// <summary>
/// What the UI knows about one MeatNet node (Display, Booster, ...). docs/02 §3.
/// <c>Link</c> says how we hear the node: <c>DirectConnection</c> while a <c>NodeLink</c> is up, otherwise
/// <c>NodeAdvertisement</c> from its own advertisements (probes, hops and heartbeat are empty then).
/// </summary>
/// <param name="Probes">Probes this node relayed recently, ascending. Only known while connected.</param>
/// <param name="HopCounts">Repeater network hops (1...4) from each of <c>Probes</c> to this node.</param>
/// <param name="HeartbeatCount">Heartbeats (0x49) received on the current connection. The payload (network topology) is not decoded.</param>
public sealed record NodeSnapshot(
    string Serial,
    NodeProductType ProductType,
    LinkSource Link,
    ValueList<ProbeSerial>? Probes = null,
    ValueMap<ProbeSerial, int>? HopCounts = null,
    bool IsConnected = false,
    DeviceInfo? Firmware = null,
    int HeartbeatCount = 0,
    DateTimeOffset? LastHeartbeat = null)
{
    public ValueList<ProbeSerial> Probes { get; init; } = Probes ?? ValueList<ProbeSerial>.Empty;

    public ValueMap<ProbeSerial, int> HopCounts { get; init; } = HopCounts ?? ValueMap<ProbeSerial, int>.Empty;
}
