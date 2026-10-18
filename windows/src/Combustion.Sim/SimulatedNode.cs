using System.Text;

namespace Combustion.Sim;

/// <summary>
/// A virtual MeatNet node (Display, Booster, ...) on top of <see cref="SimulatedTransport"/>, driven by an
/// <see cref="IClock"/>.
/// <para>
/// It relays <see cref="SimulatedProbe"/>s the way a node on the repeater network would, independent of whether the
/// computer can hear those probes directly:
/// </para>
/// <list type="bullet">
/// <item>Every 250 ms it advertises itself, plus one repeated-probe advertisement per relayed probe.</item>
/// <item>When a relayed probe makes a log record and the app is connected to the node, it sends a <c>0x45</c>
/// Probe Status for it. Every second it sends a <c>0x49</c> heartbeat.</item>
/// <item>It answers node-variant UART requests: Read Logs and Read Session Information from the probe's log,
/// the probe Device Information reads, and (forwarded to the probe) prediction, alarms and silence.</item>
/// </list>
/// <para>
/// Controls: <see cref="Relay"/> / <see cref="StopRelaying"/> (a probe joins or leaves the node's network),
/// <see cref="SetInRange"/> (out of range: no advertisements, the connection drops with <c>LinkLost</c>, connects are
/// refused).
/// </para>
/// <para>Confined to one <see cref="SynchronizationContext"/> with the transport, so it needs no locks.</para>
/// </summary>
public sealed class SimulatedNode
{
    public static readonly TimeSpan AdvertisementPeriod = TimeSpan.FromMilliseconds(250);

    /// <summary>Advertisement periods per heartbeat.</summary>
    public const int HeartbeatEvery = 4;

    /// <summary>MeatNet heartbeat message type (Swift <c>UartMessageType.heartbeat</c>; not in the C# codec yet).</summary>
    private const byte HeartbeatMessageType = 0x49;

    private readonly SimulatedTransport _transport;
    private readonly IClock _clock;

    private sealed record Relayed(SimulatedProbe Probe, int Hops);

    private readonly Dictionary<ProbeSerial, Relayed> _relayed = [];
    private bool _inRange = true;
    private bool _running;
    private int _ticks;
    private uint _nextResponseId = 5000;
    private readonly List<(ProbeSerial? Probe, UartRequest Request)> _received = [];
    private int _heartbeats;
    private CancellationTokenSource? _task;

    public SimulatedNode(
        string serial, SimulatedTransport transport, IClock clock,
        NodeProductType productType = NodeProductType.Display, PeripheralId? peripheral = null)
    {
        Serial = serial;
        ProductType = productType;
        _transport = transport;
        _clock = clock;
        Peripheral = peripheral ?? new PeripheralId($"NODE-{serial}");
    }

    public string Serial { get; }

    public NodeProductType ProductType { get; }

    public PeripheralId Peripheral { get; }

    // MARK: Lifecycle

    /// <summary>Registers the UART responder and starts advertising on the clock. Idempotent.</summary>
    public void Start()
    {
        if (_running)
        {
            return;
        }
        _running = true;
        _transport.AddResponder(Respond, peripheral: Peripheral);
        var ticks = _clock.Timer(AdvertisementPeriod);
        _task = new CancellationTokenSource();
        _ = ticks.ForEachAsync(_ => Tick(), _task.Token);
    }

    public void Stop()
    {
        _running = false;
        _task?.Cancel();
        _task = null;
    }

    // MARK: Controls

    /// <summary>The probe joins the node's network, <paramref name="hops"/> repeater hops (1...4) away.</summary>
    public void Relay(SimulatedProbe probe, int hops = 1)
    {
        var first = !_relayed.ContainsKey(probe.Serial);
        _relayed[probe.Serial] = new Relayed(probe, hops);
        if (first)
        {
            probe.OnSample(() => Sampled(probe.Serial));
        }
    }

    public void StopRelaying(SimulatedProbe probe) => _relayed.Remove(probe.Serial);

    public bool IsInRange => _inRange;

    /// <summary>Out of range: no advertisements, the open connection drops with <c>LinkLost</c>, connects are refused.</summary>
    public void SetInRange(bool value)
    {
        var changed = _inRange != value;
        _inRange = value;
        if (!changed)
        {
            return;
        }
        if (value)
        {
            _transport.AllowConnects(Peripheral);
        }
        else
        {
            _transport.BlockConnects(Peripheral);
            _transport.ForceDisconnect(Peripheral, DisconnectReason.LinkLost);
        }
    }

    /// <summary>Strings the app reads from the node's Device Information service.</summary>
    public void SetDeviceInfo(DeviceInfo info)
    {
        foreach (var (uuid, text) in new[]
                 {
                     (GattUuid.FirmwareRevision, info.Firmware), (GattUuid.HardwareRevision, info.Hardware),
                     (GattUuid.ModelNumber, info.Model),
                 })
        {
            if (text is not null)
            {
                _transport.SetReadValue(Encoding.UTF8.GetBytes(text), uuid, Peripheral);
            }
        }
    }

    // MARK: Observation

    /// <summary>Every request answered (or refused), in order, with the probe it named.</summary>
    public IReadOnlyList<(ProbeSerial? Probe, UartRequest Request)> Requests => [.. _received];

    public int HeartbeatsSent => _heartbeats;

    // MARK: Internals

    private void Tick()
    {
        if (!_running || !_inRange)
        {
            return;
        }
        _ticks++;
        var ads = new List<byte[]>();
        if (Try(() => CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Node(new NodeAdvertisement(ProductType, Serial)))) is { } own)
        {
            ads.Add(own);
        }
        foreach (var r in _relayed.Values)
        {
            if (Try(() => CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Repeated(r.Probe.CurrentAdvertisement, r.Hops))) is { } ad)
            {
                ads.Add(ad);
            }
        }
        byte[]? beat = null;
        if (_ticks % HeartbeatEvery == 0)
        {
            _heartbeats++;
            var payload = new byte[10];
            var serial = Encoding.UTF8.GetBytes(Serial);
            Array.Copy(serial, payload, Math.Min(serial.Length, 10));
            beat = Try(() => new UartFrame(UartVariant.Node, UartDirection.Request, HeartbeatMessageType, requestId: 0, payload: payload).Encoded());
        }
        foreach (var ad in ads)
        {
            _transport.InjectAdvertisement(Peripheral, ad);
        }
        if (beat is not null && _transport.IsConnected(Peripheral))
        {
            _transport.InjectNotification(Peripheral, GattUuid.UartTx, beat);
        }
    }

    private static byte[]? Try(Func<byte[]> encode)
    {
        try
        {
            return encode();
        }
        catch (CodecException)
        {
            return null;
        }
    }

    /// <summary>A relayed probe made a record: push its status to the connected app.</summary>
    private void Sampled(ProbeSerial probeSerial)
    {
        if (!_running || !_inRange || !_relayed.TryGetValue(probeSerial, out var relay) || !_transport.IsConnected(Peripheral))
        {
            return;
        }
        var probe = relay.Probe;
        var layout = probe.IsLegacyLayout ? StatusLayout.Legacy : StatusLayout.Current;
        var frame = Try(() =>
        {
            var payload = CombustionCodec.EncodeNodeProbeStatus(new NodeProbeStatus(probeSerial, probe.CurrentStatus, relay.Hops), layout);
            return new UartFrame(UartVariant.Node, UartDirection.Request, UartMessageType.ProbeStatus, requestId: 0, payload: payload).Encoded();
        });
        if (frame is not null)
        {
            _transport.InjectNotification(Peripheral, GattUuid.UartTx, frame);
        }
    }

    /// <summary>Answers one RX write. Called by the transport from inside the write.</summary>
    private IReadOnlyList<byte[]> Respond(byte[] bytes)
    {
        var framer = new UartFramer(UartVariant.Node, UartDirection.Request);
        var output = new List<byte[]>();
        foreach (var item in framer.Push(bytes))
        {
            if (item is not UartFramerOutput.FrameOutput { Frame: var frame })
            {
                continue;
            }
            UartRequestMessage message;
            try
            {
                message = CombustionCodec.DecodeRequest(frame);
            }
            catch (CodecException)
            {
                continue;
            }
            if (message.RequestId is not { } requestId)
            {
                continue;
            }
            output.AddRange(Answer(message, requestId));
        }
        return output;
    }

    private List<byte[]> Answer(UartRequestMessage message, uint requestId)
    {
        var type = message.Request.MessageType;
        _received.Add((message.Probe, message.Request));
        var nextId = _nextResponseId;
        _nextResponseId = unchecked(_nextResponseId + 300); // room for a whole log read
        var lastId = unchecked(nextId + 299);
        Relayed? relay = message.Probe is { } named && _relayed.TryGetValue(named, out var r) ? r : null;
        var exhausted = false;

        byte[] Reply(bool success = true, ResponseBody? body = null)
        {
            uint responseId = 0;
            if (!exhausted)
            {
                responseId = nextId;
                exhausted = nextId == lastId;
                nextId = unchecked(nextId + 1);
            }
            var response = new UartResponse(type, success, body ?? new ResponseBody.Ack(), requestId, responseId);
            return Try(() => CombustionCodec.EncodeResponse(response, UartVariant.Node)) ?? [];
        }

        // Global silence names no probe; everything else needs a probe on this node's network.
        if (message.Request is UartRequest.SilenceAlarms && message.Probe is null)
        {
            return [Reply()];
        }
        if (message.Probe is not { } probe || relay is null)
        {
            return [Reply(success: false)];
        }
        var source = relay.Probe;

        switch (message.Request)
        {
            case UartRequest.ReadSessionInfo:
                if (source.IsLegacyLayout)
                {
                    return [Reply(success: false)];
                }
                var info = new SessionInfo(source.SessionId, (ushort)(source.SamplePeriod.TotalSeconds * 1000));
                return [Reply(body: new ResponseBody.SessionInfoBody(probe, info))];
            case UartRequest.ReadLogs(var start, var end):
                var count = source.RecordCount;
                if (start > end || start >= count)
                {
                    return [];
                }
                var output = new List<byte[]>();
                for (var seq = (long)start; seq <= Math.Min(end, (uint)(count - 1)); seq++)
                {
                    if (source.Record((uint)seq) is { } record)
                    {
                        output.Add(Reply(body: new ResponseBody.LogRecordBody(probe, record)));
                    }
                }
                return output;
            case UartRequest.SetPrediction or UartRequest.SetAlarms or UartRequest.SilenceAlarms:
                source.ApplyRelayed(message.Request);
                return [Reply()];
            case UartRequest.ReadProbeFirmware:
                return [Reply(body: new ResponseBody.RevisionBody(probe, ProbeInfoKind.Firmware, "v1.2.3"))];
            case UartRequest.ReadProbeHardware:
                return [Reply(body: new ResponseBody.RevisionBody(probe, ProbeInfoKind.Hardware, "HW-A"))];
            case UartRequest.ReadProbeModel:
                return [Reply(body: new ResponseBody.RevisionBody(probe, ProbeInfoKind.Model, "Predictive Probe"))];
            default:
                return [Reply(success: false)];
        }
    }
}
