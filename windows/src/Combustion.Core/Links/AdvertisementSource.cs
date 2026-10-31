using Combustion.Codec;

namespace Combustion.Core;

/// <summary>A probe heard advertising from its own peripheral (not repeated by a node). The peripheral is what a
/// direct connection needs; observations alone do not carry it.</summary>
public sealed record ProbeSighting(ProbeSerial Serial, PeripheralId Peripheral, int Rssi, DateTimeOffset Time);

/// <summary>A probe's data repeated by a node, heard on the node's peripheral. Tells the policy which node can reach
/// the probe even before the node's own advertisement has been matched to a serial.</summary>
/// <param name="Via">Null until the node's own advertisement has been heard.</param>
public sealed record RepeatedProbeSighting(ProbeSerial Serial, PeripheralId NodePeripheral, string? Via, int HopCount, int Rssi, DateTimeOffset Time);

public sealed record AdvertisementDiagnostics
{
    /// <summary>Advertisements received from the transport.</summary>
    public int Received { get; init; }

    /// <summary>Probe advertisements published (own and node-repeated).</summary>
    public int ProbePackets { get; init; }

    public int NodePackets { get; init; }

    /// <summary>Valid Combustion packets of a product type this version ignores.</summary>
    public int UnknownPackets { get; init; }

    /// <summary>Probe packets with serial 0: a node with no probe in that slot yet (a Display right after power-on
    /// repeats all-zero packets). Dropped.</summary>
    public int EmptySlotPackets { get; init; }

    /// <summary>Advertisements the codec rejected (wrong vendor, too short). Counted, never thrown.</summary>
    public int CodecErrors { get; init; }
}

/// <summary>
/// Decodes every advertisement and publishes probe observations and node sightings (docs/02 §5.2).
/// Gives live temperatures without using a probe connection slot.
/// Repeated-probe packets come from a node's peripheral; the node's own advertisements teach the source which
/// node serial lives on which peripheral, so <c>LinkSource.Via</c> can be filled. Until the node has been heard,
/// <c>Via</c> is null.
/// </summary>
public sealed class AdvertisementSource
{
    private readonly IBleTransport _transport;
    private readonly Broadcaster<ProbeObservation> _observations = new();
    private readonly Broadcaster<NodeSighting> _sightings = new();
    private readonly Broadcaster<ProbeSighting> _probeSightings = new();
    private readonly Broadcaster<RepeatedProbeSighting> _repeated = new();
    private readonly Dictionary<PeripheralId, string> _nodeByPeripheral = [];
    private AdvertisementDiagnostics _stats = new();
    private CancellationTokenSource? _task;

    public AdvertisementSource(IBleTransport transport)
    {
        _transport = transport;
    }

    public AsyncStream<ProbeObservation> Observations() => _observations.Stream();

    public AsyncStream<NodeSighting> NodeSightings() => _sightings.Stream();

    /// <summary>Probes heard on their own peripheral; <c>ConnectionPolicy</c> connects to these.</summary>
    public AsyncStream<ProbeSighting> ProbeSightings() => _probeSightings.Stream();

    /// <summary>Probes heard through a node; <c>ConnectionPolicy</c> uses them to decide on a node connection.</summary>
    public AsyncStream<RepeatedProbeSighting> RepeatedSightings() => _repeated.Stream();

    public AdvertisementDiagnostics Diagnostics => _stats;

    /// <summary>The node serial last advertised by <paramref name="peripheral"/>, if any.</summary>
    public string? NodeSerial(PeripheralId peripheral) => _nodeByPeripheral.GetValueOrDefault(peripheral);

    /// <summary>Starts scanning and consuming advertisements. Idempotent.</summary>
    public async Task StartAsync()
    {
        if (_task is not null)
        {
            return;
        }
        // Take the stream before scanning so nothing is missed.
        var stream = _transport.Advertisements();
        _task = new CancellationTokenSource();
        _ = stream.ForEachAsync(Process, _task.Token);
        await _transport.StartScanAsync();
    }

    public async Task StopAsync()
    {
        _task?.Cancel();
        _task = null;
        await _transport.StopScanAsync();
    }

    /// <summary>Decodes one advertisement. Exposed for replays that bypass the transport.</summary>
    public void Process(RawAdvertisement raw)
    {
        _stats = _stats with { Received = _stats.Received + 1 };
        AdvertisementPacket packet;
        try
        {
            packet = CombustionCodec.DecodeAdvertisement(raw.MfrData);
        }
        catch (CodecException)
        {
            _stats = _stats with { CodecErrors = _stats.CodecErrors + 1 };
            return;
        }
        switch (packet)
        {
            case AdvertisementPacket.Probe { Advertisement.Serial.Raw: 0 }:
            case AdvertisementPacket.Repeated { Advertisement.Serial.Raw: 0 }:
                _stats = _stats with { EmptySlotPackets = _stats.EmptySlotPackets + 1 };
                break;
            case AdvertisementPacket.Probe { Advertisement: var probe }:
                _stats = _stats with { ProbePackets = _stats.ProbePackets + 1 };
                Publish(probe, LinkKind.Advertisement, null, null, raw);
                _probeSightings.Send(new ProbeSighting(probe.Serial, raw.Peripheral, raw.Rssi, raw.Time));
                break;
            case AdvertisementPacket.Repeated { Advertisement: var probe, HopCount: var hops }:
                _stats = _stats with { ProbePackets = _stats.ProbePackets + 1 };
                var via = _nodeByPeripheral.GetValueOrDefault(raw.Peripheral);
                Publish(probe, LinkKind.NodeAdvertisement, via, hops, raw);
                _repeated.Send(new RepeatedProbeSighting(probe.Serial, raw.Peripheral, via, hops, raw.Rssi, raw.Time));
                break;
            case AdvertisementPacket.Node { Advertisement: var node }:
                _stats = _stats with { NodePackets = _stats.NodePackets + 1 };
                _nodeByPeripheral[raw.Peripheral] = node.Serial;
                _sightings.Send(new NodeSighting(node.Serial, node.ProductType, raw.Peripheral, raw.Rssi, raw.Time));
                break;
            default:
                _stats = _stats with { UnknownPackets = _stats.UnknownPackets + 1 };
                break;
        }
    }

    private void Publish(ProbeAdvertisement probe, LinkKind kind, string? via, int? hopCount, RawAdvertisement raw)
    {
        var source = new LinkSource(kind, raw.Time, via, hopCount, raw.Rssi, probe.Preferences?.HighRadioPower);
        _observations.Send(new ProbeObservation(probe.Serial, source, new ObservationPayload.Advertisement(probe), raw.Time));
    }
}
