using Combustion.Sim;
using static Combustion.Core.Tests.EndToEnd.E2E;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>M5 exit: the countdown matches the Display; set prediction, set alarms and silence are confirmed by status.</summary>
public sealed class M5PredictionAndCommandsTests
{
    /// <summary>A followed, connected probe with a few statuses behind it.</summary>
    private static async Task<(E2ERig Rig, SimulatedProbe Probe)> ConnectedRigAsync(double offset = 0, double lead = 600)
    {
        var rig = new E2ERig();
        var probe = rig.Probe(SerialA, preload: 20, offset: offset);
        probe.PredictionLeadSeconds = lead;
        await rig.App.StartAsync();
        await rig.App.FollowAsync(SerialA);
        Assert.True(await rig.RunUntilAsync(() => rig.Connected(SerialA), limit: 20));
        await rig.RunAsync(10);
        return (rig, probe);
    }

    private static Alarm High(AlarmConfig? c, AlarmChannel ch) => c?.High.GetValueOrDefault(ch) ?? default;

    private static Alarm Low(AlarmConfig? c, AlarmChannel ch) => c?.Low.GetValueOrDefault(ch) ?? default;

    [Fact]
    public void SetPredictionIsConfirmedAndTheCountdownMatchesTheProbeOverTheWholeCook() => Det.Run(async () =>
    {
        var (rig, probe) = await ConnectedRigAsync(lead: 1200);
        using var _ = rig;
        using var views = rig.App.Predictions(SerialA).Collect();

        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 63);
        var (setpoint, mode) = probe.CurrentPrediction;
        Assert.Equal(63, setpoint);
        Assert.Equal(PredictionMode.TimeToRemoval, mode);
        Assert.Contains(new UartRequest.SetPrediction(63, PredictionMode.TimeToRemoval), probe.Requests);

        // Sample the presented number each second against the probe's own countdown (what its Display shows).
        var worst = 0.0;
        var worstLast5 = 0.0;
        var checkedCount = 0;
        for (var i = 0; i < 1230; i++)
        {
            await rig.RunAsync(1, step: 1);
            var truth = probe.CurrentPredictionState.SecondsRemaining;
            if (views.Last is { State: PredictionState.Predicting, SecondsRemaining: { } shown })
            {
                var error = Math.Abs(shown - truth);
                worst = Math.Max(worst, error);
                if (truth <= 290)
                {
                    worstLast5 = Math.Max(worstLast5, error);
                }
                checkedCount++;
            }
        }
        Assert.True(checkedCount > 1100);
        // Rounding to 15 s (7.5) plus holding for three statuses (15) bounds the error; the last five minutes
        // follow the probe closely.
        Assert.True(worst <= 22.5, $"worst {worst} s");
        Assert.True(worstLast5 <= 6, $"worst in the last five minutes {worstLast5} s");

        // The cook ends: Ready is exposed with the time it started.
        var done = views.Last!;
        Assert.Equal(PredictionState.RemovalPredictionDone, done.State);
        Assert.Null(done.SecondsRemaining);
        Assert.NotNull(done.ReadySince);
        Assert.True(Math.Abs(done.ReadySince.Value.Since(TestClock.DefaultStart.AddSecondsExact(10 + 1200))) < 40);
        await rig.App.StopAsync();
    });

    [Fact]
    public void CountdownCarriesAReadyAtThatMatchesTheEnd() => Det.Run(async () =>
    {
        var (rig, _) = await ConnectedRigAsync(lead: 900);
        using var r = rig;
        using var views = rig.App.Predictions(SerialA).Collect();
        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        var startedAt = rig.Clock.Now();
        await rig.RunAsync(30);
        var readyAt = views.Last?.ReadyAt;
        Assert.NotNull(readyAt);
        Assert.True(Math.Abs(readyAt.Value.Since(startedAt.AddSecondsExact(900))) <= 20);
        await rig.App.StopAsync();
    });

    [Fact]
    public void RemovalAndRestingRunsThroughBothCountdowns() => Det.Run(async () =>
    {
        var (rig, probe) = await ConnectedRigAsync(lead: 60);
        using var _ = rig;
        probe.RestingSeconds = 40;
        using var views = rig.App.Predictions(SerialA).Collect();
        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.RemovalAndResting, 60);
        await rig.RunAsync(130, step: 1);
        var collapsed = new List<string>();
        foreach (var s in views.Items.Select(v => $"{v.State}/{v.Type}"))
        {
            if (collapsed.Count == 0 || collapsed[^1] != s)
            {
                collapsed.Add(s);
            }
        }
        Assert.Contains("Predicting/Removal", collapsed);
        Assert.Contains("RemovalPredictionDone/Removal", collapsed);
        Assert.Contains("Predicting/Resting", collapsed);
        Assert.Equal("RemovalPredictionDone/Resting", collapsed[^1]);
        await rig.App.StopAsync();
    });

    [Fact]
    public void CancelPredictionEndsIt() => Det.Run(async () =>
    {
        var (rig, probe) = await ConnectedRigAsync();
        using var _ = rig;
        await rig.App.Commands.SetPredictionAsync(SerialA, PredictionMode.TimeToRemoval, 60);
        await rig.App.Commands.CancelPredictionAsync(SerialA);
        Assert.Equal(PredictionMode.None, probe.CurrentPrediction.Mode);
        Assert.Equal(PredictionState.NotInserted, probe.CurrentPredictionState.State);
        await rig.App.StopAsync();
    });

    [Fact]
    public void SetAlarmsAreConfirmedKeepOthersAndSurviveAnotherSet() => Det.Run(async () =>
    {
        var (rig, probe) = await ConnectedRigAsync();
        using var _ = rig;
        await rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Core, AlarmKind.High, 90.5);
        await rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Ambient, AlarmKind.Low, 120);
        var alarms = probe.CurrentAlarms;
        Assert.True(High(alarms, AlarmChannel.Core).IsSet);
        Assert.True(Math.Abs(High(alarms, AlarmChannel.Core).Temperature - 90.5) < 0.06);
        Assert.True(Low(alarms, AlarmChannel.Ambient).IsSet);
        Assert.True(High(alarms, AlarmChannel.Core).IsSet, "the second write carried the first alarm along");

        // The app's own snapshot shows what the probe reported.
        var seen = rig.App.Probes.Snapshot(SerialA)?.Alarms;
        Assert.True(High(seen, AlarmChannel.Core).IsSet && Low(seen, AlarmChannel.Ambient).IsSet);

        await rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Core, AlarmKind.High, null);
        Assert.False(High(probe.CurrentAlarms, AlarmChannel.Core).IsSet);
        Assert.True(Low(probe.CurrentAlarms, AlarmChannel.Ambient).IsSet);
        await rig.App.StopAsync();
    });

    [Fact]
    public void AlarmTripsAndSilenceIsConfirmedByStatus() => Det.Run(async () =>
    {
        // The ambient sensors lead the cook, so a 30 °C ambient alarm trips within about a minute.
        var (rig, probe) = await ConnectedRigAsync(offset: 0);
        using var _ = rig;
        await rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Ambient, AlarmKind.High, 30);
        var alarming = await rig.RunUntilAsync(
            () => High(rig.App.Probes.Snapshot(SerialA)?.Alarms, AlarmChannel.Ambient).Alarming, limit: 300, step: 5);
        Assert.True(alarming, "the probe reports the trip in its status");
        Assert.True(High(probe.CurrentAlarms, AlarmChannel.Ambient).Tripped);

        await rig.App.Commands.SilenceAlarmsAsync(SerialA);
        Assert.Contains(probe.Requests, r => r is UartRequest.SilenceAlarms);
        Assert.False(High(probe.CurrentAlarms, AlarmChannel.Ambient).Alarming);
        Assert.False(High(rig.App.Probes.Snapshot(SerialA)?.Alarms, AlarmChannel.Ambient).Alarming);
        await rig.App.StopAsync();
    });

    [Fact]
    public void CommandsToAnUnconnectedProbeAreNotReachable() => Det.Run(async () =>
    {
        using var rig = new E2ERig();
        _ = rig.Probe(SerialA);
        await rig.App.StartAsync();
        var e = await Assert.ThrowsAsync<CommandException>(() => rig.App.Commands.SilenceAlarmsAsync(SerialA));
        Assert.Equal(CommandErrorKind.NotReachable, e.Kind);
        await rig.App.StopAsync();
    });

    [Fact]
    public void ADeadLinkMidCommandIsAnErrorNotAHang() => Det.Run(async () =>
    {
        var (rig, probe) = await ConnectedRigAsync();
        using var _ = rig;
        probe.SetInRange(false);
        await rig.DrainAsync();
        var result = rig.App.Commands.SetAlarmAsync(SerialA, AlarmChannel.Core, AlarmKind.High, 70);
        var spent = 0.0;
        while (spent < 30)
        {
            await rig.Clock.AdvanceAsync(0.5);
            spent += 0.5;
            if (!rig.Connected(SerialA))
            {
                break;
            }
        }
        await rig.Clock.SettleAsync();
        Assert.True(result.IsCompleted, "the command finished once the link was gone");
        if (result.Exception?.InnerException is { } e)
        {
            var kind = Assert.IsType<CommandException>(e).Kind;
            Assert.Contains(kind, new[] { CommandErrorKind.NotReachable, CommandErrorKind.Uart, CommandErrorKind.NotConfirmed });
        }
        await rig.App.StopAsync();
    });
}
