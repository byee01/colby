using Combustion.Sim;
using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>M6 exit: each rule type fires and clears (see Alerts/), an alarm loops until acknowledged, and the PC stays
/// awake during a cook. Here the whole path: simulated probe -&gt; link -&gt; store -&gt; presenter -&gt; engine -&gt; sinks.</summary>
public sealed class M6AlertsTests
{
    private sealed class Doubles
    {
        public RecordingAlertSink Events { get; } = new();
        public FakeSoundPlayer Sound { get; } = new();
        public FakeNotificationPresenter Notifications { get; } = new();
        public FakeKeepAwake KeepAwake { get; } = new();

        public IReadOnlyList<IAlertSink> Sinks =>
            [Events, new SoundAlertSink(Sound), new NotificationAlertSink(Notifications)];
    }

    private static E2ERig Rig(Doubles d) => new(alertSinks: d.Sinks, keepAwake: d.KeepAwake);

    private static async Task<SimulatedProbe> ConnectAsync(E2ERig rig, int preload = 20)
    {
        var probe = rig.Probe(SerialA, preload: preload);
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 20));
        await rig.RunAsync(10);
        return probe;
    }

    private static readonly string Hex = SerialA.Hex;

    // MARK: Probe alarm: loops until acknowledged, ack silences the probe

    [Fact]
    public void ProbeAlarmLoopsUntilAcknowledgedAndAckSilencesTheProbe() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig);
        await rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Ambient, AlarmKind.High, 30);

        var id = $"{Hex}.alarm.high.ambient";
        var fired = await rig.RunUntilAsync(() => d.Sound.Playing.ContainsKey(id), limit: 300, step: 5);
        Assert.True(fired, "the trip reaches the sound sink");
        Assert.Equal(AlertSound.ProbeAlarm, d.Sound.Playing[id]);
        Assert.True(d.Notifications.Visible.ContainsKey(id));
        Assert.Equal(AlertState.Firing, rig.App.Alerts.ActiveAlerts().First().State);

        // Two minutes later it is still going: nothing but the user stops it.
        await rig.RunAsync(120);
        Assert.Equal(AlertSound.ProbeAlarm, d.Sound.Playing[id]);
        Assert.Single(d.Sound.History, h => h == $"start {id}");

        await rig.App.Alerts.AcknowledgeAsync(id);
        Assert.Empty(d.Sound.Playing); // muted at once
        // Silence Alarms reached the probe and its status shows the alarm quiet.
        Assert.True(await rig.EventuallyAsync(() => probe.Requests.Any(r => r is UartRequest.SilenceAlarms)));
        Assert.True(await rig.RunUntilAsync(() => rig.App.Alerts.ActiveAlerts().Count == 0, limit: 30, step: 1),
            "cleared once the probe reports alarming = false");
        Assert.False(probe.CurrentAlarms.High[AlarmChannel.Ambient].Alarming);
        Assert.Contains($"{id} firing->acknowledged", d.Events.Transitions);
        Assert.Equal($"{id} acknowledged->idle", d.Events.Transitions[^1]);
        await rig.App.StopAsync();
    });

    [Fact]
    public void SilencingOnTheDisplayClearsTheAlertHere() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        await ConnectAsync(rig);
        await rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Ambient, AlarmKind.High, 30);
        var id = $"{Hex}.alarm.high.ambient";
        Assert.True(await rig.RunUntilAsync(() => d.Sound.Playing.ContainsKey(id), limit: 300, step: 5));

        // Silenced from elsewhere (the Display, the phone): the probe's status stops alarming and the alert follows.
        await rig.App.Commands.SilenceAlarmsAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => d.Sound.Playing.Count == 0, limit: 30, step: 1));
        Assert.Empty(rig.App.Alerts.ActiveAlerts());
        await rig.App.StopAsync();
    });

    // MARK: Prediction rules (the default set)

    [Fact]
    public void DefaultAlertsFireTheFiveMinuteWarningThenReadyAndReadyRepeatsUntilAcknowledged() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig);
        probe.PredictionLeadSeconds = 420;
        var five = $"{Hex}.fiveMinutes";
        var ready = $"{Hex}.ready";

        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        await rig.RunAsync(60);
        Assert.Empty(rig.App.Alerts.ActiveAlerts()); // 6 minutes to go: nothing yet

        Assert.True(await rig.RunUntilAsync(() => d.Events.Transitions.Contains($"{five} idle->firing"), limit: 200, step: 1));
        var firedAt = rig.App.Alerts.ActiveAlerts().FirstOrDefault(a => a.Id == five)?.Value;
        Assert.True((firedAt ?? 999) <= 300);

        // Ready: fires when the probe says so, then stays, with a sound, until acknowledged.
        Assert.True(await rig.RunUntilAsync(() => d.Sound.Playing.ContainsKey(ready), limit: 400, step: 1));
        Assert.Equal(AlertSound.Ready, d.Sound.Playing[ready]);
        Assert.Contains($"{five} firing->idle", d.Events.Transitions); // the countdown alert goes away with the countdown
        await rig.RunAsync(300);
        Assert.Equal(AlertSound.Ready, d.Sound.Playing[ready]); // repeats until acknowledged

        await rig.App.Alerts.AcknowledgeAsync(ready);
        Assert.Empty(d.Sound.Playing);
        await rig.RunAsync(60);
        Assert.Equal(AlertState.Acknowledged, rig.App.Alerts.ActiveAlerts().First().State);
        await rig.App.StopAsync();
    });

    // MARK: Offline

    [Fact]
    public void DisconnectedAlertFiresAfterAMinuteDuringACookAndClearsOnReturn() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig);
        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        await rig.RunAsync(20);
        var offline = $"{Hex}.offline";

        probe.SetInRange(false);
        await rig.RunAsync(30);
        Assert.Empty(rig.App.Alerts.ActiveAlerts()); // not a minute yet
        Assert.True(await rig.RunUntilAsync(() => d.Events.Transitions.Contains($"{offline} idle->firing"), limit: 90, step: 1));

        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => d.Events.Transitions.Contains($"{offline} firing->idle"), limit: 120, step: 1));
        await rig.App.StopAsync();
    });

    [Fact]
    public void AcknowledgingOrSnoozingTheDisconnectedAlertTakesItOutOfFiring() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig);
        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        await rig.RunAsync(20);
        var offline = $"{Hex}.offline";
        // What the UI sees: the `Active()` stream, not the engine's own list.
        using var published = rig.App.Alerts.Active().Collect();
        AlertState? State() => published.Last?.FirstOrDefault(a => a.Id == offline)?.State;

        probe.SetInRange(false);
        Assert.True(await rig.RunUntilAsync(() => State() == AlertState.Firing, limit: 120, step: 1));
        await rig.App.Alerts.AcknowledgeAsync(offline);
        Assert.True(await rig.EventuallyAsync(() => State() == AlertState.Acknowledged));
        await rig.RunAsync(120);
        Assert.Equal(AlertState.Acknowledged, State()); // stays acknowledged while the probe is gone
        Assert.Single(d.Events.Transitions, t => t == $"{offline} idle->firing");

        probe.SetInRange(true);
        Assert.True(await rig.RunUntilAsync(() => State() is null, limit: 120, step: 1));
        probe.SetInRange(false);
        Assert.True(await rig.RunUntilAsync(() => State() == AlertState.Firing, limit: 120, step: 1));
        await rig.App.Alerts.SnoozeAsync(offline, TimeSpan.FromSeconds(300));
        Assert.True(await rig.EventuallyAsync(() => State() == AlertState.Snoozed));
        await rig.RunAsync(120);
        Assert.Equal(AlertState.Snoozed, State()); // stays snoozed until the snooze runs out
        await rig.App.StopAsync();
    });

    [Fact]
    public void NoDisconnectedAlertForAProbeThatWasNotCooking() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig); // never given a prediction, core still near room temperature
        probe.SetInRange(false);
        await rig.RunAsync(180);
        Assert.DoesNotContain(d.Events.Transitions, t => t.Contains("offline"));
        await rig.App.StopAsync();
    });

    // MARK: Low battery, overheat

    [Fact]
    public void BatteryAndOverheatReachTheSinksThroughTheWholePath() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig);
        probe.BatteryLow = true;
        probe.Overheating = SensorSet.Of(SensorIndex.T1);
        var overheat = $"{Hex}.overheat.t1";
        Assert.True(await rig.RunUntilAsync(() => d.Sound.Playing.ContainsKey(overheat), limit: 30, step: 1));
        Assert.Contains($"{Hex}.battery idle->firing", d.Events.Transitions);
        // Overheat sorts first.
        Assert.Equal(overheat, rig.App.Alerts.ActiveAlerts().First().Id);
        probe.Overheating = SensorSet.Empty;
        Assert.True(await rig.RunUntilAsync(() => !d.Sound.Playing.ContainsKey(overheat), limit: 30, step: 1));
        Assert.Equal([$"{Hex}.battery"], rig.App.Alerts.ActiveAlerts().Select(a => a.Id).ToList()); // low battery goes on
        Assert.Single(d.Sound.History, h => h == "once problem"); // its sound played once
        await rig.App.StopAsync();
    });

    // MARK: Keep awake

    [Fact]
    public void ThePcStaysAwakeDuringACookAndReleasesAfterUnfollowAndStop() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        await ConnectAsync(rig);
        Assert.False(d.KeepAwake.IsHeld, "a probe at room temperature is not a cook");

        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        Assert.True(await rig.RunUntilAsync(() => d.KeepAwake.IsHeld, limit: 30, step: 1));
        await rig.RunAsync(600);
        Assert.Equal([true], d.KeepAwake.History); // held through the cook without flapping

        await rig.App.UnfollowAsync(SerialA);
        Assert.True(await rig.EventuallyAsync(() => !d.KeepAwake.IsHeld));

        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => d.KeepAwake.IsHeld, limit: 120, step: 1));
        await rig.App.StopAsync();
        Assert.False(d.KeepAwake.IsHeld, "quitting releases the assertion");
    });

    // MARK: Trace

    [Fact]
    public void AlertsCommandsAndPredictionAppearInTheParityTrace() => Det.Run(async () =>
    {
        var d = new Doubles();
        using var rig = Rig(d);
        var probe = await ConnectAsync(rig);
        probe.BatteryLow = true;
        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        await rig.RunAsync(30);
        var lines = rig.Trace.Lines;
        Assert.Contains(lines, l => l.Contains("\"kind\":\"command\"") && l.Contains("\"op\":\"setPrediction\"") && l.Contains("\"result\":\"confirmed\""));
        Assert.Contains(lines, l => l.Contains("\"kind\":\"alert\"") && l.Contains("\"transition\":\"idle->firing\""));
        await rig.App.StopAsync();
    });
}
