namespace Combustion.Core.Tests;

/// <summary>Snapshots, prediction views and an engine wired to test doubles.</summary>
public static class AF
{
    public static readonly ProbeSerial Serial = new(0x1000_5A3F);
    public static readonly ProbeSerial Other = new(0x1000_0002);

    /// <summary>T1 core, T4 surface, T5 ambient (the default virtual sensors); the other sensors follow the core.
    /// <paramref name="alarms"/> null means an empty <see cref="AlarmConfig"/> (a full status has been seen).</summary>
    public static ProbeSnapshot Snapshot(
        DateTimeOffset at, ProbeSerial? serial = null, double? core = 25, double? surface = 30, double? ambient = 40,
        double? t3 = null, bool battery = false, bool offline = false, ProbeMode mode = ProbeMode.Normal,
        PredictionStatus? prediction = null, AlarmConfig? alarms = null, SensorSet overheating = default)
    {
        double?[] temps = [core, core, t3 ?? core, surface, ambient, core, core, core];
        if (mode == ProbeMode.InstantRead)
        {
            temps = [core, null, null, null, null, null, null, null];
        }
        var @virtual = new VirtualTemps(SensorIndex.T1, SensorIndex.T4, SensorIndex.T5, temps[0], temps[3], temps[4]);
        var source = new LinkSource(LinkKind.DirectConnection, at);
        return new ProbeSnapshot(
            serial ?? Serial, 1, ProbeColor.Yellow, mode, temps, @virtual, battery,
            offline ? LinkInfo.None : new LinkInfo([source], source), at,
            Overheating: overheating, Prediction: prediction, Alarms: alarms ?? new AlarmConfig());
    }

    public static PredictionView View(
        ProbeSerial? serial = null, PredictionState state = PredictionState.Predicting, PredictionType type = PredictionType.Removal,
        uint? seconds = null, bool stale = false) =>
        new(serial ?? Serial, state, type == PredictionType.Resting ? PredictionMode.RemovalAndResting : PredictionMode.TimeToRemoval, type,
            60, 40, SecondsRemaining: seconds, IsStale: stale);

    public static PredictionStatus Prediction(PredictionState state, PredictionType type = PredictionType.Removal) =>
        new(state, PredictionMode.TimeToRemoval, type, 60, 20, 0, 40);

    public static AlarmConfig Alarming(AlarmKind kind, AlarmChannel channel, double temperature = 80, bool on = true)
    {
        var alarm = new Alarm(true, temperature, on, on);
        var map = new Dictionary<AlarmChannel, Alarm> { [channel] = alarm };
        return kind == AlarmKind.High ? new AlarmConfig(high: map) : new AlarmConfig(low: map);
    }
}

/// <summary>An engine with every test double attached. Create it on the test's <see cref="DeterministicContext"/>.</summary>
public sealed class AlertRig
{
    public TestClock Clock { get; } = new();
    public RecordingAlertSink Sink { get; } = new();
    public FakeSoundPlayer Sound { get; } = new();
    public FakeNotificationPresenter Notifications { get; } = new();
    public FakeKeepAwake KeepAwake { get; } = new();
    public FakeSilencer Silencer { get; } = new();
    public InMemoryAlertRuleStore Store { get; } = new();
    public AlertEngine Engine { get; }

    /// <param name="defaults">Seed the default alert set on follow (off by default so tests add their own rules).</param>
    public AlertRig(bool defaults = false, TimeSpan? cookIdle = null, ITraceSink? trace = null)
    {
        IAlertSink[] sinks = [Sink, new LoopingSoundAlertSink(Sound), new NotificationAlertSink(Notifications)];
        Engine = new AlertEngine(
            Clock, Store, sinks, KeepAwake, Silencer, trace,
            defaults ? AlertRule.Defaults : AlertEngine.NoDefaultRules, cookIdle ?? TimeSpan.FromSeconds(600));
    }

    /// <summary>Follows the probe and adds rules.</summary>
    public async Task FollowAsync(IEnumerable<AlertRule> rules, ProbeSerial? serial = null)
    {
        var s = serial ?? AF.Serial;
        await Engine.SetFollowedAsync(new HashSet<ProbeSerial> { s });
        foreach (var r in rules)
        {
            await Engine.AddRuleAsync(s, r);
        }
    }

    public Task SnapshotAsync(
        ProbeSerial? serial = null, double? core = 25, double? surface = 30, double? ambient = 40, double? t3 = null,
        bool battery = false, bool offline = false, ProbeMode mode = ProbeMode.Normal, PredictionStatus? prediction = null,
        AlarmConfig? alarms = null, SensorSet overheating = default) =>
        Engine.IngestAsync(AF.Snapshot(
            Clock.Now(), serial, core, surface, ambient, t3, battery, offline, mode, prediction, alarms, overheating));

    public Task ViewAsync(PredictionView v) => Engine.IngestAsync(v);

    public IReadOnlyList<string> Transitions => Sink.Transitions;

    public ValueList<AlertInstance> Active() => Engine.ActiveAlerts();

    public AlertState? State(string id) => Active().FirstOrDefault(a => a.Id == id)?.State;

    public static HashSet<ProbeSerial> Set(params ProbeSerial[] serials) => [.. serials];
}
