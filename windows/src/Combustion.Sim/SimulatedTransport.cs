namespace Combustion.Sim;

public sealed record SimulatedWrite(PeripheralId Peripheral, GattUuid Characteristic, byte[] Bytes)
{
    public bool Equals(SimulatedWrite? other) =>
        other is not null && Peripheral == other.Peripheral && Characteristic == other.Characteristic &&
        Bytes.AsSpan().SequenceEqual(other.Bytes);

    public override int GetHashCode() => HashCode.Combine(Peripheral, Characteristic, Bytes.Length);

    public override string ToString() => $"SimulatedWrite({Peripheral}, {Characteristic}, {HexString.Encode(Bytes)})";
}

/// <summary>
/// In-memory <see cref="IBleTransport"/> driven by an <see cref="IClock"/>. Confined to one
/// <see cref="SynchronizationContext"/> like the rest of Core (docs/02 §12), so it needs no locks and scripts are
/// synchronous.
/// <para>Behaviour notes:</para>
/// <list type="bullet">
/// <item>Advertisements are delivered only between <see cref="StartScanAsync"/> and <see cref="StopScanAsync"/>.</item>
/// <item>Leaving <see cref="BluetoothState.PoweredOn"/> drops every connection with <see cref="DisconnectReason.BluetoothOff"/>
/// and stops scanning.</item>
/// <item>Notifications are delivered only to connections that subscribed to the characteristic.</item>
/// <item>Replies produced by responders / replayed responses are emitted synchronously inside <c>WriteAsync</c> unless a
/// delay applies.</item>
/// </list>
/// </summary>
public sealed class SimulatedTransport : IBleTransport
{
    /// <summary>Returns the notifications that answer one write.</summary>
    public delegate IReadOnlyList<byte[]> Responder(byte[] write);

    public sealed record ReplayOptions
    {
        /// <summary>Notifications on these characteristics that directly follow a recorded write (in file order) are
        /// treated as its responses, not as timeline events.</summary>
        public IReadOnlySet<GattUuid> ResponseChars { get; init; } = new HashSet<GattUuid> { GattUuid.UartTx };

        /// <summary>Delay each replayed response by its recorded offset from the write.</summary>
        public bool UseRecordedResponseDelays { get; init; }
    }

    private sealed record ResponderEntry(PeripheralId? Peripheral, GattUuid Characteristic, GattUuid ReplyOn, Responder Handler);

    private sealed class Fault(GattUuid? characteristic, int remaining, int skip = 0)
    {
        public GattUuid? Characteristic { get; } = characteristic;

        public int Remaining { get; set; } = remaining;

        /// <summary>Matching notifications to let through before the fault starts.</summary>
        public int Skip { get; set; } = skip;
    }

    private sealed record RecordedResponse(TimeSpan Delay, GattUuid Characteristic, byte[] Bytes);

    private sealed class ReplayScript(ReplayOptions options)
    {
        public Dictionary<string, List<List<RecordedResponse>>> Responses { get; } = [];

        public Dictionary<string, int> Served { get; } = [];

        public ReplayOptions Options { get; } = options;
    }

    private readonly record struct Reply(TimeSpan Delay, GattUuid Characteristic, byte[] Bytes);

    private readonly IClock _clock;
    private readonly Broadcaster<BluetoothState> _stateBroadcast;
    private readonly Broadcaster<RawAdvertisement> _advBroadcast = new();

    private BluetoothState _currentState;
    private bool _scanning;
    private readonly Dictionary<PeripheralId, SimulatedConnection> _connections = [];
    private readonly List<ResponderEntry> _responders = [];
    private readonly List<Fault> _drops = [];
    private readonly List<Fault> _duplicates = [];
    private TimeSpan _responseDelay = TimeSpan.Zero;
    private TimeSpan _connectDelay = TimeSpan.Zero;
    private int _refusals;
    private readonly HashSet<PeripheralId> _blockedConnects = [];
    private TransportException? _refusalError;
    private readonly List<SimulatedWrite> _writeLog = [];
    private readonly Dictionary<string, byte[]> _readValues = [];
    private IWriteMatcher _matcher;
    private ReplayScript? _script;
    private int _mtu = 185;
    private IReadOnlyList<GattService> _profile =
    [
        new GattService(GattUuid.ProbeStatusService, [GattUuid.ProbeStatus]),
        new GattService(GattUuid.UartService, [GattUuid.UartRx, GattUuid.UartTx]),
        new GattService(GattUuid.DeviceInformationService,
            [GattUuid.ManufacturerName, GattUuid.ModelNumber, GattUuid.SerialNumber, GattUuid.HardwareRevision, GattUuid.FirmwareRevision]),
    ];

    public SimulatedTransport(IClock clock, BluetoothState state = BluetoothState.PoweredOn, IWriteMatcher? matcher = null)
    {
        _clock = clock;
        _currentState = state;
        _matcher = matcher ?? new MessageTypeWriteMatcher();
        _stateBroadcast = new Broadcaster<BluetoothState>(state, replayLatest: true);
    }

    // MARK: IBleTransport

    public AsyncStream<BluetoothState> State() => _stateBroadcast.Stream();

    public AsyncStream<RawAdvertisement> Advertisements() => _advBroadcast.Stream();

    public Task StartScanAsync()
    {
        _scanning = _currentState == BluetoothState.PoweredOn;
        return Task.CompletedTask;
    }

    public Task StopScanAsync()
    {
        _scanning = false;
        return Task.CompletedTask;
    }

    public async Task<IGattConnection> ConnectAsync(PeripheralId id, TimeSpan timeout, CancellationToken ct = default)
    {
        if (_currentState != BluetoothState.PoweredOn)
        {
            throw TransportException.NotPoweredOn(_currentState);
        }
        if (_connections.ContainsKey(id))
        {
            throw TransportException.AlreadyConnected(id);
        }
        if (_blockedConnects.Contains(id))
        {
            throw TransportException.ConnectionRefused(id);
        }
        if (_refusals > 0)
        {
            _refusals--;
            throw _refusalError ?? TransportException.ConnectionRefused(id);
        }
        var delay = _connectDelay;
        if (delay > TimeSpan.Zero)
        {
            if (delay > timeout)
            {
                await _clock.SleepAsync(timeout, ct);
                throw TransportException.Timeout();
            }
            await _clock.SleepAsync(delay, ct);
        }
        if (_currentState != BluetoothState.PoweredOn)
        {
            throw TransportException.NotPoweredOn(_currentState);
        }
        if (_connections.ContainsKey(id))
        {
            throw TransportException.AlreadyConnected(id);
        }
        var c = new SimulatedConnection(id, this, _mtu);
        _connections[id] = c;
        return c;
    }

    // MARK: Scripting

    public void SetState(BluetoothState state)
    {
        _currentState = state;
        SimulatedConnection[] dropped = [];
        if (state != BluetoothState.PoweredOn)
        {
            _scanning = false;
            dropped = [.. _connections.Values];
            _connections.Clear();
        }
        _stateBroadcast.Send(state);
        foreach (var c in dropped)
        {
            c.Terminate(DisconnectReason.BluetoothOff);
        }
    }

    public void InjectAdvertisement(PeripheralId peripheral, byte[] mfrData, int rssi = -50)
    {
        if (!_scanning)
        {
            return;
        }
        _advBroadcast.Send(new RawAdvertisement(peripheral, mfrData, rssi, _clock.Now()));
    }

    /// <summary>Delivers a notification to subscribers of <paramref name="characteristic"/> on <paramref name="peripheral"/>
    /// (subject to drop/duplicate faults).</summary>
    public void InjectNotification(PeripheralId peripheral, GattUuid characteristic, byte[] bytes)
    {
        var drop = _drops.FindIndex(f => f.Characteristic is null || f.Characteristic == characteristic);
        if (drop >= 0)
        {
            if (_drops[drop].Skip > 0)
            {
                _drops[drop].Skip--;
            }
            else
            {
                Consume(_drops, drop);
                return;
            }
        }
        var copies = 1;
        var dup = _duplicates.FindIndex(f => f.Characteristic is null || f.Characteristic == characteristic);
        if (dup >= 0)
        {
            Consume(_duplicates, dup);
            copies = 2;
        }
        if (!_connections.TryGetValue(peripheral, out var conn))
        {
            return;
        }
        for (var i = 0; i < copies; i++)
        {
            conn.Deliver(characteristic, bytes);
        }
    }

    public void ForceDisconnect(PeripheralId peripheral, DisconnectReason reason = DisconnectReason.LinkLost)
    {
        if (_connections.Remove(peripheral, out var c))
        {
            c.Terminate(reason);
        }
    }

    /// <summary>
    /// Answers writes to <paramref name="characteristic"/> (default UART RX) with notifications on
    /// <paramref name="replyOn"/> (default UART TX), one per returned element. Responders are tried in registration
    /// order; the first registered for a matching write wins.
    /// </summary>
    public void AddResponder(Responder handler, GattUuid? characteristic = null, GattUuid? replyOn = null, PeripheralId? peripheral = null)
    {
        _responders.Add(new ResponderEntry(peripheral, characteristic ?? GattUuid.UartRx, replyOn ?? GattUuid.UartTx, handler));
    }

    public void RemoveResponders() => _responders.Clear();

    public void SetReadValue(byte[] bytes, GattUuid characteristic, PeripheralId peripheral) =>
        _readValues[$"{peripheral}/{characteristic}"] = bytes;

    public void SetMtu(int mtu) => _mtu = mtu;

    public void SetGattProfile(IReadOnlyList<GattService> services) => _profile = services;

    public void SetWriteMatcher(IWriteMatcher matcher) => _matcher = matcher;

    /// <summary>Every write the app has made, in order.</summary>
    public IReadOnlyList<SimulatedWrite> Writes => [.. _writeLog];

    // MARK: Faults

    /// <summary>Silently drops the next <paramref name="count"/> notifications (optionally only on one characteristic),
    /// after letting <paramref name="after"/> matching notifications through (to lose records from the middle of a
    /// download).</summary>
    public void DropNextNotifications(int count = 1, int after = 0, GattUuid? on = null) =>
        _drops.Add(new Fault(on, count, after));

    /// <summary>Delivers each of the next <paramref name="count"/> notifications twice.</summary>
    public void DuplicateNextNotifications(int count = 1, GattUuid? on = null) => _duplicates.Add(new Fault(on, count));

    /// <summary>Replies to writes arrive this long (on the clock) after the write.</summary>
    public void SetResponseDelay(TimeSpan delay) => _responseDelay = delay;

    /// <summary><c>ConnectAsync</c> takes this long; longer than its timeout throws <c>Timeout</c>.</summary>
    public void SetConnectDelay(TimeSpan delay) => _connectDelay = delay;

    /// <summary>The next <paramref name="count"/> connects throw <paramref name="error"/> (default <c>ConnectionRefused</c>).</summary>
    public void RefuseConnects(int count = 1, TransportException? error = null)
    {
        _refusals = count;
        _refusalError = error;
    }

    /// <summary>Connects to <paramref name="peripheral"/> are refused until <see cref="AllowConnects"/>. Models a probe
    /// that is out of range.</summary>
    public void BlockConnects(PeripheralId peripheral) => _blockedConnects.Add(peripheral);

    public void AllowConnects(PeripheralId peripheral) => _blockedConnects.Remove(peripheral);

    /// <summary>True while a connection to <paramref name="peripheral"/> is open.</summary>
    public bool IsConnected(PeripheralId peripheral) => _connections.ContainsKey(peripheral);

    // MARK: Replay

    /// <summary>
    /// Plays <paramref name="events"/> on the clock, with <c>T</c> relative to now. Recorded <c>write</c> events become
    /// the response table; <c>connect</c> events are informational. Cancel <paramref name="ct"/> to stop. On a
    /// <see cref="TestClock"/>, call <c>AdvanceAsync</c>. The returned task completes when the timeline has played or
    /// was cancelled; it never faults.
    /// </summary>
    public Task StartReplay(IReadOnlyList<ReplayEvent> events, ReplayOptions? options = null, CancellationToken ct = default)
    {
        options ??= new ReplayOptions();
        var table = new ReplayScript(options);
        var timeline = new List<ReplayEvent>();
        var m = _matcher;
        (string Key, ReplayEvent Event, int Index)? lastWrite = null;
        foreach (var e in events)
        {
            var ch = new GattUuid(e.Char ?? "");
            switch (e.Type)
            {
                case ReplayEvent.Kind.Write:
                    var key = m.Key(ch, e.Bytes);
                    if (!table.Responses.TryGetValue(key, out var list))
                    {
                        list = [];
                        table.Responses[key] = list;
                    }
                    list.Add([]);
                    lastWrite = (key, e, list.Count - 1);
                    break;
                case ReplayEvent.Kind.Notify when lastWrite is { } w && options.ResponseChars.Contains(ch):
                    var r = new RecordedResponse(TimeSpan.FromSeconds(Math.Max(0, e.T - w.Event.T)), ch, e.Bytes);
                    table.Responses[w.Key][w.Index].Add(r);
                    break;
                case ReplayEvent.Kind.Connect:
                    lastWrite = null;
                    break;
                default:
                    lastWrite = null;
                    timeline.Add(e);
                    break;
            }
        }
        _script = table;
        return PlayTimeline(timeline, _clock.Monotonic(), ct);
    }

    private async Task PlayTimeline(List<ReplayEvent> timeline, TimeSpan origin, CancellationToken ct)
    {
        foreach (var e in timeline)
        {
            var wait = origin + TimeSpan.FromSeconds(e.T) - _clock.Monotonic();
            if (wait > TimeSpan.Zero)
            {
                try
                {
                    await _clock.SleepAsync(wait, ct);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
            if (ct.IsCancellationRequested)
            {
                return;
            }
            Play(e);
        }
    }

    private void Play(ReplayEvent e)
    {
        var peripheral = new PeripheralId(e.Peripheral ?? "");
        switch (e.Type)
        {
            case ReplayEvent.Kind.Adv:
                InjectAdvertisement(peripheral, e.Bytes, e.Rssi ?? -50);
                break;
            case ReplayEvent.Kind.Notify:
                InjectNotification(peripheral, new GattUuid(e.Char ?? ""), e.Bytes);
                break;
            case ReplayEvent.Kind.Disconnect:
                ForceDisconnect(peripheral);
                break;
            case ReplayEvent.Kind.State:
                SetState(BluetoothStateNames.Parse(e.State) ?? BluetoothState.PoweredOn);
                break;
            default:
                break;
        }
    }

    // MARK: Internals used by SimulatedConnection

    private static void Consume(List<Fault> faults, int i)
    {
        faults[i].Remaining--;
        if (faults[i].Remaining <= 0)
        {
            faults.RemoveAt(i);
        }
    }

    internal void ConnectionClosed(PeripheralId id, SimulatedConnection connection)
    {
        if (_connections.TryGetValue(id, out var c) && ReferenceEquals(c, connection))
        {
            _connections.Remove(id);
        }
    }

    internal byte[]? ReadValue(PeripheralId peripheral, GattUuid characteristic) =>
        _readValues.TryGetValue($"{peripheral}/{characteristic}", out var v) ? v : null;

    internal IReadOnlyList<GattService> GattProfile() => _profile;

    internal void HandleWrite(PeripheralId peripheral, GattUuid characteristic, byte[] bytes)
    {
        var replies = Replies(peripheral, characteristic, bytes);
        if (replies.Count == 0)
        {
            return;
        }
        foreach (var r in replies.Where(r => r.Delay <= TimeSpan.Zero))
        {
            InjectNotification(peripheral, r.Characteristic, r.Bytes);
        }
        var later = replies.Where(r => r.Delay > TimeSpan.Zero).ToList();
        if (later.Count > 0)
        {
            _ = DeliverLater(peripheral, later);
        }
    }

    private List<Reply> Replies(PeripheralId peripheral, GattUuid characteristic, byte[] bytes)
    {
        _writeLog.Add(new SimulatedWrite(peripheral, characteristic, bytes));
        var extra = _responseDelay;
        if (_responders.FirstOrDefault(r => r.Characteristic == characteristic && (r.Peripheral is null || r.Peripheral == peripheral)) is { } responder)
        {
            return responder.Handler(bytes).Select(b => new Reply(extra, responder.ReplyOn, b)).ToList();
        }
        if (_script is not { } s)
        {
            return [];
        }
        var key = _matcher.Key(characteristic, bytes);
        if (!s.Responses.TryGetValue(key, out var recorded) || recorded.Count == 0)
        {
            return [];
        }
        var n = s.Served.GetValueOrDefault(key);
        s.Served[key] = n + 1;
        // Serve recordings in order; the last one repeats.
        return recorded[Math.Min(n, recorded.Count - 1)]
            .Select(r => new Reply(extra + (s.Options.UseRecordedResponseDelays ? r.Delay : TimeSpan.Zero), r.Characteristic, r.Bytes))
            .ToList();
    }

    private async Task DeliverLater(PeripheralId peripheral, List<Reply> later)
    {
        var elapsed = TimeSpan.Zero;
        foreach (var r in later)
        {
            if (r.Delay > elapsed)
            {
                await _clock.SleepAsync(r.Delay - elapsed);
                elapsed = r.Delay;
            }
            InjectNotification(peripheral, r.Characteristic, r.Bytes);
        }
    }
}

internal sealed class SimulatedConnection : IGattConnection
{
    private readonly SimulatedTransport _transport;
    private readonly Dictionary<GattUuid, Broadcaster<byte[]>> _subscribers = [];
    private readonly Broadcaster<DisconnectReason> _disconnectBroadcast = new(replayLatest: true);
    private bool _open = true;

    public SimulatedConnection(PeripheralId peripheral, SimulatedTransport transport, int mtu)
    {
        Peripheral = peripheral;
        _transport = transport;
        Mtu = mtu;
    }

    public PeripheralId Peripheral { get; }

    public int Mtu { get; }

    public AsyncStream<DisconnectReason> Disconnected() => _disconnectBroadcast.Stream();

    private Exception? Closed() => _open ? null : TransportException.Disconnected();

    public Task<IReadOnlyList<GattService>> DiscoverAsync(CancellationToken ct = default) =>
        Closed() is { } e ? Task.FromException<IReadOnlyList<GattService>>(e) : Task.FromResult(_transport.GattProfile());

    public Task<byte[]> ReadAsync(GattUuid characteristic, CancellationToken ct = default)
    {
        if (Closed() is { } e)
        {
            return Task.FromException<byte[]>(e);
        }
        return _transport.ReadValue(Peripheral, characteristic) is { } v
            ? Task.FromResult(v)
            : Task.FromException<byte[]>(TransportException.CharacteristicNotFound(characteristic));
    }

    public Task WriteAsync(GattUuid characteristic, byte[] bytes, bool withResponse, CancellationToken ct = default)
    {
        if (Closed() is { } e)
        {
            return Task.FromException(e);
        }
        _transport.HandleWrite(Peripheral, characteristic, bytes);
        return Task.CompletedTask;
    }

    public Task<AsyncStream<byte[]>> SubscribeAsync(GattUuid characteristic, CancellationToken ct = default)
    {
        if (Closed() is { } e)
        {
            return Task.FromException<AsyncStream<byte[]>>(e);
        }
        if (!_subscribers.TryGetValue(characteristic, out var b))
        {
            b = new Broadcaster<byte[]>();
            _subscribers[characteristic] = b;
        }
        return Task.FromResult(b.Stream());
    }

    internal void Deliver(GattUuid characteristic, byte[] bytes)
    {
        if (_open && _subscribers.TryGetValue(characteristic, out var b))
        {
            b.Send(bytes);
        }
    }

    public Task CloseAsync()
    {
        _transport.ConnectionClosed(Peripheral, this);
        Terminate(DisconnectReason.Requested);
        return Task.CompletedTask;
    }

    internal void Terminate(DisconnectReason reason)
    {
        if (!_open)
        {
            return;
        }
        _open = false;
        foreach (var b in _subscribers.Values.ToList())
        {
            b.Finish();
        }
        _disconnectBroadcast.Send(reason);
        _disconnectBroadcast.Finish();
    }
}
