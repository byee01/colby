using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// Merge state of one probe: many sources in, one <see cref="ProbeSnapshot"/> out. docs/02 §6.1. Pure (no clock, no I/O);
/// <see cref="ProbeStore"/> supplies arrival times.
/// <list type="bullet">
/// <item>Live fields (temperatures, mode, color, probe number, battery, virtual sensors, overheating) come from the
/// freshest observation of any kind. An absent overheating byte keeps the previous value.</item>
/// <item>Status-only fields (prediction, alarms, food safe, session/log range) come from the freshest full status.
/// Advertisements never touch them, and they survive loss of every source (the probe is shown offline).</item>
/// <item>Freshness is <c>ProbeObservation.ReceivedAt</c>; ties go to the later arrival.</item>
/// </list>
/// </summary>
internal sealed class ProbeMerger(ProbeSerial serial)
{
    internal readonly record struct Entry(LinkSource Source, DateTimeOffset ArrivedAt);

    private sealed record Live(
        ProbeTemperatures Temperatures, ProbeMode Mode, ProbeColor Color, int ProbeNumber, bool BatteryLow,
        VirtualSensors VirtualSensors, SensorSet Overheating, DateTimeOffset ReceivedAt);

    private sealed record StatusPart(
        PredictionStatus Prediction, AlarmConfig? Alarms, FoodSafe? FoodSafe, ProbeSessionState Session, DateTimeOffset ReceivedAt);

    private readonly Dictionary<PathKey, Entry> _sources = [];
    private Live? _live;
    private StatusPart? _status;
    private InstantReadFilter _filter;

    public ProbeSerial Serial { get; } = serial;

    public IReadOnlyDictionary<PathKey, Entry> Sources => _sources;

    /// <summary>Returns true if the observation was an accepted (freshest) full status.</summary>
    public bool Ingest(ProbeObservation o, DateTimeOffset arrivedAt)
    {
        _sources[o.Source.PathKey] = new Entry(o.Source, arrivedAt);
        switch (o.Payload)
        {
            case ObservationPayload.Advertisement { Value: var ad }:
                AcceptLive(o.ReceivedAt, ad.Temperatures, ad.Mode, ad.Color, ad.ProbeNumber, ad.BatteryLow, ad.VirtualSensors, ad.Overheating);
                return false;
            case ObservationPayload.Status { Value: var s }:
                AcceptLive(o.ReceivedAt, s.Temperatures, s.Mode, s.Color, s.ProbeNumber, s.BatteryLow, s.VirtualSensors, s.Overheating);
                if (_status is { } cur && o.ReceivedAt < cur.ReceivedAt)
                {
                    return false;
                }
                _status = new StatusPart(
                    s.Prediction,
                    s.Alarms ?? _status?.Alarms,
                    s.FoodSafe ?? _status?.FoodSafe,
                    new ProbeSessionState(s.Session, s.LogRange),
                    o.ReceivedAt);
                return true;
            default:
                return false;
        }
    }

    private void AcceptLive(
        DateTimeOffset receivedAt, ProbeTemperatures temperatures, ProbeMode mode, ProbeColor color, int probeNumber,
        bool batteryLow, VirtualSensors virtualSensors, SensorSet? overheating)
    {
        if (_live is { } cur && receivedAt < cur.ReceivedAt)
        {
            return;
        }
        _live = new Live(temperatures, mode, color, probeNumber, batteryLow, virtualSensors,
            overheating ?? _live?.Overheating ?? SensorSet.Empty, receivedAt);
        // Instant Read: only T1 is meaningful; filter it. Any other mode resets the filter.
        _filter.AddReading(mode == ProbeMode.InstantRead ? temperatures[SensorIndex.T1] : null);
    }

    /// <summary>Drops sources with no data for <paramref name="ttl"/> seconds. Returns true if any was dropped.</summary>
    public bool Expire(DateTimeOffset now, double ttl)
    {
        var gone = _sources.Where(kv => now.Since(kv.Value.ArrivedAt) >= ttl).Select(kv => kv.Key).ToList();
        foreach (var k in gone)
        {
            _sources.Remove(k);
        }
        return gone.Count > 0;
    }

    public bool HasData => _live is not null;

    public ProbeSnapshot? Snapshot()
    {
        if (_live is not { } live)
        {
            return null;
        }
        var instant = live.Mode == ProbeMode.InstantRead;
        var temps = live.Temperatures.Celsius.Select((c, i) => instant && i != 0 ? (double?)null : c).ToArray();
        var vs = live.VirtualSensors;
        var @virtual = new VirtualTemps(vs.Core, vs.Surface, vs.Ambient,
            temps[(int)vs.Core], temps[(int)vs.Surface], temps[(int)vs.Ambient]);
        var ordered = _sources.Values.Select(e => e.Source).ToList();
        ordered.Sort(Compare);
        return new ProbeSnapshot(
            Serial, live.ProbeNumber, live.Color, live.Mode, temps, @virtual, live.BatteryLow,
            new LinkInfo(ordered, ordered.Count > 0 ? ordered[0] : null),
            live.ReceivedAt,
            InstantRead: instant ? _filter.Celsius : null,
            InstantReadFahrenheit: instant ? _filter.Fahrenheit : null,
            Overheating: live.Overheating,
            Prediction: _status?.Prediction,
            Alarms: _status?.Alarms,
            FoodSafe: _status?.FoodSafe,
            Session: _status?.Session);
    }

    /// <summary>directConnection &gt; nodeConnection (lowest hop) &gt; advertisement &gt; nodeAdvertisement;
    /// then lowest hop count, freshest, and a stable tiebreak.</summary>
    internal static bool Precedes(LinkSource a, LinkSource b) => Compare(a, b) < 0;

    internal static int Compare(LinkSource a, LinkSource b)
    {
        if (Rank(a.Kind) != Rank(b.Kind))
        {
            return Rank(a.Kind).CompareTo(Rank(b.Kind));
        }
        var ha = a.HopCount ?? int.MaxValue;
        var hb = b.HopCount ?? int.MaxValue;
        if (ha != hb)
        {
            return ha.CompareTo(hb);
        }
        if (a.LastSeen != b.LastSeen)
        {
            return b.LastSeen.CompareTo(a.LastSeen);
        }
        return string.CompareOrdinal(a.Via ?? "", b.Via ?? "");
    }

    private static int Rank(LinkKind k) => k switch
    {
        LinkKind.DirectConnection => 0,
        LinkKind.NodeConnection => 1,
        LinkKind.Advertisement => 2,
        _ => 3,
    };
}
