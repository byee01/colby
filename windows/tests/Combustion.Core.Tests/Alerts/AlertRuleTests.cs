namespace Combustion.Core.Tests;

using K = AlertRuleKind;

/// <summary>One section per rule type of docs/02 §9: it fires, it clears, and it only fires once per crossing.</summary>
public class AlertRuleTests
{
    private static readonly string Hex = AF.Serial.Hex;

    // temperatureAbove / temperatureBelow

    [Fact]
    public void TemperatureAboveFiresAtTheThresholdAndClearsBelowTheHysteresis() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("hot", new K.TemperatureAbove(AlarmChannel.Core, 60, 2))]);

        await rig.SnapshotAsync(core: 59.9);
        Assert.Empty(rig.Active());
        await rig.SnapshotAsync(core: 60);
        Assert.Equal(AlertState.Firing, rig.State("hot"));
        Assert.Equal(60, rig.Active().First().Value);

        // Hovering inside the hysteresis band neither clears nor fires again.
        await rig.SnapshotAsync(core: 58.5);
        await rig.SnapshotAsync(core: 60.5);
        await rig.SnapshotAsync(core: 58.1);
        Assert.Equal(AlertState.Firing, rig.State("hot"));
        Assert.Equal(["hot idle->firing"], rig.Transitions);

        await rig.SnapshotAsync(core: 57.9);
        Assert.Empty(rig.Active());
        Assert.Equal(["hot idle->firing", "hot firing->idle"], rig.Transitions);

        // Re-armed after the clear: the next crossing fires again.
        await rig.SnapshotAsync(core: 61);
        Assert.Equal(["hot idle->firing"], rig.Transitions.TakeLast(1));
    });

    [Fact]
    public void TemperatureBelowFiresAtTheThresholdAndClearsAboveTheHysteresis() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("cold", new K.TemperatureBelow(AlarmChannel.Ambient, 100, 3))]);
        await rig.SnapshotAsync(ambient: 105);
        Assert.Empty(rig.Active());
        await rig.SnapshotAsync(ambient: 100);
        Assert.Equal(AlertState.Firing, rig.State("cold"));
        await rig.SnapshotAsync(ambient: 102.9);
        Assert.Equal(AlertState.Firing, rig.State("cold"));
        await rig.SnapshotAsync(ambient: 103.1);
        Assert.Empty(rig.Active());
    });

    [Fact]
    public void TemperatureRuleWorksOnAnyChannel() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([
            new AlertRule("t3", new K.TemperatureAbove(AlarmChannel.T3, 50)),
            new AlertRule("surface", new K.TemperatureAbove(AlarmChannel.Surface, 90)),
        ]);
        await rig.SnapshotAsync(core: 30, surface: 91, t3: 51);
        Assert.Equal(new HashSet<string> { "t3", "surface" }, rig.Active().Select(a => a.Id).ToHashSet());
    });

    [Fact]
    public void MissingReadingLeavesTheAlertAlone() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("hot", new K.TemperatureAbove(AlarmChannel.Surface, 60))]);
        await rig.SnapshotAsync(surface: 70);
        Assert.Equal(AlertState.Firing, rig.State("hot"));
        await rig.SnapshotAsync(surface: null); // Instant Read style gap: no value, no verdict
        Assert.Equal(AlertState.Firing, rig.State("hot"));
        await rig.SnapshotAsync(surface: 50);
        Assert.Empty(rig.Active());
    });

    // predictionWithin

    [Fact]
    public void PredictionWithinFiresAtNSecondsAndClearsWhenTheCountdownGoesAway() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("five", new K.PredictionWithin(300))]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(seconds: 600));
        Assert.Empty(rig.Active());
        await rig.ViewAsync(AF.View(seconds: 301));
        Assert.Empty(rig.Active());
        await rig.ViewAsync(AF.View(seconds: 300));
        Assert.Equal(AlertState.Firing, rig.State("five"));
        Assert.Equal(300, rig.Active().First().Value);

        // A re-estimate that nudges the number back up by one rounding step does not clear it.
        await rig.ViewAsync(AF.View(seconds: 310));
        Assert.Equal(AlertState.Firing, rig.State("five"));
        // A big jump (prediction restarted) does.
        await rig.ViewAsync(AF.View(seconds: 900));
        Assert.Empty(rig.Active());
        await rig.ViewAsync(AF.View(seconds: 250));
        Assert.Equal(["five idle->firing", "five firing->idle", "five idle->firing"], rig.Transitions);
    });

    [Fact]
    public void PredictionWithinIgnoresStaleViews() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("five", new K.PredictionWithin(300))]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(seconds: 100, stale: true));
        Assert.Empty(rig.Active()); // a frozen number is not news
        await rig.ViewAsync(AF.View(seconds: 100));
        Assert.Equal(AlertState.Firing, rig.State("five"));
        await rig.ViewAsync(AF.View(seconds: 100, stale: true));
        Assert.Equal(AlertState.Firing, rig.State("five")); // and not a reason to clear either
    });

    [Fact]
    public void PredictionWithinClearsWhenPredictionEnds() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("five", new K.PredictionWithin(300))]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(seconds: 200));
        Assert.Equal(AlertState.Firing, rig.State("five"));
        await rig.ViewAsync(AF.View(state: PredictionState.RemovalPredictionDone, seconds: null));
        Assert.Empty(rig.Active());
    });

    // predictionDone (latches)

    [Fact]
    public void PredictionDoneFiresWhenRemovalIsDoneAndStaysUntilAcknowledged() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("ready", new K.PredictionDone())]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(seconds: 20));
        Assert.Empty(rig.Active());
        await rig.ViewAsync(AF.View(state: PredictionState.RemovalPredictionDone, seconds: null));
        Assert.Equal(AlertState.Firing, rig.State("ready"));
        Assert.Equal(AlertSound.Ready, rig.Sound.Playing["ready"]);

        // The state moves on (probe pulled, resting starts): the alert still stands and the sound keeps looping.
        await rig.ViewAsync(AF.View(state: PredictionState.Predicting, type: PredictionType.Resting, seconds: 300));
        Assert.Equal(AlertState.Firing, rig.State("ready"));
        Assert.Equal(AlertSound.Ready, rig.Sound.Playing["ready"]);

        await rig.Engine.AcknowledgeAsync("ready");
        Assert.Equal(AlertState.Acknowledged, rig.State("ready"));
        Assert.Empty(rig.Sound.Playing);
        // Acknowledged and the condition is gone: it clears.
        await rig.ViewAsync(AF.View(state: PredictionState.Predicting, type: PredictionType.Resting, seconds: 290));
        Assert.Empty(rig.Active());
        Assert.Equal(["ready idle->firing", "ready firing->acknowledged", "ready acknowledged->idle"], rig.Transitions);
    });

    [Fact]
    public void PredictionDoneIsNotTheRestingPhase() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("ready", new K.PredictionDone())]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(state: PredictionState.RemovalPredictionDone, type: PredictionType.Resting, seconds: null));
        Assert.Empty(rig.Active());
    });

    // restingDone

    [Fact]
    public void RestingDoneFiresWhenTheRestingPredictionReachesZero() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("rest", new K.RestingDone())]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(type: PredictionType.Resting, seconds: 120));
        Assert.Empty(rig.Active());
        await rig.ViewAsync(AF.View(type: PredictionType.Resting, seconds: 0));
        Assert.Equal(AlertState.Firing, rig.State("rest"));
        Assert.Equal(AlertSound.Ready, rig.Sound.Playing["rest"]);
        await rig.Engine.AcknowledgeAsync("rest");
        await rig.ViewAsync(AF.View(state: PredictionState.RemovalPredictionDone, type: PredictionType.Resting, seconds: null));
        Assert.Equal(AlertState.Acknowledged, rig.State("rest")); // still done: stays in the list
    });

    [Fact]
    public void RestingDoneAlsoOnTheDoneState() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("rest", new K.RestingDone())]);
        await rig.SnapshotAsync();
        await rig.ViewAsync(AF.View(type: PredictionType.Removal, seconds: 0));
        Assert.Empty(rig.Active()); // a removal countdown at 0 is not resting
        await rig.ViewAsync(AF.View(state: PredictionState.RemovalPredictionDone, type: PredictionType.Resting, seconds: null));
        Assert.Equal(AlertState.Firing, rig.State("rest"));
    });

    // ambientOutOfRange (sustain)

    [Fact]
    public void AmbientOutOfRangeFiresOnlyAfterTheSustainTime() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("amb", new K.AmbientOutOfRange(100, 150, 120))]);
        await rig.SnapshotAsync(ambient: 125);
        await rig.SnapshotAsync(ambient: 160);
        Assert.Empty(rig.Active());
        // No new reading needed: the clock alone brings it due.
        await rig.Clock.AdvanceAsync(119);
        Assert.Empty(rig.Active());
        await rig.Clock.AdvanceAsync(2);
        Assert.Equal(AlertState.Firing, rig.State("amb"));
        Assert.Equal(160, rig.Active().First().Value);
    });

    [Fact]
    public void AmbientBlipThatReturnsToRangeStartsTheSustainOver() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("amb", new K.AmbientOutOfRange(100, 150, 120))]);
        await rig.SnapshotAsync(ambient: 160);
        await rig.Clock.AdvanceAsync(100);
        await rig.SnapshotAsync(ambient: 140); // back inside: the clock restarts
        await rig.Clock.AdvanceAsync(10);
        await rig.SnapshotAsync(ambient: 80); // below min this time
        await rig.Clock.AdvanceAsync(100);
        Assert.Empty(rig.Active()); // only 100 s of the new excursion
        await rig.Clock.AdvanceAsync(21);
        Assert.Equal(AlertState.Firing, rig.State("amb"));
        await rig.SnapshotAsync(ambient: 120);
        Assert.Empty(rig.Active());
    });

    // stall

    [Fact]
    public void StallFiresWhenTheCoreBarelyRoseOverTheWindowWhilePredicting() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("stall", new K.Stall(1800, 2))]);
        var predicting = AF.Prediction(PredictionState.Predicting);
        await rig.SnapshotAsync(core: 65, prediction: predicting);
        for (var i = 0; i < 4; i++)
        {
            await rig.Clock.AdvanceAsync(360);
            await rig.SnapshotAsync(core: 65.5, prediction: predicting);
        }
        Assert.Empty(rig.Active()); // 24 min of history: the window is not covered yet
        await rig.Clock.AdvanceAsync(360);
        await rig.SnapshotAsync(core: 65.6, prediction: predicting);
        Assert.Equal(AlertState.Firing, rig.State("stall")); // 30 min, rose 0.6 °C
        Assert.True((rig.Active().FirstOrDefault()?.Value ?? 9) < 2);

        // The core moves again: it clears.
        await rig.Clock.AdvanceAsync(300);
        await rig.SnapshotAsync(core: 75, prediction: predicting);
        Assert.Empty(rig.Active());
    });

    [Fact]
    public void StallDoesNotFireWhenTheCoreIsRisingOrNotPredicting() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("stall", new K.Stall(1800, 2))]);
        var predicting = AF.Prediction(PredictionState.Predicting);
        var core = 40.0;
        for (var i = 0; i < 8; i++)
        {
            await rig.SnapshotAsync(core: core, prediction: predicting);
            await rig.Clock.AdvanceAsync(300);
            core += 1;
        }
        Assert.Empty(rig.Active()); // rising 1 °C per 5 min

        var idle = new AlertRig();
        await idle.FollowAsync([new AlertRule("stall", new K.Stall(600, 2))]);
        await idle.SnapshotAsync(core: 65, prediction: AF.Prediction(PredictionState.Inserted));
        await idle.Clock.AdvanceAsync(900);
        await idle.SnapshotAsync(core: 65, prediction: AF.Prediction(PredictionState.Inserted));
        Assert.Empty(idle.Active()); // a plateau with no prediction is just a probe sitting there
    });

    // probeOffline

    [Fact]
    public void ProbeOfflineFiresAfterNSecondsWithoutASourceAndClearsWhenDataReturns() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("off", new K.ProbeOffline(60))]);
        await rig.SnapshotAsync();
        var lastData = rig.Clock.Now();
        await rig.Clock.AdvanceAsync(10);
        // The store drops the last source 10 s after the last data and shows the probe offline.
        await rig.Engine.IngestAsync(AF.Snapshot(lastData, offline: true));
        Assert.Empty(rig.Active());
        await rig.Clock.AdvanceAsync(49);
        Assert.Empty(rig.Active());
        await rig.Clock.AdvanceAsync(2);
        Assert.Equal(AlertState.Firing, rig.State("off")); // 60 s after the last data

        await rig.SnapshotAsync();
        Assert.Empty(rig.Active());
        Assert.Equal(["off idle->firing", "off firing->idle"], rig.Transitions);
    });

    [Fact]
    public void ProbeOfflineDuringCookOnlyIgnoresAProbeThatWasNotCooking() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("off", new K.ProbeOffline(60, OnlyDuringCook: true))]);
        await rig.SnapshotAsync(core: 22); // sitting on the counter
        await rig.Engine.IngestAsync(AF.Snapshot(rig.Clock.Now(), core: 22, offline: true));
        await rig.Clock.AdvanceAsync(120);
        Assert.Empty(rig.Active());

        var cook = new AlertRig();
        await cook.FollowAsync([new AlertRule("off", new K.ProbeOffline(60, OnlyDuringCook: true))]);
        await cook.SnapshotAsync(prediction: AF.Prediction(PredictionState.Predicting));
        var last = cook.Clock.Now();
        await cook.Clock.AdvanceAsync(10);
        await cook.Engine.IngestAsync(AF.Snapshot(last, offline: true, prediction: AF.Prediction(PredictionState.Predicting)));
        await cook.Clock.AdvanceAsync(51);
        Assert.Equal(AlertState.Firing, cook.State("off"));
    });

    // batteryLow

    [Fact]
    public void BatteryLowFiresAndClears() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([new AlertRule("bat", new K.BatteryLow())]);
        await rig.SnapshotAsync();
        Assert.Empty(rig.Active());
        await rig.SnapshotAsync(battery: true);
        Assert.Equal(AlertState.Firing, rig.State("bat"));
        await rig.SnapshotAsync(core: 26, battery: true);
        Assert.Equal(["bat idle->firing"], rig.Transitions); // once per crossing
        await rig.SnapshotAsync(battery: false);
        Assert.Empty(rig.Active());
    });

    // Probe alarms and overheat

    [Fact]
    public void ProbeAlarmFiresWhenAlarmingGoesTrueOnAnyChannel() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core, temperature: 70, on: false));
        Assert.Empty(rig.Active()); // set and not alarming
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.Low, AlarmChannel.Surface, temperature: 30));
        var alert = rig.Active().FirstOrDefault();
        Assert.Equal($"{Hex}.alarm.low.surface", alert?.Id);
        Assert.Equal(new AlertSource.ProbeAlarm(AlarmKind.Low, AlarmChannel.Surface), alert?.Source);
        Assert.Equal(AlertPriority.ProbeAlarm, alert?.Priority);
        Assert.Equal(AlertSound.ProbeAlarm, rig.Sound.Playing.GetValueOrDefault(alert?.Id ?? ""));
        Assert.Single(rig.Notifications.Visible);

        // Silenced on the Display or phone: the bit drops and the alert clears here too.
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.Low, AlarmChannel.Surface, temperature: 30, on: false));
        Assert.Empty(rig.Active());
        Assert.True(rig.Sound.Playing.Count == 0 && rig.Notifications.Visible.Count == 0);
    });

    [Fact]
    public void OverheatBitFiresPerSensorAndClears() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(overheating: SensorSet.Of(SensorIndex.T2, SensorIndex.T7));
        var ids = rig.Active().Select(a => a.Id).ToHashSet();
        Assert.Equal(new HashSet<string> { $"{Hex}.overheat.t2", $"{Hex}.overheat.t7" }, ids);
        Assert.All(rig.Active(), a => Assert.Equal(AlertPriority.Overheat, a.Priority));
        await rig.SnapshotAsync(overheating: SensorSet.Of(SensorIndex.T7));
        Assert.Equal(new HashSet<string> { $"{Hex}.overheat.t7" }, rig.Active().Select(a => a.Id).ToHashSet());
        await rig.SnapshotAsync(overheating: SensorSet.Empty);
        Assert.Empty(rig.Active());
    });

    [Fact]
    public void ProbeAlarmsClearWhileTheProbeIsOffline() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        await rig.FollowAsync([]);
        await rig.SnapshotAsync(alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core), overheating: SensorSet.Of(SensorIndex.T1));
        Assert.Equal(2, rig.Active().Count);
        await rig.SnapshotAsync(offline: true, alarms: AF.Alarming(AlarmKind.High, AlarmChannel.Core), overheating: SensorSet.Of(SensorIndex.T1));
        Assert.Empty(rig.Active()); // an offline probe's bits say nothing current; probeOffline covers it
    });
}
