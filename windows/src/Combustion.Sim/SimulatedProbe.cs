namespace Combustion.Sim;

/// <summary>
/// A scriptable virtual probe on top of <see cref="SimulatedTransport"/>, driven by an <see cref="IClock"/>.
/// <para>
/// Every 250 ms it advertises (when in range). Every <see cref="SamplePeriod"/> it appends a log record, and, when
/// the app is connected, sends a Probe Status notification. It answers UART requests on RX.
/// </para>
/// <para>
/// Commands: Set Prediction starts a countdown (<see cref="PredictionLeadSeconds"/>, then <see cref="RestingSeconds"/>
/// for removal-and-resting); Set High Low Alarm stores the alarms and trips them as the temperatures cross;
/// Silence Alarms clears <c>Alarming</c>. After each of these the probe sends a status at once, so the app can
/// confirm the new value without waiting for the next sample.
/// </para>
/// <para>
/// Controls: <see cref="SetInRange"/> (out of range: no adverts, the connection drops with <c>LinkLost</c>, connects are
/// refused), <see cref="NewSession"/> (charger removal: new session id, log restarts at seq 0),
/// <see cref="LegacyFirmware"/> (session id 0, 94 B status, Read Session Information fails), <see cref="Preload"/>
/// (a cook that started before the app did), <see cref="DropLinkAfterLogRecords"/> (link loss in the middle of a log
/// download).
/// </para>
/// <para>
/// A <see cref="SimulatedNode"/> can relay it: <see cref="CurrentStatus"/>, <see cref="CurrentAdvertisement"/>,
/// <see cref="Record"/> and <see cref="OnSample"/> give the node what the probe's radio would; <see cref="SetInRange"/>
/// only models the computer's range, so the node keeps hearing the probe.
/// </para>
/// <para>
/// Confined to one <see cref="SynchronizationContext"/> with the transport, so it needs no locks. The transport calls
/// the responder from inside a write; the status that follows a command still goes out afterwards, from a posted
/// continuation, as in Swift.
/// </para>
/// </summary>
public sealed class SimulatedProbe
{
    /// <summary>Eight temperatures (°C) for log record <paramref name="seq"/>.</summary>
    public delegate IReadOnlyList<double> Curve(uint seq, double samplePeriod);

    public static readonly TimeSpan AdvertisementPeriod = TimeSpan.FromMilliseconds(250);

    private readonly SimulatedTransport _transport;
    private readonly IClock _clock;
    private readonly int _probeNumber;
    private readonly int _ticksPerSample;
    private readonly VirtualSensors _virtualSensors = new(SensorIndex.T1, SensorIndex.T4, SensorIndex.T8);

    private Curve _curve;
    private readonly List<LogRecord> _records = [];
    private uint _session;
    private int _ticks;
    private bool _inRange = true;
    private bool _legacy;
    private bool _shortStatus;
    private bool _running;
    private CancellationTokenSource? _task;
    private double _setpoint;
    private PredictionMode _predictionMode = PredictionMode.None;
    private PredictionState _predState = PredictionState.NotInserted;
    private PredictionType _predType = PredictionType.None;
    private double _predRemaining;
    private double _predTotal = 1;
    private double _predHeatStart = 20;
    private int _predHoldTicks;
    private AlarmConfig _alarms = new();
    private readonly List<UartRequest> _received = [];
    private int? _cutLogsAfter;
    private bool _dropLinkOnNextTick;
    private readonly List<Action> _sampleObservers = [];

    public SimulatedProbe(
        ProbeSerial serial, SimulatedTransport transport, IClock clock,
        PeripheralId? peripheral = null, uint sessionId = 1, TimeSpan? samplePeriod = null,
        int probeNumber = 1, Curve? curve = null)
    {
        Serial = serial;
        _transport = transport;
        _clock = clock;
        Peripheral = peripheral ?? new PeripheralId($"PROBE-{serial.Hex}");
        _session = sessionId;
        SamplePeriod = samplePeriod ?? TimeSpan.FromSeconds(5);
        _probeNumber = probeNumber;
        _curve = curve ?? CookCurve();
        var ticks = (int)Math.Round(SamplePeriod.TotalSeconds / AdvertisementPeriod.TotalSeconds, MidpointRounding.AwayFromZero);
        _ticksPerSample = Math.Max(1, ticks);
        AppendRecord();
    }

    public ProbeSerial Serial { get; }

    public PeripheralId Peripheral { get; }

    public TimeSpan SamplePeriod { get; }

    // MARK: Lifecycle

    /// <summary>Registers the UART responder and starts advancing on the clock. Idempotent.</summary>
    public void Start()
    {
        if (_running)
        {
            return;
        }
        _running = true;
        _transport.AddResponder(Respond, peripheral: Peripheral);
        // A timer, not a sleep loop: a TestClock timer re-arms itself, so no tick is lost if this task is slow to resume.
        var ticks = _clock.Timer(AdvertisementPeriod);
        _task = new CancellationTokenSource();
        _ = ticks.ForEachAsync(_ => Tick(), _task.Token);
    }

    /// <summary>Stops advancing. The responder stays registered but stops answering.</summary>
    public void Stop()
    {
        _running = false;
        _task?.Cancel();
        _task = null;
    }

    // MARK: Controls

    public bool IsInRange => _inRange;

    /// <summary>Out of range: no advertisements, the open connection drops with <c>LinkLost</c>, connects are refused.
    /// The probe keeps logging.</summary>
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

    /// <summary>Charger removal: a new session id and an empty log; the first record (seq 0) is written at once.</summary>
    public void NewSession(uint? sessionId = null)
    {
        _session = sessionId ?? unchecked(_session + 1);
        _records.Clear();
        _ticks = 0;
        AppendRecord();
    }

    /// <summary>Old firmware: no session id (status reports 0 and is 94 B) and no Read Session Information.</summary>
    public bool LegacyFirmware
    {
        get => _legacy;
        set => _legacy = value;
    }

    /// <summary>fw v2.3.3: 94 B status without session fields, but Read Session Information is answered.</summary>
    public bool StatusWithoutSession
    {
        get => _shortStatus;
        set => _shortStatus = value;
    }

    public void SetCurve(Curve curve) => _curve = curve;

    /// <summary>Appends <paramref name="records"/> records instantly, as if the probe had been cooking before the app
    /// started.</summary>
    public void Preload(int records)
    {
        for (var i = 0; i < records; i++)
        {
            AppendRecord();
        }
    }

    /// <summary>The next Read Logs answers with <paramref name="count"/> records only, then the link drops on the next tick.</summary>
    public void DropLinkAfterLogRecords(int count) => _cutLogsAfter = count;

    /// <summary>Called each time a log record is made, in range or not.</summary>
    public void OnSample(Action observer) => _sampleObservers.Add(observer);

    /// <summary>Seconds a new prediction counts down from (default 600).</summary>
    public double PredictionLeadSeconds { get; set; } = 600;

    /// <summary>Seconds of the resting countdown that follows removal in <c>RemovalAndResting</c> mode (default 300).</summary>
    public double RestingSeconds { get; set; } = 300;

    /// <summary>Low-battery bit in advertisements and statuses.</summary>
    public bool BatteryLow { get; set; }

    /// <summary>Overheat bits in advertisements and statuses.</summary>
    public SensorSet Overheating { get; set; } = SensorSet.Empty;

    // MARK: Observation

    public uint SessionId => _session;

    public LogRange LogRange => new(0, (uint)(_records.Count - 1));

    public int RecordCount => _records.Count;

    public LogRecord? Record(uint seq) => seq < _records.Count ? _records[(int)seq] : null;

    /// <summary>Every UART request answered, in order.</summary>
    public IReadOnlyList<UartRequest> Requests => [.. _received];

    public AlarmConfig CurrentAlarms => _alarms;

    /// <summary>The full status the probe would notify now (latest record).</summary>
    public ProbeStatusPayload CurrentStatus => StatusPayload(_records[^1]);

    public ProbeAdvertisement CurrentAdvertisement => Advertisement(_records[^1]);

    public bool IsLegacyLayout => _legacy;

    public (double Setpoint, PredictionMode Mode) CurrentPrediction => (_setpoint, _predictionMode);

    /// <summary>Seconds the probe would report right now.</summary>
    public (PredictionState State, PredictionType Type, double SecondsRemaining) CurrentPredictionState =>
        (_predState, _predType, _predRemaining);

    // MARK: A simple cook

    /// <summary>Core climbs from <paramref name="start"/> toward 95 °C over hours; the ambient sensors lead it, with a
    /// smooth gradient in between. <paramref name="offset"/> separates probes in multi-probe tests.</summary>
    public static Curve CookCurve(double start = 20, double offset = 0) => (seq, period) =>
    {
        var t = seq * period;
        var core = start + offset + 70 * (1 - Math.Exp(-t / 6000));
        var ambient = start + offset + 100 * (1 - Math.Exp(-t / 600));
        return Enumerable.Range(0, 8).Select(i => core + (ambient - core) * i / 7).ToArray();
    };

    // MARK: Internals

    private void AppendRecord()
    {
        var seq = (uint)_records.Count;
        ProbeTemperatures temps;
        try
        {
            temps = ProbeTemperatures.FromCelsius(_curve(seq, SamplePeriod.TotalSeconds));
        }
        catch (CodecException)
        {
            temps = ProbeTemperatures.FromRaw(new ushort[8]);
        }
        var core = temps[_virtualSensors.Core];
        _records.Add(new LogRecord(seq, temps,
            new PredictionLog(_virtualSensors, _predState, _predictionMode, _predType, _setpoint, RawSeconds(), EstimatedCore(core))));
    }

    private uint RawSeconds() => (uint)Math.Min(Math.Max(Math.Round(_predRemaining, MidpointRounding.AwayFromZero), 0), 131_071);

    /// <summary>Removal phase: climbs from the heat-start core to the set point as the countdown runs down.
    /// Resting: at the set point. No prediction: the real core.</summary>
    private double EstimatedCore(double core)
    {
        var estimate = (_predState, _predType) switch
        {
            (PredictionState.Predicting, PredictionType.Removal) =>
                _predHeatStart + (_setpoint - _predHeatStart) * (1 - _predRemaining / _predTotal),
            (PredictionState.Predicting, _) or (PredictionState.RemovalPredictionDone, _) => _setpoint,
            _ => core,
        };
        return Math.Min(Math.Max(estimate, -20), 180);
    }

    /// <summary>One 250 ms step of the prediction countdown. Removal done holds for one sample so a status shows it,
    /// then removal-and-resting continues into the resting countdown.</summary>
    private void AdvancePrediction()
    {
        switch (_predState)
        {
            case PredictionState.Predicting:
                _predRemaining -= AdvertisementPeriod.TotalSeconds;
                if (_predRemaining <= 0)
                {
                    _predRemaining = 0;
                    _predState = PredictionState.RemovalPredictionDone;
                    _predHoldTicks = _ticksPerSample;
                }
                break;
            case PredictionState.RemovalPredictionDone
                when _predictionMode == PredictionMode.RemovalAndResting && _predType == PredictionType.Removal:
                _predHoldTicks--;
                if (_predHoldTicks <= 0)
                {
                    _predType = PredictionType.Resting;
                    _predState = PredictionState.Predicting;
                    _predRemaining = RestingSeconds;
                    _predTotal = RestingSeconds;
                }
                break;
            default:
                break;
        }
    }

    /// <summary>Value of an alarm channel in the newest record.</summary>
    private double Temperature(AlarmChannel channel)
    {
        var t = _records[^1].Temperatures;
        return channel switch
        {
            AlarmChannel.Core => t[_virtualSensors.Core],
            AlarmChannel.Surface => t[_virtualSensors.Surface],
            AlarmChannel.Ambient => t[_virtualSensors.Ambient],
            _ => t[(SensorIndex)(int)channel],
        };
    }

    /// <summary>Trips set alarms whose temperature has been reached (tripped stays; alarming is set on the trip and
    /// cleared by Silence Alarms). Unset alarms are reset.</summary>
    private void EvaluateAlarms()
    {
        Dictionary<AlarmChannel, Alarm> Evaluate(IReadOnlyDictionary<AlarmChannel, Alarm> alarms, bool high)
        {
            var output = alarms.ToDictionary(kv => kv.Key, kv => kv.Value);
            foreach (var channel in Enum.GetValues<AlarmChannel>())
            {
                var a = output.TryGetValue(channel, out var existing) ? existing : Alarm.Unset;
                if (a.IsSet)
                {
                    var t = Temperature(channel);
                    if ((high ? t >= a.Temperature : t <= a.Temperature) && !a.Tripped)
                    {
                        a = a with { Tripped = true, Alarming = true };
                    }
                }
                else
                {
                    a = a with { Tripped = false, Alarming = false };
                }
                output[channel] = a;
            }
            return output;
        }
        _alarms = new AlarmConfig(Evaluate(_alarms.High, high: true), Evaluate(_alarms.Low, high: false));
    }

    private void Tick()
    {
        if (!_running)
        {
            return;
        }
        _ticks++;
        var sampled = _ticks % _ticksPerSample == 0;
        AdvancePrediction();
        Action[] observers = [];
        if (sampled)
        {
            AppendRecord();
            EvaluateAlarms();
            observers = [.. _sampleObservers];
        }
        var drop = _dropLinkOnNextTick;
        _dropLinkOnNextTick = false;
        byte[]? ad = null;
        byte[]? status = null;
        if (_inRange)
        {
            var last = _records[^1];
            ad = Try(() => CombustionCodec.EncodeAdvertisement(new AdvertisementPacket.Probe(Advertisement(last)))) ?? [];
            status = sampled ? EncodeStatus(last) : null;
        }
        foreach (var observer in observers)
        {
            observer();
        }
        if (ad is null)
        {
            return;
        }
        _transport.InjectAdvertisement(Peripheral, ad);
        if (status is not null && _transport.IsConnected(Peripheral))
        {
            _transport.InjectNotification(Peripheral, GattUuid.ProbeStatus, status);
        }
        if (drop)
        {
            _transport.ForceDisconnect(Peripheral, DisconnectReason.LinkLost);
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

    private byte[]? EncodeStatus(LogRecord last) =>
        Try(() => CombustionCodec.EncodeProbeStatus(StatusPayload(last), _legacy || _shortStatus ? StatusLayout.Legacy : StatusLayout.Current));

    private ProbeAdvertisement Advertisement(LogRecord last) =>
        new(Serial, last.Temperatures, ProbeMode.Normal, ProbeColor.Yellow, _probeNumber, BatteryLow, _virtualSensors,
            Overheating, new ThermometerPreferences(ProbePowerMode.Normal, false));

    private SessionInfo Session => new(_session, (ushort)(SamplePeriod.TotalSeconds * 1000));

    private ProbeStatusPayload StatusPayload(LogRecord last)
    {
        // Prediction as of now, not as of the record: a command changes it between samples.
        var core = last.Temperatures[_virtualSensors.Core];
        return new ProbeStatusPayload(
            new LogRange(0, last.Sequence), last.Temperatures, ProbeMode.Normal, ProbeColor.Yellow, _probeNumber, BatteryLow,
            _virtualSensors,
            new PredictionStatus(_predState, _predictionMode, _predType, _setpoint, _predHeatStart, RawSeconds(), EstimatedCore(core)),
            FoodSafe: new FoodSafe(FoodSafeMode.Simplified, 1, FoodSafeServing.ServedImmediately, State: FoodSafeState.NotSafe),
            Overheating: Overheating,
            Preferences: new ThermometerPreferences(ProbePowerMode.Normal, false),
            Alarms: _alarms,
            Session: _legacy || _shortStatus ? null : Session);
    }

    /// <summary>Applies a command that arrived through a node, as the probe would after a node forwarded it.
    /// Reads are answered by the node itself from <see cref="Record"/>; this only covers state-changing commands.</summary>
    public void ApplyRelayed(UartRequest request)
    {
        if (request is UartRequest.SetPrediction or UartRequest.SetAlarms or UartRequest.SilenceAlarms)
        {
            Answer(request);
        }
    }

    /// <summary>Answers one RX write. Called by the transport from inside the write.</summary>
    private IReadOnlyList<byte[]> Respond(byte[] bytes)
    {
        var framer = new UartFramer(UartVariant.Probe, UartDirection.Request);
        var output = new List<byte[]>();
        var changed = false;
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
            output.AddRange(Answer(message.Request));
            if (message.Request is UartRequest.SetPrediction or UartRequest.SetAlarms or UartRequest.SilenceAlarms)
            {
                changed = true;
            }
        }
        // The replies go out when this returns; the status follows from a posted continuation.
        if (changed)
        {
            _ = PushStatusSoon();
        }
        return output;
    }

    private async Task PushStatusSoon()
    {
        await Task.Yield();
        PushStatusNow();
    }

    /// <summary>Sends the current status to the connected app, between samples.</summary>
    private void PushStatusNow()
    {
        if (!_running || !_inRange || _records.Count == 0)
        {
            return;
        }
        if (EncodeStatus(_records[^1]) is { } status && _transport.IsConnected(Peripheral))
        {
            _transport.InjectNotification(Peripheral, GattUuid.ProbeStatus, status);
        }
    }

    private static byte[] Reply(byte type, bool success = true, ResponseBody? body = null) =>
        Try(() => CombustionCodec.EncodeResponse(new UartResponse(type, success, body ?? new ResponseBody.Ack()), UartVariant.Probe)) ?? [];

    private List<byte[]> Answer(UartRequest request)
    {
        _received.Add(request);
        switch (request)
        {
            case UartRequest.ReadSessionInfo:
                if (_legacy)
                {
                    return [Reply(UartMessageType.ReadSessionInfo, success: false)];
                }
                return [Reply(UartMessageType.ReadSessionInfo, body: new ResponseBody.SessionInfoBody(null, Session))];
            case UartRequest.ReadLogs(var start, var end):
                if (start > end || start >= _records.Count)
                {
                    return [];
                }
                var last = Math.Min(end, (uint)(_records.Count - 1));
                var seqs = Enumerable.Range((int)start, (int)(last - start + 1));
                if (_cutLogsAfter is { } cut)
                {
                    _cutLogsAfter = null;
                    seqs = seqs.Take(cut);
                    _dropLinkOnNextTick = true;
                }
                return seqs.Select(s => Reply(UartMessageType.ReadLogs, body: new ResponseBody.LogRecordBody(null, _records[s]))).ToList();
            case UartRequest.SetPrediction(var sp, var mode):
                _setpoint = sp;
                _predictionMode = mode;
                if (mode is PredictionMode.None or PredictionMode.Reserved)
                {
                    _predState = PredictionState.NotInserted;
                    _predType = PredictionType.None;
                    _predRemaining = 0;
                }
                else
                {
                    _predState = PredictionState.Predicting;
                    _predType = PredictionType.Removal;
                    _predRemaining = PredictionLeadSeconds;
                    _predTotal = Math.Max(PredictionLeadSeconds, 1);
                    _predHeatStart = _records.Count > 0 ? _records[^1].Temperatures[_virtualSensors.Core] : 20;
                }
                return [Reply(UartMessageType.SetPrediction)];
            case UartRequest.SetAlarms(var config):
                // Tripped and alarming are read-only: the probe decides them from the temperatures.
                static Dictionary<AlarmChannel, Alarm> Fresh(IReadOnlyDictionary<AlarmChannel, Alarm> set) =>
                    set.ToDictionary(kv => kv.Key, kv => new Alarm(kv.Value.IsSet, kv.Value.Temperature));
                _alarms = new AlarmConfig(Fresh(config.High), Fresh(config.Low));
                EvaluateAlarms();
                return [Reply(UartMessageType.SetAlarms)];
            case UartRequest.SilenceAlarms:
                static Dictionary<AlarmChannel, Alarm> Quiet(IReadOnlyDictionary<AlarmChannel, Alarm> set) =>
                    set.ToDictionary(kv => kv.Key, kv => new Alarm(kv.Value.IsSet, kv.Value.Temperature, kv.Value.Tripped));
                _alarms = new AlarmConfig(Quiet(_alarms.High), Quiet(_alarms.Low));
                return [Reply(UartMessageType.SilenceAlarms)];
            default:
                return [];
        }
    }
}
