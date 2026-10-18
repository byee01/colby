using Combustion.Codec;

namespace Combustion.Core;

/// <summary>Where one followed probe stands in the connection lifecycle (diagnostics and tests).</summary>
public abstract record ProbeConnectionState
{
    private ProbeConnectionState() { }

    /// <summary>Followed, but its own advertisement has not been heard yet.</summary>
    public sealed record WaitingForAdvertisement : ProbeConnectionState;

    public sealed record Connecting(int Attempt) : ProbeConnectionState;

    public sealed record Connected : ProbeConnectionState;

    /// <summary>A connect failed or the link dropped; the next attempt is at <c>RetryAt</c> (clock monotonic time).</summary>
    public sealed record Backoff(int Attempt, TimeSpan RetryAt) : ProbeConnectionState;

    /// <summary>Absent from advertisements for the give-up interval. Resumes when it advertises again.</summary>
    public sealed record GaveUp : ProbeConnectionState;

    /// <summary>A connected MeatNet node covers this probe, so no direct connection is held (probe slots stay free).</summary>
    public sealed record ViaNode(string Node) : ProbeConnectionState;

    public static readonly ProbeConnectionState Waiting = new WaitingForAdvertisement();
    public static readonly ProbeConnectionState IsConnected = new Connected();
    public static readonly ProbeConnectionState HasGivenUp = new GaveUp();
}

/// <summary>Receives the links a policy creates. All calls for one probe are sequential.
/// Node methods have default no-op implementations.</summary>
public interface IConnectionPolicyDelegate
{
    /// <summary>A link object exists but has not started. Subscribe to its streams here so nothing is missed.</summary>
    Task LinkCreatedAsync(DirectProbeLink link);

    /// <summary>The link is started (discovered, UART ready, subscribed to Probe Status).</summary>
    Task LinkEstablishedAsync(DirectProbeLink link);

    /// <summary>The link is gone (dropped, closed on unfollow, or closed by <c>Stop</c>).</summary>
    Task LinkEndedAsync(ProbeSerial serial, DisconnectReason reason);

    Task NodeLinkCreatedAsync(NodeLink link) => Task.CompletedTask;

    Task NodeLinkEstablishedAsync(NodeLink link) => Task.CompletedTask;

    Task NodeLinkEndedAsync(string serial, DisconnectReason reason) => Task.CompletedTask;
}

/// <summary>Everything a policy needs from the app.</summary>
/// <param name="Sightings">Probes heard on their own peripheral (<c>AdvertisementSource.ProbeSightings</c>).</param>
/// <param name="Followed">The followed set; current value first (<c>ProbeStore.Followed</c>).</param>
/// <param name="NodeSightings">MeatNet nodes heard on their own peripheral (<c>AdvertisementSource.NodeSightings</c>).</param>
/// <param name="RepeatedSightings">Probes heard through a node (<c>AdvertisementSource.RepeatedSightings</c>).</param>
public sealed record ConnectionPolicyInput(
    IBleTransport Transport,
    IClock Clock,
    IAsyncEnumerable<ProbeSighting> Sightings,
    IAsyncEnumerable<ValueSet<ProbeSerial>> Followed,
    IConnectionPolicyDelegate Delegate,
    IAsyncEnumerable<NodeSighting>? NodeSightings = null,
    IAsyncEnumerable<RepeatedProbeSighting>? RepeatedSightings = null);

/// <summary>Decides what to connect to (docs/02 §5.6). Replaceable so it can be tuned without touching links.</summary>
public interface IConnectionPolicy
{
    Task StartAsync(ConnectionPolicyInput input);

    /// <summary>Closes every link and ends all work.</summary>
    Task StopAsync();

    IReadOnlyDictionary<ProbeSerial, ProbeConnectionState> States();

    /// <summary>Connection state of each node the policy is working on (diagnostics). Empty for policies without nodes.</summary>
    IReadOnlyDictionary<string, ProbeConnectionState> NodeStates();
}

/// <summary>
/// Default policy (docs/02 §5.6):
/// <list type="number">
/// <item>Scanning is the app's job (always on); this policy reacts to what the scan hears.</item>
/// <item>MeatNet node step: when a node repeats the advertisement of a followed probe, connect to the node
/// (one connection gets every probe on its network and keeps probe slots free for the phone app).
/// While a node is connected and covers a probe, that probe gets no direct connection, and an existing
/// one is closed. A node whose first connect attempt is still under way holds direct connects back.</item>
/// <item>Otherwise connect directly to each followed probe once its own advertisement has been heard. If the
/// node link drops (or stops repeating the probe) the probe falls back to direct, starting from the initial backoff.</item>
/// <item>Reconnect with backoff 1, 2, 4 ... 30 s, for probes and nodes alike. Give up on a probe when it has
/// been absent from advertisements for 5 min (absence counts from the later of the last advertisement
/// and the end of the last link); resume as soon as it advertises again. A node is left alone once no
/// followed probe is heard through it.</item>
/// <item>At most one connection per probe: one supervisor task per followed probe, and one per node.</item>
/// </list>
/// </summary>
public sealed class DirectConnectionPolicy : IConnectionPolicy
{
    public sealed record Timing
    {
        public TimeSpan InitialBackoff { get; init; } = TimeSpan.FromSeconds(1);
        public TimeSpan MaxBackoff { get; init; } = TimeSpan.FromSeconds(30);
        public TimeSpan AbsentLimit { get; init; } = TimeSpan.FromSeconds(300);
        public TimeSpan ConnectTimeout { get; init; } = TimeSpan.FromSeconds(10);
        /// <summary>A link that lasted this long counts as healthy: the next reconnect starts from <c>InitialBackoff</c>.</summary>
        public TimeSpan StableAfter { get; init; } = TimeSpan.FromSeconds(10);
        /// <summary>How often a probe supervisor re-checks whether a node covers it.</summary>
        public TimeSpan CoverageCheck { get; init; } = TimeSpan.FromSeconds(1);
        /// <summary>A probe counts as heard through a node for this long after the node's last repeated advertisement.</summary>
        public TimeSpan ViaNodeFresh { get; init; } = TimeSpan.FromSeconds(15);
    }

    private readonly record struct NodeInfo(PeripheralId Peripheral, NodeProductType ProductType);

    private sealed class Supervisor(CancellationTokenSource cts)
    {
        public CancellationTokenSource Cts { get; } = cts;
        public Task Task { get; set; } = Task.CompletedTask;
    }

    private readonly Timing _timing;
    private ConnectionPolicyInput? _input;
    private CancellationTokenSource? _background;
    private readonly List<Task> _backgroundTasks = [];
    private readonly Dictionary<ProbeSerial, Supervisor> _supervisors = [];
    private readonly Dictionary<ProbeSerial, PeripheralId> _peripherals = [];
    private readonly Dictionary<ProbeSerial, TimeSpan> _lastSeen = [];
    private readonly Dictionary<ProbeSerial, ProbeConnectionState> _stateByProbe = [];
    private readonly Dictionary<ProbeSerial, List<TaskCompletionSource>> _waiters = [];

    private HashSet<ProbeSerial> _followed = [];
    private readonly Dictionary<string, NodeInfo> _nodes = [];
    /// <summary>When each followed probe was last repeated by each node peripheral (monotonic).</summary>
    private readonly Dictionary<ProbeSerial, Dictionary<PeripheralId, TimeSpan>> _viaNode = [];
    private readonly Dictionary<string, Supervisor> _nodeSupervisors = [];
    private readonly Dictionary<string, ProbeConnectionState> _stateByNode = [];

    public DirectConnectionPolicy(Timing? timing = null)
    {
        _timing = timing ?? new Timing();
    }

    public IReadOnlyDictionary<ProbeSerial, ProbeConnectionState> States() => new Dictionary<ProbeSerial, ProbeConnectionState>(_stateByProbe);

    public IReadOnlyDictionary<string, ProbeConnectionState> NodeStates() => new Dictionary<string, ProbeConnectionState>(_stateByNode);

    public Task StartAsync(ConnectionPolicyInput input)
    {
        if (_input is not null)
        {
            return Task.CompletedTask;
        }
        _input = input;
        _background = new CancellationTokenSource();
        var ct = _background.Token;
        _backgroundTasks.Add(input.Sightings.ForEachAsync(NoteSighting, ct));
        _backgroundTasks.Add(input.Followed.ForEachAsync(Reconcile, ct));
        if (input.NodeSightings is { } nodes)
        {
            _backgroundTasks.Add(nodes.ForEachAsync(NoteNode, ct));
        }
        if (input.RepeatedSightings is { } repeated)
        {
            _backgroundTasks.Add(repeated.ForEachAsync(NoteRepeated, ct));
        }
        return Task.CompletedTask;
    }

    public async Task StopAsync()
    {
        var all = _backgroundTasks.ToList();
        var cancels = new List<CancellationTokenSource>();
        if (_background is not null)
        {
            cancels.Add(_background);
        }
        foreach (var s in _supervisors.Values.Concat(_nodeSupervisors.Values))
        {
            all.Add(s.Task);
            cancels.Add(s.Cts);
        }
        _backgroundTasks.Clear();
        _background = null;
        _supervisors.Clear();
        _nodeSupervisors.Clear();
        _input = null;
        foreach (var c in cancels)
        {
            c.Cancel();
        }
        foreach (var t in all)
        {
            try
            {
                await t;
            }
            catch (OperationCanceledException)
            {
            }
        }
        _stateByProbe.Clear();
        _stateByNode.Clear();
    }

    // Inputs

    private void NoteSighting(ProbeSighting s)
    {
        if (_input is not { } input)
        {
            return;
        }
        _peripherals[s.Serial] = s.Peripheral;
        _lastSeen[s.Serial] = input.Clock.Monotonic();
        if (_waiters.Remove(s.Serial, out var ws))
        {
            foreach (var w in ws)
            {
                w.TrySetResult();
            }
        }
    }

    private void Reconcile(ValueSet<ProbeSerial> followed)
    {
        if (_input is null)
        {
            return;
        }
        _followed = [.. followed];
        foreach (var serial in followed)
        {
            if (!_supervisors.ContainsKey(serial))
            {
                _stateByProbe[serial] = ProbeConnectionState.Waiting;
                var sup = new Supervisor(new CancellationTokenSource());
                _supervisors[serial] = sup;
                sup.Task = SuperviseAsync(serial, sup.Cts.Token);
            }
        }
        foreach (var serial in _supervisors.Keys.ToList())
        {
            if (!followed.Contains(serial))
            {
                _supervisors.Remove(serial, out var sup);
                sup!.Cts.Cancel();
                _stateByProbe.Remove(serial);
            }
        }
        // A node no followed probe is heard through has nothing to do for us.
        foreach (var serial in _nodeSupervisors.Keys.ToList())
        {
            if (!NodeHearsFollowed(serial))
            {
                _nodeSupervisors.Remove(serial, out var sup);
                sup!.Cts.Cancel();
                _stateByNode.Remove(serial);
            }
        }
        EvaluateNodes();
    }

    private void NoteNode(NodeSighting s)
    {
        _nodes[s.Serial] = new NodeInfo(s.Peripheral, s.ProductType);
        EvaluateNodes();
    }

    private void NoteRepeated(RepeatedProbeSighting s)
    {
        if (_input is not { } input || !_followed.Contains(s.Serial))
        {
            return;
        }
        if (!_viaNode.TryGetValue(s.Serial, out var heard))
        {
            heard = [];
            _viaNode[s.Serial] = heard;
        }
        heard[s.NodePeripheral] = input.Clock.Monotonic();
        EvaluateNodes();
    }

    /// <summary>Suspends until the next sighting of <paramref name="serial"/> (or cancellation; then it returns normally).</summary>
    private async Task WaitForSightingAsync(ProbeSerial serial, CancellationToken ct)
    {
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (!_waiters.TryGetValue(serial, out var list))
        {
            list = [];
            _waiters[serial] = list;
        }
        list.Add(tcs);
        using var reg = ct.Register(() => tcs.TrySetResult());
        await tcs.Task;
        if (_waiters.TryGetValue(serial, out var current))
        {
            current.Remove(tcs);
        }
    }

    private void Set(ProbeSerial serial, ProbeConnectionState state)
    {
        if (!_supervisors.ContainsKey(serial))
        {
            return;
        }
        _stateByProbe[serial] = state;
        EvaluateNodes();
    }

    // Per-probe supervisor

    private async Task SuperviseAsync(ProbeSerial serial, CancellationToken ct)
    {
        // Run after Reconcile has registered this supervisor (Swift starts it in a new Task).
        await Task.Yield();
        if (_input is not { } input)
        {
            return;
        }
        var clock = input.Clock;
        var attempt = 0;
        var backoff = _timing.InitialBackoff;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                // Node first: no direct connection while a node covers the probe (or is about to).
                if (CoveringNode(serial) is { } node)
                {
                    Set(serial, new ProbeConnectionState.ViaNode(node));
                    attempt = 0;
                    backoff = _timing.InitialBackoff;
                    await clock.SleepAsync(_timing.CoverageCheck, ct);
                    continue;
                }
                if (NodePending(serial))
                {
                    Set(serial, ProbeConnectionState.Waiting);
                    await clock.SleepAsync(_timing.CoverageCheck, ct);
                    continue;
                }
                if (!_peripherals.TryGetValue(serial, out var peripheral) || !_lastSeen.TryGetValue(serial, out var seen))
                {
                    Set(serial, ProbeConnectionState.Waiting);
                    await WaitForSightingAsync(serial, ct);
                    attempt = 0;
                    backoff = _timing.InitialBackoff;
                    continue;
                }
                if (clock.Monotonic() - seen >= _timing.AbsentLimit)
                {
                    Set(serial, ProbeConnectionState.HasGivenUp);
                    await WaitForSightingAsync(serial, ct);
                    attempt = 0;
                    backoff = _timing.InitialBackoff;
                    continue;
                }

                attempt++;
                Set(serial, new ProbeConnectionState.Connecting(attempt));
                var startedAt = clock.Monotonic();
                if (await ConnectAndRunAsync(serial, peripheral, input, ct) is { } ended)
                {
                    _lastSeen[serial] = _lastSeen.TryGetValue(serial, out var last) && last > ended ? last : ended;
                    if (ended - startedAt >= _timing.StableAfter)
                    {
                        attempt = 0;
                        backoff = _timing.InitialBackoff;
                    }
                }
                if (ct.IsCancellationRequested)
                {
                    return;
                }
                if (CoveringNode(serial) is not null)
                {
                    continue; // closed because a node took over: no backoff
                }

                // Wait out the backoff, but never past the give-up deadline.
                var now = clock.Monotonic();
                var deadline = (_lastSeen.TryGetValue(serial, out var ls) ? ls : now) + _timing.AbsentLimit;
                var wait = backoff < deadline - now ? backoff : deadline - now;
                backoff = backoff * 2 < _timing.MaxBackoff ? backoff * 2 : _timing.MaxBackoff;
                if (wait <= TimeSpan.Zero)
                {
                    continue;
                }
                Set(serial, new ProbeConnectionState.Backoff(attempt, now + wait));
                await clock.SleepAsync(wait, ct);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>One connection attempt and, if it succeeds, the life of the link. Returns the monotonic time the
    /// link ended, or null if no link was established.</summary>
    private async Task<TimeSpan?> ConnectAndRunAsync(ProbeSerial serial, PeripheralId peripheral, ConnectionPolicyInput input, CancellationToken ct)
    {
        IGattConnection connection;
        try
        {
            connection = await input.Transport.ConnectAsync(peripheral, _timing.ConnectTimeout, ct);
        }
        catch (Exception)
        {
            return null;
        }
        var link = new DirectProbeLink(serial, connection, input.Clock);
        await input.Delegate.LinkCreatedAsync(link);
        var drops = link.Disconnected();
        try
        {
            await link.StartAsync();
        }
        catch (Exception)
        {
            await link.CloseAsync();
            await input.Delegate.LinkEndedAsync(serial, DisconnectReason.Requested);
            return null;
        }
        Set(serial, ProbeConnectionState.IsConnected);
        await input.Delegate.LinkEstablishedAsync(link);
        // Ends when the link drops, or when a node connects and covers this probe (we close the link then).
        using var race = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var dropTask = FirstReasonAsync(drops, race.Token);
        var coverTask = WaitForCoverAsync(serial, input.Clock, race.Token);
        var first = await Task.WhenAny(dropTask, coverTask);
        race.Cancel();
        DisconnectReason? dropped = first == dropTask && dropTask.IsCompletedSuccessfully ? dropTask.Result : null;
        await link.CloseAsync();
        var reason = dropped ?? DisconnectReason.Requested;
        if (ct.IsCancellationRequested)
        {
            reason = DisconnectReason.Requested;
        }
        await input.Delegate.LinkEndedAsync(serial, reason);
        return input.Clock.Monotonic();
    }

    private static async Task<DisconnectReason?> FirstReasonAsync(AsyncStream<DisconnectReason> drops, CancellationToken ct)
    {
        try
        {
            await foreach (var r in drops.WithCancellation(ct))
            {
                return r;
            }
            return DisconnectReason.LinkLost;
        }
        catch (OperationCanceledException)
        {
            return null;
        }
    }

    private async Task WaitForCoverAsync(ProbeSerial serial, IClock clock, CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (CoveringNode(serial) is not null)
                {
                    return;
                }
                await clock.SleepAsync(_timing.CoverageCheck, ct);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    // MeatNet node step

    /// <summary>Followed probes heard through <paramref name="serial"/> (its peripheral repeated them within <c>ViaNodeFresh</c>).</summary>
    private List<ProbeSerial> FollowedViaNode(string serial)
    {
        if (_input is not { } input || !_nodes.TryGetValue(serial, out var node))
        {
            return [];
        }
        var now = input.Clock.Monotonic();
        return _followed.Where(p => _viaNode.TryGetValue(p, out var heard) && heard.TryGetValue(node.Peripheral, out var seen) && now - seen < _timing.ViaNodeFresh).ToList();
    }

    private bool NodeHearsFollowed(string serial) => FollowedViaNode(serial).Count > 0;

    /// <summary>A connected node that repeats <paramref name="probe"/> right now.</summary>
    private string? CoveringNode(ProbeSerial probe) =>
        NodesHearing(probe).FirstOrDefault(n => _stateByNode.GetValueOrDefault(n) is ProbeConnectionState.Connected);

    /// <summary>A node that repeats <paramref name="probe"/> is waiting to connect or on its first attempt.</summary>
    private bool NodePending(ProbeSerial probe) =>
        NodesHearing(probe).Any(n => _stateByNode.GetValueOrDefault(n) is ProbeConnectionState.WaitingForAdvertisement or ProbeConnectionState.Connecting { Attempt: 1 });

    private List<string> NodesHearing(ProbeSerial probe)
    {
        if (_input is not { } input || !_viaNode.TryGetValue(probe, out var heard))
        {
            return [];
        }
        var now = input.Clock.Monotonic();
        return _nodes.Where(kv => heard.TryGetValue(kv.Value.Peripheral, out var t) && now - t < _timing.ViaNodeFresh)
            .Select(kv => kv.Key).Order(StringComparer.Ordinal).ToList();
    }

    /// <summary>A followed probe is heard through the node: worth a connection.</summary>
    private bool NodeWanted(string serial) => NodeHearsFollowed(serial);

    /// <summary>Starts a supervisor for every node that is wanted and has none. Cheap; called on every input.</summary>
    private void EvaluateNodes()
    {
        if (_input is null)
        {
            return;
        }
        foreach (var serial in _nodes.Keys.ToList())
        {
            if (!_nodeSupervisors.ContainsKey(serial) && NodeWanted(serial))
            {
                _stateByNode[serial] = new ProbeConnectionState.Connecting(1);
                var sup = new Supervisor(new CancellationTokenSource());
                _nodeSupervisors[serial] = sup;
                sup.Task = SuperviseNodeAsync(serial, sup, sup.Cts.Token);
            }
        }
    }

    private void SetNode(string serial, ProbeConnectionState state)
    {
        if (_nodeSupervisors.ContainsKey(serial))
        {
            _stateByNode[serial] = state;
        }
    }

    /// <summary>Same retry shape as <see cref="SuperviseAsync"/>. Ends (and is restarted by <see cref="EvaluateNodes"/>) once no
    /// followed probe needs the node, so there is no give-up timer: the repeated advertisements stopping is the signal.</summary>
    private async Task SuperviseNodeAsync(string serial, Supervisor self, CancellationToken ct)
    {
        await Task.Yield();
        if (_input is not { } input)
        {
            return;
        }
        var clock = input.Clock;
        var attempt = 0;
        var backoff = _timing.InitialBackoff;
        try
        {
            while (!ct.IsCancellationRequested)
            {
                if (!NodeWanted(serial) || !_nodes.TryGetValue(serial, out var node))
                {
                    if (_nodeSupervisors.GetValueOrDefault(serial) == self)
                    {
                        _nodeSupervisors.Remove(serial);
                        _stateByNode.Remove(serial);
                    }
                    return;
                }
                attempt++;
                SetNode(serial, new ProbeConnectionState.Connecting(attempt));
                var startedAt = clock.Monotonic();
                if (await ConnectAndRunNodeAsync(serial, node, input, ct) is { } ended && ended - startedAt >= _timing.StableAfter)
                {
                    attempt = 0;
                    backoff = _timing.InitialBackoff;
                }
                if (ct.IsCancellationRequested)
                {
                    return;
                }
                var wait = backoff;
                backoff = backoff * 2 < _timing.MaxBackoff ? backoff * 2 : _timing.MaxBackoff;
                SetNode(serial, new ProbeConnectionState.Backoff(attempt, clock.Monotonic() + wait));
                await clock.SleepAsync(wait, ct);
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>One connection attempt to a node and, if it succeeds, the life of the link. Returns the monotonic
    /// time the link ended, or null if no link was established.</summary>
    private async Task<TimeSpan?> ConnectAndRunNodeAsync(string serial, NodeInfo node, ConnectionPolicyInput input, CancellationToken ct)
    {
        IGattConnection connection;
        try
        {
            connection = await input.Transport.ConnectAsync(node.Peripheral, _timing.ConnectTimeout, ct);
        }
        catch (Exception)
        {
            return null;
        }
        var link = new NodeLink(serial, node.ProductType, connection, input.Clock);
        await input.Delegate.NodeLinkCreatedAsync(link);
        var drops = link.Disconnected();
        try
        {
            await link.StartAsync();
        }
        catch (Exception)
        {
            await link.CloseAsync();
            await input.Delegate.NodeLinkEndedAsync(serial, DisconnectReason.Requested);
            return null;
        }
        SetNode(serial, ProbeConnectionState.IsConnected);
        await input.Delegate.NodeLinkEstablishedAsync(link);
        var reason = await FirstReasonAsync(drops, ct) ?? DisconnectReason.Requested;
        await link.CloseAsync();
        if (ct.IsCancellationRequested)
        {
            reason = DisconnectReason.Requested;
        }
        await input.Delegate.NodeLinkEndedAsync(serial, reason);
        return input.Clock.Monotonic();
    }
}
