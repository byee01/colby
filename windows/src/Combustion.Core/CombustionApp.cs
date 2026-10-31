using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Counters and link states for a diagnostics screen. docs/02 §13 <c>diagnostics</c>.</summary>
/// <param name="Uart">UART counters per followed probe, summed over every link it has had since <c>StartAsync</c>.</param>
/// <param name="StatusDecodeErrors">Probe Status notifications the codec rejected, per probe, summed over links.</param>
/// <param name="NodeLinks">Connection state of each MeatNet node the policy is working on.</param>
/// <param name="LogFetchesInFlight">Log downloads (live fetch or backfill) in progress.</param>
public sealed record DiagnosticsSnapshot(
    BluetoothState Bluetooth,
    AdvertisementDiagnostics Advertisements,
    ValueMap<ProbeSerial, UartDiagnostics> Uart,
    ValueMap<ProbeSerial, int> StatusDecodeErrors,
    ValueMap<ProbeSerial, ProbeConnectionState> Links,
    ValueMap<string, ProbeConnectionState> NodeLinks,
    int LogFetchesInFlight);

/// <summary>
/// The facade a UI talks to (docs/02 §13): probes, history, follow, diagnostics, predictions, commands, alerts.
/// Wiring:
/// <list type="bullet">
/// <item><see cref="AdvertisementSource"/> -&gt; <see cref="ProbeStore"/>.</item>
/// <item>The connection policy makes a <see cref="DirectProbeLink"/> per followed probe; link observations -&gt; <see cref="ProbeStore"/>.</item>
/// <item><c>ProbeStore.StatusEvents</c> (followed probes only) -&gt; <see cref="HistoryStore"/>, one ordered lane per probe.</item>
/// <item>After the first status of each (re)connection is recorded, <c>HistoryStore.BackfillAsync</c> runs over that link.
/// It repeats while holes remain and re-checks every minute while connected.</item>
/// <item>The store's live <see cref="ILogFetcher"/> routes each probe to its current link and fails while it has none.</item>
/// </list>
/// Confined to the core context.
/// </summary>
public sealed class CombustionApp : IDisposable
{
    private readonly IBleTransport _transport;
    private readonly IClock _clock;
    private readonly AdvertisementSource _advertisements;
    private readonly IConnectionPolicy _policy;
    private readonly ITraceSink? _trace;
    private readonly LinkRouter _router = new();
    private readonly LinkCoordinator _coordinator;

    private CancellationTokenSource? _tasks;
    private readonly Dictionary<ProbeSerial, AsyncStream<ProbeStatusEvent>> _lanes = [];
    private readonly Dictionary<ProbeSerial, SessionKey> _lastSession = [];
    private bool _started;
    private Core.BluetoothState _bluetooth = Core.BluetoothState.PoweredOff;

    /// <param name="databasePath">A file path or <c>":memory:"</c>.</param>
    /// <param name="policy">Defaults to <see cref="DirectConnectionPolicy"/>.</param>
    /// <param name="trace">Optional parity trace (docs/05 §3): <c>probe</c>, <c>session</c> and <c>link</c> events.</param>
    /// <param name="alertSinks">Where alert events go (notification, sound); none by default.</param>
    /// <param name="keepAwake">Held while a followed probe is in a cook.</param>
    /// <param name="alertRuleStore">Defaults to a <see cref="SqliteAlertStore"/> on <paramref name="databasePath"/>, which also logs alert events.</param>
    /// <param name="liveSnapshot">Where to write the widget snapshot; no snapshot when null.</param>
    public CombustionApp(
        IBleTransport transport, IClock clock, string databasePath = ":memory:",
        IConnectionPolicy? policy = null, ITraceSink? trace = null,
        IReadOnlyList<IAlertSink>? alertSinks = null, IKeepAwake? keepAwake = null,
        IAlertRuleStore? alertRuleStore = null, ILiveSnapshotWriting? liveSnapshot = null)
    {
        // History migrates the shared schema first; the alert store's own connection then finds it current.
        History = new HistoryStore(databasePath, clock, _router);
        AlertStore = alertRuleStore is null ? new SqliteAlertStore(databasePath) : null;
        LiveSnapshot = liveSnapshot is null ? null : new LiveSnapshotWriter(clock, liveSnapshot);
        _transport = transport;
        _clock = clock;
        Probes = new ProbeStore(clock, History);
        _advertisements = new AdvertisementSource(transport);
        _policy = policy ?? new DirectConnectionPolicy();
        _trace = trace;
        _coordinator = new LinkCoordinator(Probes, History, clock, _router, trace);
        Commands = new Commands(Probes, _router, clock, trace);
        PredictionPresenter = new PredictionPresenter(Probes, clock);
        Alerts = new AlertEngine(clock, alertRuleStore ?? AlertStore, alertSinks, keepAwake, Commands, trace);
    }

    public ProbeStore Probes { get; }

    public HistoryStore History { get; }

    public Commands Commands { get; }

    public AlertEngine Alerts { get; }

    public PredictionPresenter PredictionPresenter { get; }

    /// <summary>Alert rules and the alert log, in the app database (null when a custom rule store was passed).</summary>
    public SqliteAlertStore? AlertStore { get; }

    /// <summary>Widget snapshot writer (docs/02 §18); null unless a destination was passed.</summary>
    public LiveSnapshotWriter? LiveSnapshot { get; }

    /// <summary>MeatNet nodes in range or connected (<c>ProbeStore.Nodes</c>).</summary>
    public AsyncStream<ValueMap<string, NodeSnapshot>> Nodes() => Probes.Nodes();

    /// <summary>Bluetooth state: current value first, then changes.</summary>
    public AsyncStream<Core.BluetoothState> BluetoothState() => _transport.State();

    /// <summary>One probe's prediction for the UI: the latest view first, then every change. docs/02 §7.</summary>
    public AsyncStream<PredictionView> Predictions(ProbeSerial serial) => PredictionPresenter.Predictions(serial);

    // Lifecycle

    /// <summary>Loads the followed set, starts scanning and the connection policy. Idempotent.</summary>
    public async Task StartAsync()
    {
        if (_started)
        {
            return;
        }
        _started = true;
        await Probes.StartAsync();

        // Subscribe before anything can produce events.
        var observations = _advertisements.Observations();
        var sightings = _advertisements.ProbeSightings();
        var statuses = Probes.StatusEvents();
        var followed = Probes.Followed();
        var bluetoothChanges = _transport.State();
        var nodeSightings = _advertisements.NodeSightings();
        var policyNodes = _advertisements.NodeSightings();
        var policyRepeated = _advertisements.RepeatedSightings();
        var alertEvents = Alerts.Events();

        _tasks = new CancellationTokenSource();
        var ct = _tasks.Token;
        _ = observations.ForEachAsync(Probes.Ingest, ct);
        _ = ForEachAsync(statuses, RouteAsync, ct);
        _ = nodeSightings.ForEachAsync(Probes.Ingest, ct);
        if (AlertStore is not null)
        {
            _ = AlertStore.ConsumeAsync(alertEvents, ct);
        }
        else
        {
            alertEvents.Finish();
        }
        _ = ForEachAsync(bluetoothChanges, BluetoothChangedAsync, ct);

        PredictionPresenter.Start();
        Alerts.Start(Probes.Probes(), PredictionPresenter.Updates(), Probes.Followed());
        LiveSnapshot?.Start(Probes.Probes(), PredictionPresenter.Updates(), Probes.Followed());
        if (LiveSnapshot is { } writer)
        {
            _ = ForEachAsync(History.CookNames(), writer.SetNamesAsync, ct);
        }

        await _advertisements.StartAsync();
        await _policy.StartAsync(new ConnectionPolicyInput(
            _transport, _clock, sightings, followed, _coordinator, policyNodes, policyRepeated));
    }

    /// <summary>Closes every link, stops scanning and timers. Streams of the stores stay open.</summary>
    public async Task StopAsync()
    {
        if (!_started)
        {
            return;
        }
        _started = false;
        _tasks?.Cancel();
        _tasks = null;
        await Alerts.StopAsync();
        LiveSnapshot?.Stop();
        PredictionPresenter.Stop();
        await _policy.StopAsync();
        _coordinator.Shutdown();
        foreach (var lane in _lanes.Values)
        {
            lane.Finish();
        }
        _lanes.Clear();
        await _advertisements.StopAsync();
        Probes.Stop();
    }

    public void Dispose()
    {
        History.Dispose();
        AlertStore?.Dispose();
    }

    // Follow

    public Task FollowAsync(ProbeSerial serial) => Probes.FollowAsync(serial);

    public Task UnfollowAsync(ProbeSerial serial) => Probes.UnfollowAsync(serial);

    // Cook names

    /// <summary>Each probe's current cook name (absent when unnamed): the latest map first, then changes.</summary>
    public AsyncStream<ValueMap<ProbeSerial, string>> CookNames() => History.CookNames();

    /// <summary>Names the probe's current cook, or its next one if none is open; null or blank clears it.
    /// History rows and the widget snapshot show it.</summary>
    public void SetCookName(string? name, ProbeSerial serial) => History.SetCookName(name, serial);

    // Diagnostics

    public DiagnosticsSnapshot Diagnostics()
    {
        var (uart, decode) = _coordinator.LinkCounters();
        return new DiagnosticsSnapshot(
            _bluetooth, _advertisements.Diagnostics, uart, decode,
            new ValueMap<ProbeSerial, ProbeConnectionState>(_policy.States()),
            new ValueMap<string, ProbeConnectionState>(_policy.NodeStates()),
            History.FetchesInFlight);
    }

    // Internals

    private static async Task ForEachAsync<T>(IAsyncEnumerable<T> source, Func<T, Task> body, CancellationToken ct)
    {
        try
        {
            await foreach (var item in source.WithCancellation(ct))
            {
                await body(item);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    private async Task BluetoothChangedAsync(Core.BluetoothState state)
    {
        _bluetooth = state;
        // Leaving poweredOn stops the scan; resume it when Bluetooth returns.
        if (state == Core.BluetoothState.PoweredOn && _started)
        {
            await _transport.StartScanAsync();
        }
    }

    private Task RouteAsync(ProbeStatusEvent e)
    {
        if (!_started || !Probes.FollowedSerials().Contains(e.Serial))
        {
            return Task.CompletedTask;
        }
        if (_lanes.TryGetValue(e.Serial, out var lane))
        {
            lane.Yield(e);
            return Task.CompletedTask;
        }
        lane = new AsyncStream<ProbeStatusEvent>();
        _lanes[e.Serial] = lane;
        _ = ForEachAsync(lane, ProcessAsync, _tasks?.Token ?? CancellationToken.None);
        lane.Yield(e);
        return Task.CompletedTask;
    }

    /// <summary>Records one status. Runs in the probe's own lane, so statuses of one probe stay in order and a slow
    /// log fetch on one probe does not hold up another.</summary>
    private async Task ProcessAsync(ProbeStatusEvent e)
    {
        var s = e.Status;
        var core = s.Temperatures[s.VirtualSensors.Core];
        _trace?.Emit("probe", new Dictionary<string, TraceValue>
        {
            ["serial"] = e.Serial,
            ["core"] = core,
            ["state"] = PredictionStateName(s.Prediction.State),
        });
        SessionKey key;
        try
        {
            key = await History.IngestAsync(e);
        }
        catch (Exception)
        {
            return;
        }
        if (!_lastSession.TryGetValue(e.Serial, out var last) || last != key)
        {
            if (_lastSession.ContainsKey(e.Serial))
            {
                _trace?.Emit("session", new Dictionary<string, TraceValue>
                {
                    ["serial"] = last.Serial, ["sessionId"] = (long)last.SessionId, ["transition"] = "ended",
                });
            }
            _trace?.Emit("session", new Dictionary<string, TraceValue>
            {
                ["serial"] = key.Serial, ["sessionId"] = (long)key.SessionId, ["transition"] = "started",
            });
            _lastSession[e.Serial] = key;
        }
        _coordinator.StatusRecorded(e.Serial, e.ReceivedAt);
    }

    /// <summary>Swift <c>String(describing:)</c> of the state: lowerCamelCase case names.</summary>
    internal static string PredictionStateName(PredictionState state)
    {
        var name = state.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }
}

/// <summary>Routes log fetches and commands to the current link of each probe: its direct link if it has one, else
/// a node that is relaying it (nearest first).</summary>
internal sealed class LinkRouter : ILogFetcher, ICommandRouting
{
    private readonly Dictionary<ProbeSerial, DirectProbeLink> _links = [];
    private readonly Dictionary<string, NodeLink> _nodes = [];

    public void Set(ProbeSerial serial, DirectProbeLink? link)
    {
        if (link is null)
        {
            _links.Remove(serial);
        }
        else
        {
            _links[serial] = link;
        }
    }

    public void SetNode(string serial, NodeLink? link)
    {
        if (link is null)
        {
            _nodes.Remove(serial);
        }
        else
        {
            _nodes[serial] = link;
        }
    }

    public ICommandRoute? CommandRoute(ProbeSerial probe) =>
        _links.TryGetValue(probe, out var direct) ? new DirectCommandRoute(direct)
        : NearestNode(probe) is { } node ? new NodeCommandRoute(node)
        : null;

    public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end)
    {
        if (_links.TryGetValue(probe, out var direct))
        {
            return direct.ReadLogs(probe, start, end);
        }
        if (NearestNode(probe) is { } node)
        {
            return node.ReadLogs(probe, start, end);
        }
        var failed = new AsyncStream<LogRecord>();
        failed.Finish(UartException.Disconnected);
        return failed;
    }

    private NodeLink? NearestNode(ProbeSerial probe) =>
        _nodes.Values
            .Select(n => (Node: n, Hops: n.Hops(probe)))
            .Where(x => x.Hops is not null)
            .OrderBy(x => x.Hops).ThenBy(x => x.Node.Serial, StringComparer.Ordinal)
            .Select(x => x.Node)
            .FirstOrDefault();
}

/// <summary>Receives links from the policy: forwards their observations, publishes them to the router and runs
/// the backfill loop.</summary>
internal sealed class LinkCoordinator : IConnectionPolicyDelegate
{
    internal static readonly TimeSpan RecheckInterval = TimeSpan.FromSeconds(60);

    private readonly ProbeStore _probes;
    private readonly HistoryStore _history;
    private readonly IClock _clock;
    private readonly LinkRouter _router;
    private readonly ITraceSink? _trace;

    private readonly Dictionary<ProbeSerial, DirectProbeLink> _links = [];
    private readonly Dictionary<ProbeSerial, CancellationTokenSource> _forwarders = [];
    private readonly Dictionary<ProbeSerial, CancellationTokenSource> _backfills = [];
    private readonly Dictionary<string, NodeLink> _nodeLinks = [];
    private readonly Dictionary<string, CancellationTokenSource> _nodeForwarders = [];
    /// <summary>Probes whose running backfill reads through a node, and which one (no direct link at the time).</summary>
    private readonly Dictionary<ProbeSerial, string> _nodeBackfills = [];
    /// <summary>Probes whose link is up but whose first status has not been recorded yet.</summary>
    private readonly Dictionary<ProbeSerial, DateTimeOffset> _awaitingFirstStatus = [];
    private readonly Dictionary<ProbeSerial, UartDiagnostics> _retiredUart = [];
    private readonly Dictionary<ProbeSerial, int> _retiredDecodeErrors = [];

    public LinkCoordinator(ProbeStore probes, HistoryStore history, IClock clock, LinkRouter router, ITraceSink? trace)
    {
        _probes = probes;
        _history = history;
        _clock = clock;
        _router = router;
        _trace = trace;
    }

    public Task LinkCreatedAsync(DirectProbeLink link)
    {
        var serial = link.Serial;
        _links[serial] = link;
        Cancel(_forwarders, serial);
        var cts = new CancellationTokenSource();
        _forwarders[serial] = cts;
        _ = link.Observations().ForEachAsync(_probes.Ingest, cts.Token);
        return Task.CompletedTask;
    }

    public Task LinkEstablishedAsync(DirectProbeLink link)
    {
        var serial = link.Serial;
        _router.Set(serial, link);
        _awaitingFirstStatus[serial] = _clock.Now();
        _trace?.Emit("link", new Dictionary<string, TraceValue> { ["serial"] = serial, ["state"] = "connected" });
        return Task.CompletedTask;
    }

    public Task LinkEndedAsync(ProbeSerial serial, DisconnectReason reason)
    {
        _router.Set(serial, null);
        _awaitingFirstStatus.Remove(serial);
        Cancel(_backfills, serial);
        _nodeBackfills.Remove(serial);
        Cancel(_forwarders, serial);
        if (_links.Remove(serial, out var link))
        {
            _retiredUart[serial] = Sum(_retiredUart.GetValueOrDefault(serial), link.Uart.Diagnostics);
            _retiredDecodeErrors[serial] = _retiredDecodeErrors.GetValueOrDefault(serial) + link.StatusDecodeErrors;
        }
        _trace?.Emit("link", new Dictionary<string, TraceValue>
        {
            ["serial"] = serial, ["state"] = "disconnected", ["reason"] = ReasonName(reason),
        });
        return Task.CompletedTask;
    }

    /// <summary>
    /// Called after a status was recorded in history. The first one after a connect starts the backfill:
    /// until then the session for this connection may not exist (new session) or may still be the old one.
    /// A probe with no direct link but relayed by a connected node gets its backfill through the node
    /// (the router picks the node per read), started by its first recorded status.
    /// </summary>
    public void StatusRecorded(ProbeSerial serial, DateTimeOffset receivedAt)
    {
        if (_awaitingFirstStatus.TryGetValue(serial, out var since) && receivedAt >= since && _links.TryGetValue(serial, out var link))
        {
            _awaitingFirstStatus.Remove(serial);
            Cancel(_backfills, serial);
            _nodeBackfills.Remove(serial);
            StartBackfill(serial, link);
            return;
        }
        if (_links.ContainsKey(serial) || _backfills.ContainsKey(serial))
        {
            return;
        }
        if (_nodeLinks.Values.FirstOrDefault(n => n.Covers(serial)) is not { } node)
        {
            return;
        }
        _nodeBackfills[serial] = node.Serial;
        StartBackfill(serial, _router);
    }

    private void StartBackfill(ProbeSerial serial, ILogFetcher fetcher)
    {
        var cts = new CancellationTokenSource();
        _backfills[serial] = cts;
        _ = RunBackfillAsync(serial, fetcher, cts.Token);
    }

    // Nodes

    public Task NodeLinkCreatedAsync(NodeLink link)
    {
        var serial = link.Serial;
        _nodeLinks[serial] = link;
        Cancel(_nodeForwarders, serial);
        var cts = new CancellationTokenSource();
        _nodeForwarders[serial] = cts;
        _ = link.Observations().ForEachAsync(_probes.Ingest, cts.Token);
        _ = link.Snapshots().ForEachAsync(_probes.Ingest, cts.Token);
        return Task.CompletedTask;
    }

    public Task NodeLinkEstablishedAsync(NodeLink link)
    {
        _router.SetNode(link.Serial, link);
        return Task.CompletedTask;
    }

    public Task NodeLinkEndedAsync(string serial, DisconnectReason reason)
    {
        _router.SetNode(serial, null);
        foreach (var (probe, via) in _nodeBackfills.ToList())
        {
            if (via == serial)
            {
                Cancel(_backfills, probe);
                _nodeBackfills.Remove(probe);
            }
        }
        Cancel(_nodeForwarders, serial);
        if (_nodeLinks.Remove(serial, out var link))
        {
            // The forwarder may not have seen the final (disconnected) snapshot yet.
            _probes.Ingest(link.Snapshot);
        }
        return Task.CompletedTask;
    }

    public void Shutdown()
    {
        foreach (var c in _backfills.Values.Concat(_forwarders.Values).Concat(_nodeForwarders.Values))
        {
            c.Cancel();
        }
        _backfills.Clear();
        _forwarders.Clear();
        _nodeForwarders.Clear();
        _nodeBackfills.Clear();
    }

    public (ValueMap<ProbeSerial, UartDiagnostics>, ValueMap<ProbeSerial, int>) LinkCounters()
    {
        var uart = new Dictionary<ProbeSerial, UartDiagnostics>(_retiredUart);
        var decode = new Dictionary<ProbeSerial, int>(_retiredDecodeErrors);
        foreach (var (serial, link) in _links)
        {
            uart[serial] = Sum(uart.GetValueOrDefault(serial), link.Uart.Diagnostics);
            decode[serial] = decode.GetValueOrDefault(serial) + link.StatusDecodeErrors;
        }
        return (new ValueMap<ProbeSerial, UartDiagnostics>(uart), new ValueMap<ProbeSerial, int>(decode));
    }

    /// <summary>Fills holes while the link lives: retry soon while holes remain, otherwise re-check every minute
    /// (a live fetch can lose a record to a dropped notification).</summary>
    private async Task RunBackfillAsync(ProbeSerial serial, ILogFetcher fetcher, CancellationToken ct)
    {
        // Swift starts this in a new Task: let the caller finish first.
        await Task.Yield();
        var attempt = 0;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var complete = true;
                if (_history.CurrentSession(serial) is { } key)
                {
                    var result = await _history.BackfillAsync(key, fetcher, ct: ct);
                    complete = result.Remaining == 0 && !result.Failed;
                }
                TimeSpan wait;
                if (complete)
                {
                    attempt = 0;
                    wait = RecheckInterval;
                }
                else
                {
                    attempt++;
                    wait = TimeSpan.FromSeconds(Math.Min(2 * attempt, 30));
                }
                await _clock.SleepAsync(wait, ct);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    private static void Cancel<TKey>(Dictionary<TKey, CancellationTokenSource> map, TKey key)
        where TKey : notnull
    {
        if (map.Remove(key, out var cts))
        {
            cts.Cancel();
        }
    }

    private static UartDiagnostics Sum(UartDiagnostics? a, UartDiagnostics b)
    {
        var o = a ?? new UartDiagnostics();
        return o with
        {
            FramingErrors = o.FramingErrors + b.FramingErrors,
            IgnoredFrames = o.IgnoredFrames + b.IgnoredFrames,
            DuplicateResponses = o.DuplicateResponses + b.DuplicateResponses,
            CodecErrors = o.CodecErrors + b.CodecErrors,
        };
    }

    /// <summary>Swift raw values: requested, linkLost, timeout, bluetoothOff.</summary>
    internal static string ReasonName(DisconnectReason r) => char.ToLowerInvariant(r.ToString()[0]) + r.ToString()[1..];
}
