namespace Combustion.Core.Tests;

using F = StoreFixtures;

/// <summary>docs/02 §7: the iOS <c>PredictionManager</c> rules, on a <see cref="TestClock"/>.</summary>
public class PredictionPresenterTests
{
    /// <summary>Create on the test's <see cref="DeterministicContext"/>.</summary>
    private sealed class Rig
    {
        public TestClock Clock { get; } = new();
        public ProbeStore Store { get; }
        public PredictionPresenter Presenter { get; }
        public Collector<PredictionView> Views { get; }

        public Rig()
        {
            Store = new ProbeStore(Clock);
            Presenter = new PredictionPresenter(Store, Clock);
            Views = Presenter.Predictions(F.Serial).Collect();
        }

        /// <summary>Feeds one status straight to the presenter, as the store's status stream would.</summary>
        public async Task StatusAsync(
            uint seconds, uint seq, PredictionState state = PredictionState.Predicting, PredictionType? type = null,
            PredictionMode mode = PredictionMode.TimeToRemoval, double setpoint = 60, double est = 40)
        {
            var p = F.Prediction(state, mode, setpoint, seconds, est);
            if (type is { } t)
            {
                p = p with { Type = t };
            }
            Presenter.Ingest(new ProbeStatusEvent(F.Serial, F.Status(logMax: seq, prediction: p), Clock.Now()));
            await Clock.SettleAsync();
        }

        public PredictionView? Latest => Views.Last;

        /// <summary>The view as of now, computed on demand (does not depend on a timer tick having been delivered yet).</summary>
        public PredictionView? Shown() => Presenter.View(F.Serial);

        public Task AdvanceAsync(double seconds) => Clock.AdvanceAsync(seconds);
    }

    // Above 300 s

    [Fact]
    public void AboveFiveMinutesRoundsTo15sAndMovesOnlyEveryThirdSeq() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(1000, 3);
        Assert.Equal(1005u, rig.Shown()?.SecondsRemaining); // nearest 15 s
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(995, 4);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(990, 5);
        Assert.Equal(1005u, rig.Shown()?.SecondsRemaining); // seq 4 and 5 do not move the number
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(985, 6);
        Assert.Equal(990u, rig.Shown()?.SecondsRemaining); // seq % 3 == 0
    });

    [Fact]
    public void FirstStatusSetsTheNumberEvenOffSequence() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(1234, 7);
        Assert.Equal(1230u, rig.Shown()?.SecondsRemaining);
    });

    [Fact]
    public void NilUnlessPredictingAndWithinFourHours() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(600, 0, PredictionState.Warming);
        Assert.Equal(PredictionState.Warming, rig.Shown()?.State);
        Assert.Null(rig.Shown()?.SecondsRemaining);
        await rig.StatusAsync(14_401, 1);
        Assert.Null(rig.Shown()?.SecondsRemaining);
        await rig.StatusAsync(14_400, 3);
        Assert.Equal(14_400u, rig.Shown()?.SecondsRemaining);
        await rig.StatusAsync(0, 4, PredictionState.RemovalPredictionDone);
        Assert.Null(rig.Shown()?.SecondsRemaining);
    });

    // At or below 300 s

    [Fact]
    public void BelowFiveMinutesCountsDownLinearlyBetweenStatuses() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(300, 0);
        Assert.Equal(300u, rig.Shown()?.SecondsRemaining);
        // Aims at raw - 5 s by the next status: one second per second.
        for (var elapsed = 1; elapsed <= 5; elapsed++)
        {
            await rig.AdvanceAsync(1);
            Assert.Equal((uint)(300 - elapsed), rig.Shown()?.SecondsRemaining);
        }
        // The next status confirms it; the countdown carries on.
        await rig.StatusAsync(295, 1);
        Assert.Equal(295u, rig.Shown()?.SecondsRemaining);
        await rig.AdvanceAsync(5);
        Assert.Equal(290u, rig.Shown()?.SecondsRemaining);
    });

    [Fact]
    public void CountdownStopsAtTheAimIfTheNextStatusIsLate() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(100, 0);
        await rig.AdvanceAsync(9);
        Assert.Equal(95u, rig.Shown()?.SecondsRemaining); // does not run on past raw - 5 s
    });

    [Fact]
    public void CountdownIsSmoothWhenEnteringTheLastFiveMinutes() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(315, 3);
        Assert.Equal(315u, rig.Shown()?.SecondsRemaining);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(310, 4); // still above 300: held
        Assert.Equal(315u, rig.Shown()?.SecondsRemaining);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(300, 5); // at 300: starts from what is on screen and eases to raw - 5
        Assert.Equal(315u, rig.Shown()?.SecondsRemaining);
        await rig.AdvanceAsync(5);
        Assert.Equal(295u, rig.Shown()?.SecondsRemaining);
    });

    // readyAt, readySince, stale, percent

    [Fact]
    public void ReadyAtIsCompletionTimeAndStaysPutWhileTheCountdownHolds() => Det.Run(async () =>
    {
        var rig = new Rig();
        var t0 = rig.Clock.Now();
        await rig.StatusAsync(1000, 3);
        Assert.Equal(t0.AddSeconds(1005), rig.Shown()?.ReadyAt);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(995, 4);
        Assert.Equal(t0.AddSeconds(1005), rig.Shown()?.ReadyAt); // held number, held completion time

        var low = new Rig();
        var t1 = low.Clock.Now();
        await low.StatusAsync(200, 0);
        Assert.Equal(t1.AddSeconds(200), low.Shown()?.ReadyAt);
        await low.AdvanceAsync(5);
        await low.StatusAsync(195, 1);
        Assert.Equal(t1.AddSeconds(200), low.Shown()?.ReadyAt); // the estimate did not move
    });

    [Fact]
    public void ReadySinceIsWhenTheStateBecameDone() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(5, 0);
        Assert.Null(rig.Shown()?.ReadySince);
        await rig.AdvanceAsync(5);
        var done = rig.Clock.Now();
        await rig.StatusAsync(0, 1, PredictionState.RemovalPredictionDone);
        Assert.Equal(done, rig.Shown()?.ReadySince);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(0, 2, PredictionState.RemovalPredictionDone);
        Assert.Equal(done, rig.Shown()?.ReadySince); // stays at the first done status
        await rig.StatusAsync(0, 3, PredictionState.Inserted, mode: PredictionMode.None);
        Assert.Null(rig.Shown()?.ReadySince);
    });

    [Fact]
    public void StaleAfterFifteenSecondsWithoutStatus() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(1000, 3);
        Assert.False(rig.Shown()?.IsStale);
        await rig.AdvanceAsync(14);
        Assert.False(rig.Shown()?.IsStale);
        await rig.AdvanceAsync(1);
        Assert.True(rig.Shown()?.IsStale);
        Assert.Equal(1005u, rig.Shown()?.SecondsRemaining); // the last known number stays
        await rig.StatusAsync(980, 6);
        Assert.False(rig.Shown()?.IsStale);
    });

    [Fact]
    public void PercentToRemovalComesFromTheStatus() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(600, 0, setpoint: 60, est: 40); // heat start 20: (40 - 20) / (60 - 20)
        Assert.Equal(50, rig.Shown()?.PercentToRemoval);
        Assert.Equal(60, rig.Shown()?.Setpoint);
        Assert.Equal(40, rig.Shown()?.EstimatedCore);
    });

    // Streams

    [Fact]
    public void StreamEmitsEachChangeOnceAndTheStaleFlip() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(100, 0);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(95, 1);
        await rig.AdvanceAsync(5);
        await rig.StatusAsync(90, 2);
        await rig.AdvanceAsync(20);
        await rig.Clock.SettleAsync();
        var items = rig.Views.Items;
        var numbers = items.Select(v => v.SecondsRemaining).ToList();
        Assert.Equal(100u, numbers[0]);
        Assert.Equal(85u, numbers[^1]); // ran on to raw - 5 s
        Assert.True(items.Zip(items.Skip(1)).All(p => p.First != p.Second), "no repeated emissions");
        Assert.True(numbers.Count >= 15, $"one emission per second of countdown, not per 200 ms tick: {numbers.Count}");
        Assert.True(numbers.Count <= 25);
        Assert.True(rig.Latest?.IsStale); // the stale flip is emitted too
        // A late subscriber gets the current view first.
        var (has, first) = await rig.Presenter.Predictions(F.Serial).NextAsync();
        Assert.True(has && first.IsStale);
    });

    [Fact]
    public void UpdatesCarryEveryProbe() => Det.Run(async () =>
    {
        var rig = new Rig();
        using var updates = rig.Presenter.Updates().Collect();
        await rig.Clock.SettleAsync();
        var other = new ProbeSerial(0x1000_0002);
        await rig.StatusAsync(1000, 3);
        rig.Presenter.Ingest(new ProbeStatusEvent(
            other, F.Status(logMax: 3, prediction: F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, seconds: 500)),
            rig.Clock.Now()));
        await rig.Clock.SettleAsync();
        Assert.Equal(new HashSet<ProbeSerial> { F.Serial, other }, updates.Items.Select(u => u.Serial).ToHashSet());
    });

    // Wiring

    [Fact]
    public void ReadsStatusesFromTheProbeStore() => Det.Run(async () =>
    {
        var rig = new Rig();
        rig.Presenter.Start();
        await rig.Clock.SettleAsync();
        var p = F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, 60, 900, 40);
        rig.Store.Ingest(F.Observe(F.St(F.Status(logMax: 3, prediction: p)), LinkKind.DirectConnection, rig.Clock.Now()));
        await rig.Clock.SettleAsync();
        Assert.Equal(900u, rig.Latest?.SecondsRemaining);
        Assert.Equal(900u, rig.Presenter.View(F.Serial)?.SecondsRemaining);
        rig.Presenter.Stop();
        rig.Store.Stop();
    });

    [Fact]
    public void IdleProbeCostsNoTicker() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.StatusAsync(1000, 3);
        Assert.Equal(1, rig.Clock.TimerCount); // only the 1 s stale watcher; no 200 ms ticker above five minutes
        Assert.Equal(0, rig.Clock.SleeperCount);
        await rig.AdvanceAsync(20);
        Assert.Equal(0, rig.Clock.TimerCount); // stale: nothing left to watch
        await rig.StatusAsync(1000, 3);
        Assert.Equal(1, rig.Clock.TimerCount);
        rig.Presenter.Stop();
        await rig.Clock.SettleAsync();
        Assert.Equal(0, rig.Clock.TimerCount);
    });

    // Matches the Display (M5 exit criterion, unit level)

    /// <summary>The probe counts down 1 s per second and reports every 5 s. The Display rounds to 15 s and moves every
    /// third status, so against the probe's own number it is off by up to 7.5 s (rounding) plus 15 s (held for three
    /// statuses) = 22.5 s; the last five minutes follow the probe to within a few seconds. Matching the Display's
    /// rounding is the point (02 §7); this pins the error that rounding implies.</summary>
    [Fact]
    public void CountdownTracksTheProbeOverACook() => Det.Run(async () =>
    {
        var rig = new Rig();
        const int total = 2400;
        var worst = 0.0;
        var worstLast5 = 0.0;
        var detail = "";
        for (var second = 0; second < total; second++)
        {
            if (second % 5 == 0)
            {
                await rig.StatusAsync((uint)(total - second), (uint)(second / 5));
            }
            if (rig.Shown()?.SecondsRemaining is { } shown)
            {
                var error = Math.Abs((double)shown - (total - second));
                worst = Math.Max(worst, error);
                if (total - second <= 290)
                {
                    if (error > worstLast5)
                    {
                        detail = $"second {second}: shown {shown}, truth {total - second}";
                    }
                    worstLast5 = Math.Max(worstLast5, error);
                }
            }
            await rig.AdvanceAsync(1);
        }
        Assert.True(worst <= 22.5, $"worst error {worst} s");
        Assert.True(worstLast5 <= 6, $"worst error in the last five minutes {worstLast5} s ({detail})");
        Assert.NotNull(rig.Shown()?.SecondsRemaining);
    });
}
