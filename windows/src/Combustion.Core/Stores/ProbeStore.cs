using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Where followed probes are persisted (the <c>probe</c> table). <c>HistoryStore</c> implements it.</summary>
public interface IFollowedProbePersistence
{
    Task<IReadOnlySet<ProbeSerial>> LoadFollowedAsync();

    Task SetFollowedAsync(ProbeSerial serial, bool followed);
}

/// <summary>
/// Merges observations from every link into one <see cref="ProbeSnapshot"/> per probe. docs/02 §6.1.
/// <list type="bullet">
/// <item>Streams replay the latest value to new subscribers.</item>
/// <item>UI-facing streams (<see cref="Probes"/>, <see cref="Probe"/>) are coalesced: the first change after a quiet period
/// is emitted immediately, later changes at most once per <c>coalesceInterval</c> (100 ms = 10 Hz) carrying the latest state.</item>
/// <item><see cref="StatusEvents"/> is not coalesced; it carries each accepted full status.</item>
/// <item>A source with no data for <c>sourceTimeout</c> is dropped (checked every <c>expiryCheckInterval</c>, so the drop
/// happens at the first check at or after the timeout). A probe whose sources are all gone stays, offline.</item>
/// </list>
/// Call <see cref="StartAsync"/> once to load the persisted followed set; the timers start lazily on the first ingest.
/// Confined to the core context (Swift: actor).
/// </summary>
public sealed class ProbeStore
{
    private readonly IClock _clock;
    private readonly IFollowedProbePersistence? _persistence;
    private readonly TimeSpan _sourceTimeout;
    private readonly TimeSpan _coalesceInterval;
    private readonly TimeSpan _expiryCheckInterval;

    private readonly Dictionary<ProbeSerial, ProbeMerger> _mergers = [];
    private readonly Dictionary<ProbeSerial, ProbeSnapshot> _published = [];
    private readonly HashSet<ProbeSerial> _dirty = [];
    private TimeSpan? _lastFlush;
    private CancellationTokenSource? _flush;
    private CancellationTokenSource? _expiry;
    private readonly HashSet<ProbeSerial> _followed = [];
    private readonly Dictionary<ProbeSerial, Broadcaster<ProbeSnapshot?>> _perProbe = [];

    private readonly Broadcaster<ValueMap<ProbeSerial, ProbeSnapshot>> _probes = new(ValueMap<ProbeSerial, ProbeSnapshot>.Empty);
    private readonly Broadcaster<ValueSet<ProbeSerial>> _followedOut = new(ValueSet<ProbeSerial>.Empty);
    private readonly Broadcaster<ProbeStatusEvent> _status = new();
    private readonly Dictionary<string, NodeSnapshot> _nodes = [];
    private readonly Broadcaster<ValueMap<string, NodeSnapshot>> _nodesOut = new(ValueMap<string, NodeSnapshot>.Empty);

    public ProbeStore(
        IClock clock,
        IFollowedProbePersistence? persistence = null,
        TimeSpan? sourceTimeout = null,
        TimeSpan? coalesceInterval = null,
        TimeSpan? expiryCheckInterval = null)
    {
        _clock = clock;
        _persistence = persistence;
        _sourceTimeout = sourceTimeout ?? TimeSpan.FromSeconds(10);
        _coalesceInterval = coalesceInterval ?? TimeSpan.FromMilliseconds(100);
        _expiryCheckInterval = expiryCheckInterval ?? TimeSpan.FromSeconds(1);
    }

    // Observables

    /// <summary>All probes, latest map (coalesced).</summary>
    public AsyncStream<ValueMap<ProbeSerial, ProbeSnapshot>> Probes() => _probes.Stream();

    /// <summary>One probe; emits null first if the probe is unknown (coalesced).</summary>
    public AsyncStream<ProbeSnapshot?> Probe(ProbeSerial serial)
    {
        if (!_perProbe.TryGetValue(serial, out var b))
        {
            b = new Broadcaster<ProbeSnapshot?>(_published.GetValueOrDefault(serial));
            _perProbe[serial] = b;
        }
        return b.Stream();
    }

    public AsyncStream<ValueSet<ProbeSerial>> Followed() => _followedOut.Stream();

    /// <summary>Every accepted full status (freshest per probe), uncoalesced. For HistoryStore and session detection.</summary>
    public AsyncStream<ProbeStatusEvent> StatusEvents() => _status.Stream();

    /// <summary>MeatNet nodes in range or connected (not coalesced; nodes change at heartbeat rate).</summary>
    public AsyncStream<ValueMap<string, NodeSnapshot>> Nodes() => _nodesOut.Stream();

    // Direct reads (not coalesced)

    public IReadOnlyDictionary<string, NodeSnapshot> NodeSnapshots() => new Dictionary<string, NodeSnapshot>(_nodes);

    public ProbeSnapshot? Snapshot(ProbeSerial serial) => _mergers.GetValueOrDefault(serial)?.Snapshot();

    public IReadOnlyDictionary<ProbeSerial, ProbeSnapshot> Snapshots()
    {
        var all = new Dictionary<ProbeSerial, ProbeSnapshot>();
        foreach (var (serial, m) in _mergers)
        {
            if (m.Snapshot() is { } s)
            {
                all[serial] = s;
            }
        }
        return all;
    }

    // Lifecycle

    /// <summary>Loads the persisted followed set.</summary>
    public async Task StartAsync()
    {
        if (_persistence is null)
        {
            return;
        }
        try
        {
            var loaded = await _persistence.LoadFollowedAsync();
            _followed.UnionWith(loaded);
            _followedOut.Send(new ValueSet<ProbeSerial>(_followed));
        }
        catch (Exception)
        {
            // Swift: try? — a broken store starts with nothing followed.
        }
    }

    /// <summary>Cancels timers. Streams stay open.</summary>
    public void Stop()
    {
        _flush?.Cancel();
        _flush = null;
        _expiry?.Cancel();
        _expiry = null;
    }

    // Ingest

    public void Ingest(ProbeObservation o)
    {
        EnsureExpiryTimer();
        if (!_mergers.TryGetValue(o.Serial, out var m))
        {
            m = new ProbeMerger(o.Serial);
            _mergers[o.Serial] = m;
        }
        var accepted = m.Ingest(o, _clock.Now());
        if (accepted && o.Payload is ObservationPayload.Status { Value: var s })
        {
            _status.Send(new ProbeStatusEvent(o.Serial, s, o.ReceivedAt));
        }
        MarkDirty(o.Serial);
    }

    /// <summary>Records a <c>NodeLink</c> snapshot. It replaces what is known, except firmware it has not read yet.</summary>
    public void Ingest(NodeSnapshot node)
    {
        EnsureExpiryTimer();
        if (node.Firmware is null && _nodes.TryGetValue(node.Serial, out var known))
        {
            node = node with { Firmware = known.Firmware };
        }
        Store(node);
    }

    /// <summary>Records a node heard advertising. A connected node is already better known and is left alone.</summary>
    public void Ingest(NodeSighting s)
    {
        EnsureExpiryTimer();
        var source = new LinkSource(LinkKind.NodeAdvertisement, s.Time, Rssi: s.Rssi);
        if (!_nodes.TryGetValue(s.Serial, out var n))
        {
            Store(new NodeSnapshot(s.Serial, s.ProductType, source));
            return;
        }
        if (n.IsConnected)
        {
            return;
        }
        Store(n with { ProductType = s.ProductType, Link = source });
    }

    private void Store(NodeSnapshot n)
    {
        if (_nodes.TryGetValue(n.Serial, out var cur) && cur == n)
        {
            return;
        }
        _nodes[n.Serial] = n;
        _nodesOut.Send(new ValueMap<string, NodeSnapshot>(_nodes));
    }

    // Follow

    public async Task FollowAsync(ProbeSerial serial)
    {
        if (!_followed.Add(serial))
        {
            return;
        }
        _followedOut.Send(new ValueSet<ProbeSerial>(_followed));
        await Persist(serial, true);
    }

    public async Task UnfollowAsync(ProbeSerial serial)
    {
        if (!_followed.Remove(serial))
        {
            return;
        }
        _followedOut.Send(new ValueSet<ProbeSerial>(_followed));
        await Persist(serial, false);
    }

    private async Task Persist(ProbeSerial serial, bool followed)
    {
        if (_persistence is null)
        {
            return;
        }
        try
        {
            await _persistence.SetFollowedAsync(serial, followed);
        }
        catch (Exception)
        {
            // Swift: try? — in-memory state wins; the next change retries.
        }
    }

    public IReadOnlySet<ProbeSerial> FollowedSerials() => new HashSet<ProbeSerial>(_followed);

    // Source expiry

    private void EnsureExpiryTimer()
    {
        if (_expiry is not null)
        {
            return;
        }
        _expiry = new CancellationTokenSource();
        var ticks = _clock.Timer(_expiryCheckInterval);
        _ = ticks.ForEachAsync(_ => ExpireSources(), _expiry.Token);
    }

    private void ExpireSources()
    {
        var now = _clock.Now();
        var ttl = _sourceTimeout.TotalSeconds;
        foreach (var (serial, m) in _mergers.ToList())
        {
            if (m.Expire(now, ttl))
            {
                MarkDirty(serial);
            }
        }
        // A node that is neither connected nor heard advertising is gone.
        var stale = _nodes.Where(kv => !kv.Value.IsConnected && now.Since(kv.Value.Link.LastSeen) >= ttl).Select(kv => kv.Key).ToList();
        if (stale.Count > 0)
        {
            foreach (var serial in stale)
            {
                _nodes.Remove(serial);
            }
            _nodesOut.Send(new ValueMap<string, NodeSnapshot>(_nodes));
        }
    }

    // Coalesced publishing

    private void MarkDirty(ProbeSerial serial)
    {
        _dirty.Add(serial);
        if (_flush is not null)
        {
            return;
        }
        var now = _clock.Monotonic();
        if (_lastFlush is { } last && now - last < _coalesceInterval)
        {
            var wait = _coalesceInterval - (now - last);
            var cts = new CancellationTokenSource();
            _flush = cts;
            _ = ScheduledFlush(wait, cts);
        }
        else
        {
            Flush();
        }
    }

    private async Task ScheduledFlush(TimeSpan wait, CancellationTokenSource cts)
    {
        try
        {
            await _clock.SleepAsync(wait, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (_flush != cts)
        {
            return;
        }
        _flush = null;
        Flush();
    }

    private void Flush()
    {
        if (_dirty.Count == 0)
        {
            return;
        }
        _lastFlush = _clock.Monotonic();
        var serials = _dirty.ToList();
        _dirty.Clear();
        foreach (var serial in serials)
        {
            if (_mergers.GetValueOrDefault(serial)?.Snapshot() is not { } snap)
            {
                continue;
            }
            _published[serial] = snap;
            _perProbe.GetValueOrDefault(serial)?.Send(snap);
        }
        _probes.Send(new ValueMap<ProbeSerial, ProbeSnapshot>(_published));
    }
}
