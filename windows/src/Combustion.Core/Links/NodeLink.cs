using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// One MeatNet node (Display, Booster, ...) connected over GATT (docs/02 §5.4).
/// Owns a node-variant <see cref="UartClient"/>. The node pushes 0x45 Probe Status for every probe on its network;
/// each becomes a <c>ProbeObservation(Status)</c> with source <c>NodeConnection</c> (<c>Via</c> = this node, <c>HopCount</c>
/// from the Network Information byte). 0x49 heartbeats feed the node's <see cref="NodeSnapshot"/>. Requests for a
/// probe (history, session info) are addressed by probe serial, so one connection serves every probe the node relays.
/// <para>
/// The 94 B status inside 0x45 (probe fw v2.3.3) has no session fields. As <see cref="DirectProbeLink"/> does, the link
/// reads Session Info for each probe on its first such status, through this node, and fills it into later
/// statuses; a log range that goes backwards drops that probe's cached info and reads it again.
/// </para>
/// </summary>
public sealed class NodeLink : ILogFetcher
{
    /// <summary>A probe counts as relayed by this node for this long after its last 0x45.</summary>
    public static readonly TimeSpan CoverageTtl = TimeSpan.FromSeconds(10);

    private readonly IGattConnection _connection;
    private readonly IClock _clock;
    private readonly Coverage _coverage = new();
    private readonly Broadcaster<ProbeObservation> _observations = new();
    private readonly Broadcaster<NodeSnapshot> _snapshots;
    private readonly Broadcaster<DisconnectReason> _disconnect = new(replayLatest: true);
    private readonly CancellationTokenSource _tasks = new();
    private NodeSnapshot _current;
    private bool _started;
    private bool _finished;
    private readonly Dictionary<ProbeSerial, ProbeSession> _sessions = [];

    private sealed class ProbeSession
    {
        public SessionInfo? Info { get; set; }
        public bool Reading { get; set; }
        public bool Refused { get; set; }
        public uint? LastLogMax { get; set; }
    }

    /// <param name="requestIds">Source of request IDs; inject a deterministic one in tests.</param>
    public NodeLink(string serial, NodeProductType productType, IGattConnection connection, IClock clock, Func<uint>? requestIds = null)
    {
        Serial = serial;
        ProductType = productType;
        _connection = connection;
        _clock = clock;
        Uart = new UartClient(UartVariant.Node, connection, clock, requestIds);
        _current = new NodeSnapshot(serial, productType, new LinkSource(LinkKind.NodeAdvertisement, clock.Now()));
        _snapshots = new Broadcaster<NodeSnapshot>(_current);
    }

    public string Serial { get; }

    public NodeProductType ProductType { get; }

    public UartClient Uart { get; }

    /// <summary>Probe statuses relayed by the node.</summary>
    public AsyncStream<ProbeObservation> Observations() => _observations.Stream();

    /// <summary>The node's own state; current value first, then each change. The last one has <c>IsConnected == false</c>.</summary>
    public AsyncStream<NodeSnapshot> Snapshots() => _snapshots.Stream();

    /// <summary>Yields the reason once (late subscribers still get it), then finishes.</summary>
    public AsyncStream<DisconnectReason> Disconnected() => _disconnect.Stream();

    public NodeSnapshot Snapshot => _current;

    /// <summary>0x45 messages the codec rejected.</summary>
    public int StatusDecodeErrors { get; private set; }

    /// <summary>Payload of the latest heartbeat, undecoded (the topology layout is not in our spec digest).</summary>
    public byte[]? LastHeartbeatPayload { get; private set; }

    // Lifecycle

    /// <summary>Discovers services, starts the UART client and begins routing 0x45 / 0x49. Device Information is
    /// read in the background (best effort). On failure the link is torn down and the error rethrown.</summary>
    public async Task StartAsync()
    {
        if (_started)
        {
            return;
        }
        _started = true;
        _ = WatchDisconnectAsync(_connection.Disconnected(), _tasks.Token);
        try
        {
            var services = await _connection.DiscoverAsync();
            var known = services.SelectMany(s => s.Characteristics).ToHashSet();
            foreach (var needed in new[] { GattUuid.UartRx, GattUuid.UartTx })
            {
                if (!known.Contains(needed))
                {
                    throw TransportException.CharacteristicNotFound(needed);
                }
            }
            // Subscribe before starting the client so no early frame is missed.
            var frames = Uart.Unsolicited();
            await Uart.StartAsync();
            _ = frames.ForEachAsync(Handle, _tasks.Token);
        }
        catch
        {
            await _connection.CloseAsync();
            Finish(DisconnectReason.Requested);
            throw;
        }
        _current = _current with { IsConnected = true, Link = new LinkSource(LinkKind.DirectConnection, _clock.Now()) };
        Publish();
        _ = LoadDeviceInfoAsync();
    }

    private async Task WatchDisconnectAsync(AsyncStream<DisconnectReason> drops, CancellationToken ct)
    {
        try
        {
            await foreach (var reason in drops.WithCancellation(ct))
            {
                Finish(reason);
                return;
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        Finish(DisconnectReason.LinkLost);
    }

    /// <summary>Closes the connection and ends all streams.</summary>
    public async Task CloseAsync()
    {
        await _connection.CloseAsync();
        Finish(DisconnectReason.Requested);
    }

    private void Finish(DisconnectReason reason)
    {
        if (_finished)
        {
            return;
        }
        _finished = true;
        _tasks.Cancel();
        _sessions.Clear();
        Uart.Close();
        _coverage.Clear();
        _current = _current with
        {
            IsConnected = false,
            Link = new LinkSource(LinkKind.NodeAdvertisement, _clock.Now()),
            Probes = ValueList<ProbeSerial>.Empty,
            HopCounts = ValueMap<ProbeSerial, int>.Empty,
        };
        _snapshots.Send(_current);
        _snapshots.Finish();
        _observations.Finish();
        _disconnect.Send(reason);
        _disconnect.Finish();
    }

    // Receiving

    private void Handle(UartFrame frame)
    {
        if (_finished)
        {
            return;
        }
        switch (frame.MessageType)
        {
            case UartMessageType.ProbeStatus:
                HandleProbeStatus(frame.Payload);
                break;
            case UartMessageType.Heartbeat:
                HandleHeartbeat(frame.Payload);
                break;
        }
    }

    private void HandleProbeStatus(byte[] payload)
    {
        NodeProbeStatus node;
        try
        {
            node = CombustionCodec.DecodeNodeProbeStatus(payload);
        }
        catch (CodecException)
        {
            StatusDecodeErrors++;
            return;
        }
        if (node.Status.Session is null)
        {
            if (!_sessions.TryGetValue(node.Serial, out var s))
            {
                s = new ProbeSession();
                _sessions[node.Serial] = s;
            }
            if (s.LastLogMax is { } last && node.Status.LogRange.Max < last)
            {
                s.Info = null;
                s.Refused = false;
            }
            node = node with { Status = node.Status with { Session = s.Info } };
            if (s.Info is null)
            {
                RequestSessionInfo(node.Serial, s);
            }
        }
        if (!_sessions.TryGetValue(node.Serial, out var session))
        {
            session = new ProbeSession();
            _sessions[node.Serial] = session;
        }
        session.LastLogMax = node.Status.LogRange.Max;
        var now = _clock.Now();
        var source = new LinkSource(LinkKind.NodeConnection, now, Serial, node.HopCount, HighRadioPower: node.Status.Preferences?.HighRadioPower);
        _observations.Send(new ProbeObservation(node.Serial, source, new ObservationPayload.Status(node.Status), now));
        if (_coverage.Note(node.Serial, node.HopCount, now))
        {
            RefreshProbes(now);
        }
    }

    private void RequestSessionInfo(ProbeSerial probe, ProbeSession s)
    {
        if (s.Reading || s.Refused)
        {
            return;
        }
        s.Reading = true;
        _ = ReadSessionInfoInBackgroundAsync(probe, s);
    }

    private async Task ReadSessionInfoInBackgroundAsync(ProbeSerial probe, ProbeSession s)
    {
        // Swift starts this in a new Task: let the status that asked for it go out first.
        await Task.Yield();
        SessionInfo? info;
        try
        {
            info = await ReadSessionInfoAsync(probe);
        }
        catch (Exception)
        {
            info = null;
        }
        s.Reading = false;
        if (_finished || !_sessions.TryGetValue(probe, out var current) || current != s)
        {
            return;
        }
        if (info is { } i)
        {
            s.Info = i;
        }
        else
        {
            s.Refused = true;
        }
    }

    private void HandleHeartbeat(byte[] payload)
    {
        var now = _clock.Now();
        LastHeartbeatPayload = payload;
        _current = _current with
        {
            HeartbeatCount = _current.HeartbeatCount + 1,
            LastHeartbeat = now,
            Link = _current.Link with { LastSeen = now },
        };
        // Heartbeats are the only periodic event, so they also retire probes that stopped being relayed.
        RefreshProbes(now);
    }

    private void RefreshProbes(DateTimeOffset now)
    {
        var live = _coverage.Live(now, CoverageTtl.TotalSeconds);
        _current = _current with
        {
            Probes = new ValueList<ProbeSerial>(live.Keys.Order()),
            HopCounts = new ValueMap<ProbeSerial, int>(live),
        };
        Publish();
    }

    private void Publish()
    {
        if (!_finished)
        {
            _snapshots.Send(_current);
        }
    }

    // Device Information

    /// <summary>Reads firmware, hardware and model strings. Missing characteristics are skipped.</summary>
    public async Task LoadDeviceInfoAsync()
    {
        async Task<string?> Text(GattUuid uuid)
        {
            try
            {
                var bytes = await _connection.ReadAsync(uuid);
                var s = System.Text.Encoding.UTF8.GetString(bytes.TakeWhile(b => b != 0).ToArray());
                return s.Length == 0 ? null : s;
            }
            catch (Exception)
            {
                return null;
            }
        }
        var info = new DeviceInfo(await Text(GattUuid.FirmwareRevision), await Text(GattUuid.HardwareRevision), await Text(GattUuid.ModelNumber));
        if (_finished || info.IsEmpty)
        {
            return;
        }
        _current = _current with { Firmware = info };
        Publish();
    }

    // Probe access

    /// <summary>True if the node relayed a status for <paramref name="probe"/> in the last <see cref="CoverageTtl"/>.</summary>
    public bool Covers(ProbeSerial probe) => _coverage.Covers(probe, _clock.Now(), CoverageTtl.TotalSeconds);

    /// <summary>Hop count of <paramref name="probe"/> as last relayed, if still covered.</summary>
    public int? Hops(ProbeSerial probe) =>
        _coverage.Live(_clock.Now(), CoverageTtl.TotalSeconds).TryGetValue(probe, out var h) ? h : null;

    /// <summary>Sends a request addressed to <paramref name="probe"/> through this node.</summary>
    public Task<UartResponse> SendAsync(UartRequest request, ProbeSerial probe, TimeSpan? timeout = null, int retries = 1) =>
        Uart.SendAsync(request, probe, timeout, retries);

    public async Task<SessionInfo> ReadSessionInfoAsync(ProbeSerial probe)
    {
        var response = await Uart.SendAsync(new UartRequest.ReadSessionInfo(), probe);
        return response.Body is ResponseBody.SessionInfoBody { Info: var info }
            ? info
            : throw new UartException(UartErrorKind.Codec, new CodecError.UnknownMessageType(response.MessageType));
    }

    /// <summary>Streams <paramref name="probe"/>'s log records through the node. Node requests carry IDs, so concurrent
    /// reads (live fetch and backfill, or several probes) need no serialization here.</summary>
    public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end) =>
        Uart.ReadLogs(start, end, probe, TimeSpan.FromSeconds(2));

    /// <summary>Probes recently relayed by a node: last 0x45 time and hop count.</summary>
    private sealed class Coverage
    {
        private readonly Dictionary<ProbeSerial, (DateTimeOffset At, int Hops)> _seen = [];

        /// <summary>Returns true if the set of probes or a hop count changed.</summary>
        public bool Note(ProbeSerial probe, int hops, DateTimeOffset at)
        {
            var changed = !_seen.TryGetValue(probe, out var cur) || cur.Hops != hops;
            _seen[probe] = (at, hops);
            return changed;
        }

        public bool Covers(ProbeSerial probe, DateTimeOffset now, double ttl) =>
            _seen.TryGetValue(probe, out var s) && now.Since(s.At) < ttl;

        public Dictionary<ProbeSerial, int> Live(DateTimeOffset now, double ttl) =>
            _seen.Where(kv => now.Since(kv.Value.At) < ttl).ToDictionary(kv => kv.Key, kv => kv.Value.Hops);

        public void Clear() => _seen.Clear();
    }
}
