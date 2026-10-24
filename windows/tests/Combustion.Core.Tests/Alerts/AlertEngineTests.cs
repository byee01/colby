namespace Combustion.Core.Tests;

using K = AlertRuleKind;

/// <summary>The instance state machine, sinks, rule management and keep-awake (docs/02 §9).</summary>
public class AlertEngineTests
{
    private static readonly AlertRule Hot = new("hot", new K.TemperatureAbove(AlarmChannel.Core, 60));
    private static readonly string Hex = AF.Serial.Hex;

    /// <summary>Stands in for <c>CommandError.notConfirmed</c> (Commands is ported separately).</summary>
    private sealed class NotConfirmed() : Exception("notConfirmed");

    // Ack, snooze

    [Fact]
    public void AcknowledgeStopsSoundKeepsRecordAndStaysQuietUntilTheConditionClears() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        Assert.Equal(["once custom"], rig.Sound.History);
        Assert.True(rig.Notifications.Visible.ContainsKey("hot"));

        await rig.Engine.AcknowledgeAsync("hot");
        Assert.Equal(AlertState.Acknowledged, rig.State("hot"));
        Assert.Equal(rig.Clock.Now(), rig.Active().First().AcknowledgedAt);
        Assert.Empty(rig.Sound.Playing);
        Assert.Empty(rig.Notifications.Visible);

        // Still hot: no new alert for the same crossing.
        await rig.SnapshotAsync(core: 65);
        Assert.Equal(AlertState.Acknowledged, rig.State("hot"));
        Assert.Equal(["hot idle->firing", "hot firing->acknowledged"], rig.Transitions);

        await rig.SnapshotAsync(core: 50);
        Assert.Empty(rig.Active());
        Assert.Equal("hot acknowledged->idle", rig.Transitions[^1]);
        // And the next crossing is a new alert.
        await rig.SnapshotAsync(core: 62);
        Assert.Equal(AlertState.Firing, rig.State("hot"));
    });

    [Fact]
    public void AlarmSoundLoopsUntilAcknowledged() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        var id = $"{AF.Serial.Hex}.alarm.high.core";
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core));
        for (var i = 0; i < 10; i++)
        {
            await rig.Clock.AdvanceAsync(30);
            await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core));
        }
        Assert.Equal(AlertSound.ProbeAlarm, rig.Sound.Playing[id]); // five minutes later it is still going
        Assert.Equal([$"start {id}"], rig.Sound.History); // one loop, started once
        await rig.Engine.AcknowledgeAsync(id);
        Assert.Equal([$"start {id}", $"stop {id}"], rig.Sound.History);
    });

    [Fact]
    public void RuleSoundPlaysOncePerFiring() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        for (var i = 0; i < 10; i++)
        {
            await rig.Clock.AdvanceAsync(30);
            await rig.SnapshotAsync(core: 62);
        }
        Assert.Equal(AlertState.Firing, rig.State("hot"));
        Assert.Empty(rig.Sound.Playing);
        Assert.Equal(["once custom"], rig.Sound.History); // played when it fired, not again while it stays true
        await rig.Engine.AcknowledgeAsync("hot");
        Assert.Equal(["once custom"], rig.Sound.History); // nothing to stop
    });

    [Fact]
    public void SoundPerAlertFollowsTheUxPlan()
    {
        static AlertSound Sound(AlertRuleKind kind) => AlertSounds.For(new AlertSource.Rule(kind));
        Assert.True(Sound(new AlertRuleKind.PredictionDone()) == AlertSound.Ready && Sound(new AlertRuleKind.RestingDone()) == AlertSound.Ready);
        Assert.Equal(AlertSound.Countdown, Sound(new AlertRuleKind.PredictionWithin(300)));
        Assert.True(Sound(new AlertRuleKind.ProbeOffline()) == AlertSound.Problem && Sound(new AlertRuleKind.BatteryLow()) == AlertSound.Problem);
        Assert.Equal(AlertSound.Custom, Sound(new AlertRuleKind.TemperatureAbove(AlarmChannel.Core, 60)));
        Assert.Equal(AlertSound.Custom, Sound(new AlertRuleKind.Stall(minRise: 1)));
        Assert.Equal([AlertSound.Ready, AlertSound.Overheat, AlertSound.ProbeAlarm], Enum.GetValues<AlertSound>().Where(s => s.Loops()));
    }

    [Fact]
    public void SnoozeMutesThenFiresAgainIfStillTrue() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.SnoozeAsync("hot", TimeSpan.FromSeconds(300));
        Assert.Equal(AlertState.Snoozed, rig.State("hot"));
        Assert.Equal(rig.Clock.Now().AddSeconds(300), rig.Active().First().SnoozedUntil);
        Assert.True(rig.Sound.Playing.Count == 0 && rig.Notifications.Visible.Count == 0);

        await rig.SnapshotAsync(core: 62);
        await rig.Clock.AdvanceAsync(299);
        Assert.Equal(AlertState.Snoozed, rig.State("hot"));
        await rig.Clock.AdvanceAsync(2);
        Assert.Equal(AlertState.Firing, rig.State("hot")); // the timer alone brings it back, no new reading needed
        Assert.Equal(["once custom", "once custom"], rig.Sound.History);
        Assert.Equal(["hot idle->firing", "hot firing->snoozed", "hot snoozed->firing"], rig.Transitions);
        Assert.Null(rig.Active().First().SnoozedUntil);
    });

    [Fact]
    public void SnoozedAlertThatClearsDuringTheSnoozeJustGoesIdle() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.SnoozeAsync("hot", TimeSpan.FromSeconds(300));
        await rig.SnapshotAsync(core: 40);
        Assert.Empty(rig.Active());
        await rig.Clock.AdvanceAsync(400);
        Assert.Equal(["hot idle->firing", "hot firing->snoozed", "hot snoozed->idle"], rig.Transitions);
    });

    [Fact]
    public void AcknowledgingASnoozedAlertWorks() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.SnoozeAsync("hot", TimeSpan.FromSeconds(300));
        await rig.Engine.AcknowledgeAsync("hot");
        Assert.Equal(AlertState.Acknowledged, rig.State("hot"));
        await rig.Clock.AdvanceAsync(400);
        Assert.Equal(AlertState.Acknowledged, rig.State("hot")); // the snooze timer is gone
    });

    [Fact]
    public void AcknowledgeAndSnoozeOfUnknownOrWrongStateAreIgnored() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.Engine.AcknowledgeAsync("nothing");
        await rig.Engine.SnoozeAsync("nothing", TimeSpan.FromSeconds(5));
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.AcknowledgeAsync("hot");
        await rig.Engine.SnoozeAsync("hot", TimeSpan.FromSeconds(5)); // already acknowledged
        Assert.Equal(AlertState.Acknowledged, rig.State("hot"));
        Assert.Equal(2, rig.Transitions.Count);
    });

    // Probe alarms: silence

    [Fact]
    public void AcknowledgingAProbeAlarmSilencesTheProbe() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core));
        var id = $"{Hex}.alarm.high.core";
        Assert.Equal(AlertSound.ProbeAlarm, rig.Sound.Playing[id]);
        await rig.Engine.AcknowledgeAsync(id);
        Assert.Equal([AF.Serial], rig.Silencer.Silenced);
        Assert.Equal(AlertState.Acknowledged, rig.State(id));
        Assert.Empty(rig.Sound.Playing);
        // The probe confirms with alarming = false in its next status: the alert is over.
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core, on: false));
        Assert.Empty(rig.Active());
    });

    [Fact]
    public void FailedSilenceGoesBackToFiringWithTheReason() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core));
        var id = $"{Hex}.alarm.high.core";
        rig.Silencer.FailNext(new NotConfirmed());
        await rig.Engine.AcknowledgeAsync(id);
        Assert.Equal(AlertState.Firing, rig.State(id));
        Assert.Equal(AlertSound.ProbeAlarm, rig.Sound.Playing[id]); // the app does not stay quiet about a probe that still alarms
        var last = rig.Sink.Events[^1];
        Assert.True(last.Failure?.Contains("notConfirmed") == true);
        Assert.Equal("acknowledged->firing", last.Transition);
    });

    [Fact]
    public void OverheatCannotBeSilencedOnTheProbeSoAckOnlyMutesTheApp() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(overheating: SensorSet.Of(SensorIndex.T3));
        var id = $"{Hex}.overheat.t3";
        Assert.Equal(AlertSound.Overheat, rig.Sound.Playing[id]);
        Assert.True(rig.Notifications.Visible.ContainsKey(id));
        await rig.Engine.AcknowledgeAsync(id);
        Assert.Empty(rig.Silencer.Silenced);
        Assert.Empty(rig.Sound.Playing);
        Assert.True(rig.Notifications.Visible.ContainsKey(id)); // the banner stays while the probe is overheating (06 §7)
        await rig.SnapshotAsync(overheating: SensorSet.Empty);
        Assert.Empty(rig.Notifications.Visible);
        Assert.Empty(rig.Active());
    });

    [Fact]
    public void SnoozingAProbeAlarmIsLocalOnly() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core));
        var id = $"{Hex}.alarm.high.core";
        await rig.Engine.SnoozeAsync(id, TimeSpan.FromSeconds(60));
        Assert.Empty(rig.Silencer.Silenced);
        await rig.Clock.AdvanceAsync(61);
        Assert.Equal(AlertState.Firing, rig.State(id)); // the probe is still alarming
    });

    [Fact]
    public void SilenceAllAcknowledgesEverythingAndSendsOneSilence() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61, alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core), overheating: SensorSet.Of(SensorIndex.T2));
        Assert.Equal(3, rig.Active().Count);
        await rig.Engine.SilenceAllAsync(AF.Serial);
        Assert.All(rig.Active(), a => Assert.Equal(AlertState.Acknowledged, a.State));
        Assert.Equal([AF.Serial], rig.Silencer.Silenced); // one Silence Alarms covers every probe alarm
        Assert.Empty(rig.Sound.Playing);
    });

    [Fact]
    public void SilenceAllWithoutAProbeAlarmSendsNothing() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.SilenceAllAsync(AF.Serial);
        Assert.Empty(rig.Silencer.Silenced);
        Assert.Equal(AlertState.Acknowledged, rig.State("hot"));
    });

    // Ordering of the active list

    [Fact]
    public void ActiveListIsOrderedOverheatThenProbeAlarmThenReadyThenOthersNewestFirst() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([
            new AlertRule("bat", new K.BatteryLow()),
            new AlertRule("ready", new K.PredictionDone()),
            new AlertRule("hot", new K.TemperatureAbove(AlarmChannel.Core, 60)),
        ]);
        await rig.SnapshotAsync(core: 20, battery: true);
        await rig.Clock.AdvanceAsync(5);
        await rig.SnapshotAsync(core: 70, battery: true, alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Ambient), overheating: SensorSet.Of(SensorIndex.T1));
        await rig.ViewAsync(AF.View(state: PredictionState.RemovalPredictionDone, seconds: null));
        Assert.Equal([$"{Hex}.overheat.t1", $"{Hex}.alarm.high.ambient", "ready", "hot", "bat"], rig.Active().Select(a => a.Id));
    });

    // Streams

    [Fact]
    public void EventsAndActiveStreamsCarryEveryChange() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        using var events = rig.Engine.Events().Collect();
        using var lists = rig.Engine.Active().Collect();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.AcknowledgeAsync("hot");
        await rig.SnapshotAsync(core: 40);
        await rig.Clock.SettleAsync();
        Assert.Equal(["idle->firing", "firing->acknowledged", "acknowledged->idle"], events.Items.Select(e => e.Transition));
        Assert.Empty(lists.Items[0]); // the current (empty) list first
        Assert.True(lists.Items.Any(l => l.Select(a => a.Id).SequenceEqual(["hot"])) && lists.Last!.Count == 0);
    });

    [Fact]
    public void EventsAreTracedForTheParityFormat() => Det.Run(async () =>
    {
        var clock = new TestClock();
        using var trace = new JsonlTraceSink(clock);
        var engine = new AlertEngine(clock, trace: trace, defaultRules: AlertEngine.NoDefaultRules);
        await engine.SetFollowedAsync(AlertRig.Set(AF.Serial));
        await engine.AddRuleAsync(AF.Serial, Hot);
        await engine.IngestAsync(AF.Snapshot(clock.Now(), core: 61));
        Assert.Single(trace.Lines);
        var line = trace.Lines[0];
        Assert.True(line.Contains("\"kind\":\"alert\"") && line.Contains("\"rule\":\"hot\""));
        Assert.True(line.Contains("\"transition\":\"idle->firing\"") && line.Contains("\"value\":61"));
        Assert.Contains($"\"serial\":\"{Hex}\"", line);
    });

    // Rule management

    [Fact]
    public void RemovingOrDisablingARuleClearsItsAlert() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot, new AlertRule("bat", new K.BatteryLow())]);
        await rig.SnapshotAsync(core: 61, battery: true);
        Assert.Equal(2, rig.Active().Count);
        await rig.Engine.RemoveRuleAsync(AF.Serial, "hot");
        Assert.Equal(["bat"], rig.Active().Select(a => a.Id));
        var bat = new AlertRule("bat", new K.BatteryLow()) { Enabled = false };
        await rig.Engine.UpdateRuleAsync(AF.Serial, bat);
        Assert.Empty(rig.Active());
        bat = bat with { Enabled = true };
        await rig.Engine.UpdateRuleAsync(AF.Serial, bat);
        Assert.Equal(AlertState.Firing, rig.State("bat")); // enabled again and the condition holds
    });

    [Fact]
    public void UpdatingARuleThresholdReevaluatesAtOnce() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 55);
        Assert.Empty(rig.Active());
        await rig.Engine.UpdateRuleAsync(AF.Serial, new AlertRule("hot", new K.TemperatureAbove(AlarmChannel.Core, 50)));
        Assert.Equal(AlertState.Firing, rig.State("hot"));
        // Changing the kind drops the old alert instead of morphing it.
        await rig.Engine.UpdateRuleAsync(AF.Serial, new AlertRule("hot", new K.TemperatureBelow(AlarmChannel.Core, 60)));
        Assert.Equal(["hot idle->firing", "hot firing->idle", "hot idle->firing"], rig.Transitions);
    });

    [Fact]
    public void RulesArePerProbeAndPersist() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial, AF.Other));
        await rig.Engine.AddRuleAsync(AF.Serial, Hot);
        Assert.Equal(["hot"], (await rig.Engine.RulesAsync(AF.Serial)).Select(r => r.Id));
        Assert.Empty(await rig.Engine.RulesAsync(AF.Other));
        Assert.Equal(["hot"], (await rig.Store.LoadRulesAsync(AF.Serial))?.Select(r => r.Id) ?? []);

        // A second engine on the same store sees the rules after follow.
        var again = new AlertEngine(rig.Clock, rig.Store, defaultRules: AlertEngine.NoDefaultRules);
        await again.SetFollowedAsync(AlertRig.Set(AF.Serial));
        Assert.Equal(["hot"], (await again.RulesAsync(AF.Serial)).Select(r => r.Id));
        await again.IngestAsync(AF.Snapshot(rig.Clock.Now(), core: 70));
        Assert.Equal(["hot"], again.ActiveAlerts().Select(a => a.Id));
    });

    [Fact]
    public void OtherProbesDoNotInterfere() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial, AF.Other));
        await rig.Engine.AddRuleAsync(AF.Serial, Hot);
        await rig.Engine.IngestAsync(AF.Snapshot(rig.Clock.Now(), AF.Other, core: 99));
        Assert.Empty(rig.Active());
        await rig.Engine.IngestAsync(AF.Snapshot(rig.Clock.Now(), AF.Serial, core: 99));
        Assert.Equal([AF.Serial], rig.Active().Select(a => a.Serial));
    });

    // Defaults (06 §6)

    [Fact]
    public void FirstFollowSeedsTheDefaultAlertSetOnce() => Det.Run(async () =>
    {
        var rig = new AlertRig(defaults: true);
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial));
        var rules = await rig.Engine.RulesAsync(AF.Serial);
        Assert.Equal(
            [new K.PredictionDone(), new K.PredictionWithin(300), new K.ProbeOffline(60, OnlyDuringCook: true), new K.BatteryLow()],
            rules.Select(r => r.Kind));
        // Unfollow, delete one, follow again: the user's choice stands, no reseed.
        await rig.Engine.SetFollowedAsync(AlertRig.Set());
        await rig.Engine.RemoveRuleAsync(AF.Serial, $"{Hex}.battery");
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial));
        Assert.Equal(3, (await rig.Engine.RulesAsync(AF.Serial)).Count);
    });

    // Follow set

    [Fact]
    public void UnfollowingClearsTheProbesAlerts() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61, overheating: SensorSet.Of(SensorIndex.T1));
        Assert.Equal(2, rig.Active().Count);
        await rig.Engine.SetFollowedAsync(AlertRig.Set());
        Assert.Empty(rig.Active());
        Assert.Empty(rig.Sound.Playing);
        // Not followed: readings are ignored.
        await rig.SnapshotAsync(core: 70);
        Assert.Empty(rig.Active());
    });

    [Fact]
    public void FollowingAProbeThatIsAlreadyReportingEvaluatesAtOnce() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.SnapshotAsync(core: 61); // seen, not followed
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial));
        await rig.Engine.AddRuleAsync(AF.Serial, Hot);
        Assert.Equal(AlertState.Firing, rig.State("hot"));
    });

    // Keep awake

    [Fact]
    public void KeepAwakeIsHeldForTheWholeCookAndReleasedAfter() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(core: 22, prediction: AF.Prediction(PredictionState.NotInserted));
        Assert.Empty(rig.KeepAwake.History); // on the counter: nothing to protect
        await rig.SnapshotAsync(core: 30, prediction: AF.Prediction(PredictionState.Inserted));
        Assert.True(rig.KeepAwake.IsHeld);
        await rig.SnapshotAsync(core: 55, prediction: AF.Prediction(PredictionState.Predicting));
        await rig.SnapshotAsync(core: 60, prediction: AF.Prediction(PredictionState.RemovalPredictionDone));
        Assert.Equal([true], rig.KeepAwake.History); // asserted once, not per reading
        await rig.SnapshotAsync(core: 25, prediction: AF.Prediction(PredictionState.NotInserted));
        Assert.Equal([true, false], rig.KeepAwake.History);
    });

    [Fact]
    public void AHotCoreWithoutPredictionCountsAsACook() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(core: 41, prediction: AF.Prediction(PredictionState.NotInserted));
        Assert.True(rig.KeepAwake.IsHeld);
    });

    [Fact]
    public void InstantReadIsNotACook() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(core: 90, mode: ProbeMode.InstantRead, prediction: AF.Prediction(PredictionState.Predicting));
        Assert.Empty(rig.KeepAwake.History);
    });

    [Fact]
    public void KeepAwakeOutlastsAQuietProbeForTheIdleTimeoutThenLetsGo() => Det.Run(async () =>
    {
        var rig = new AlertRig(cookIdle: TimeSpan.FromSeconds(600));
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(prediction: AF.Prediction(PredictionState.Predicting));
        var last = rig.Clock.Now();
        await rig.Engine.IngestAsync(AF.Snapshot(last, offline: true, prediction: AF.Prediction(PredictionState.Predicting)));
        await rig.Clock.AdvanceAsync(590);
        Assert.True(rig.KeepAwake.IsHeld); // the app is still trying to reconnect
        await rig.Clock.AdvanceAsync(20);
        Assert.Equal([true, false], rig.KeepAwake.History);
    });

    [Fact]
    public void KeepAwakeStaysWhileAnyProbeCooksAndEndsOnUnfollowOrStop() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial, AF.Other));
        await rig.Engine.IngestAsync(AF.Snapshot(rig.Clock.Now(), AF.Serial, prediction: AF.Prediction(PredictionState.Predicting)));
        await rig.Engine.IngestAsync(AF.Snapshot(rig.Clock.Now(), AF.Other, prediction: AF.Prediction(PredictionState.Predicting)));
        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Other));
        Assert.True(rig.KeepAwake.IsHeld); // the other probe is still cooking
        await rig.Engine.SetFollowedAsync(AlertRig.Set());
        Assert.False(rig.KeepAwake.IsHeld);

        await rig.Engine.SetFollowedAsync(AlertRig.Set(AF.Serial));
        await rig.Engine.IngestAsync(AF.Snapshot(rig.Clock.Now(), AF.Serial, core: 30, prediction: AF.Prediction(PredictionState.Predicting)));
        Assert.True(rig.KeepAwake.IsHeld);
        await rig.Engine.StopAsync();
        Assert.False(rig.KeepAwake.IsHeld); // quitting releases the assertion
    });

    // Sinks

    [Fact]
    public void NotificationSinkPostsOnFireAndWithdrawsOnSnoozeAndClear() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot]);
        await rig.SnapshotAsync(core: 61);
        await rig.Engine.SnoozeAsync("hot", TimeSpan.FromSeconds(60));
        await rig.Clock.AdvanceAsync(61);
        await rig.SnapshotAsync(core: 20);
        Assert.Equal(["post hot", "withdraw hot", "post hot", "withdraw hot"], rig.Notifications.History);
    });

    [Fact]
    public void EventsReachTheSinksInOrder() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([Hot, new AlertRule("bat", new K.BatteryLow())]);
        await rig.SnapshotAsync(core: 61, battery: true);
        await rig.SnapshotAsync(core: 20, battery: false);
        Assert.Equal(
            new HashSet<string> { "bat idle->firing", "hot idle->firing", "bat firing->idle", "hot firing->idle" },
            rig.Transitions.ToHashSet());
        var firstClear = rig.Transitions.ToList().FindIndex(t => t.Contains("->idle"));
        if (firstClear < 0)
        {
            firstClear = 0;
        }
        Assert.All(rig.Transitions.Take(firstClear), t => Assert.Contains("idle->firing", t)); // fires before clears
    });
}
