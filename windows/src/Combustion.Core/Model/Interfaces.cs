using Combustion.Codec;

namespace Combustion.Core;

// Shared types between Links (producers) and Stores (consumers). docs/02 §3, §5, §6.
// Node serials are plain strings (Swift typealias NodeSerial = String).

public enum LinkKind { Advertisement, DirectConnection, NodeConnection, NodeAdvertisement }

/// <summary>Identity of a path, ignoring per-packet values (rssi, lastSeen).</summary>
public readonly record struct PathKey(LinkKind Kind, string? Via);

/// <summary>One path that delivers data for a probe. docs/02 §3 LinkSource.</summary>
public sealed record LinkSource(
    LinkKind Kind,
    DateTimeOffset LastSeen,
    string? Via = null,
    int? HopCount = null,
    int? Rssi = null,
    bool? HighRadioPower = null)
{
    public PathKey PathKey => new(Kind, Via);
}

public sealed record LinkInfo(ValueList<LinkSource> Sources, LinkSource? Primary = null)
{
    public static LinkInfo None { get; } = new(ValueList<LinkSource>.Empty);
}

/// <summary>What a link reports about one probe. Links emit these; ProbeStore merges them.</summary>
public abstract record ObservationPayload
{
    private ObservationPayload() { }

    /// <summary>Advertisement data only (no prediction, alarms, session).</summary>
    public sealed record Advertisement(ProbeAdvertisement Value) : ObservationPayload;

    /// <summary>Full status from GATT Probe Status or node 0x45.</summary>
    public sealed record Status(ProbeStatusPayload Value) : ObservationPayload;
}

public sealed record ProbeObservation(ProbeSerial Serial, LinkSource Source, ObservationPayload Payload, DateTimeOffset ReceivedAt);

/// <summary>Something that can read log records for a probe (DirectProbeLink, NodeLink).
/// HistoryStore uses it for backfill and live fetches. docs/02 §6.3.</summary>
public interface ILogFetcher
{
    /// <summary>Streams records in [start, end]. Finishes at <paramref name="end"/> or after the idle timeout; errors end the enumeration with an exception.</summary>
    IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end);
}

/// <summary>A MeatNet node heard advertising (AdvertisementSource output, ProbeStore input).</summary>
public sealed record NodeSighting(string Serial, NodeProductType ProductType, PeripheralId Peripheral, int Rssi, DateTimeOffset Time);
