namespace Combustion.Core.Tests;

using K = AlertRuleKind;

/// <summary>Alert rules and the alert log in SQLite (docs/02 §11).</summary>
public class SqliteAlertStoreTests
{
    private static readonly ValueList<AlertRule> EveryKind =
    [
        new("a", new K.TemperatureAbove(AlarmChannel.Core, 95, 0.5)),
        new("b", new K.TemperatureBelow(AlarmChannel.Ambient, 107.2), Enabled: false),
        new("c", new K.PredictionWithin(300)),
        new("d", new K.PredictionDone()),
        new("e", new K.RestingDone()),
        new("f", new K.AmbientOutOfRange(107, 135, 300)),
        new("g", new K.Stall(1800, 1.1)),
        new("h", new K.ProbeOffline(60, OnlyDuringCook: true)),
        new("i", new K.BatteryLow()),
    ];

    private static string TempPath() => Path.Combine(Path.GetTempPath(), $"colby-{Guid.NewGuid()}.sqlite");

    private static void Remove(string path)
    {
        foreach (var p in new[] { path, path + "-wal", path + "-shm" })
        {
            try
            {
                File.Delete(p);
            }
            catch (IOException)
            {
            }
        }
    }

    [Fact]
    public void EveryRuleKindRoundTripsInOrderWithItsEnabledFlag() => Det.Run(async () =>
    {
        using var store = new SqliteAlertStore(":memory:");
        await store.SaveRulesAsync(EveryKind, AF.Serial);
        Assert.Equal(EveryKind, await store.LoadRulesAsync(AF.Serial));
        Assert.Null(store.LastError);
    });

    /// <summary>The <c>params_json</c> column holds what Swift's JSONEncoder (<c>.sortedKeys</c>) writes, so the
    /// table is interchangeable between the two apps.</summary>
    [Fact]
    public void ParamsJsonHasTheSwiftShape()
    {
        string? Json(K kind) => AlertRuleCoding.Encode(kind).Params;
        Assert.Equal("""{"celsius":95,"channel":8,"hysteresis":0.5}""", Json(new K.TemperatureAbove(AlarmChannel.Core, 95, 0.5)));
        Assert.Equal("""{"seconds":300}""", Json(new K.PredictionWithin(300)));
        Assert.Equal("""{"max":135,"min":107,"sustain":300}""", Json(new K.AmbientOutOfRange(107, 135, 300)));
        Assert.Equal("""{"minRise":1.1,"window":1800}""", Json(new K.Stall(1800, 1.1)));
        Assert.Equal("""{"onlyDuringCook":true,"seconds":60}""", Json(new K.ProbeOffline(60, true)));
        Assert.Null(Json(new K.PredictionDone()));
        Assert.Equal(new K.TemperatureBelow(AlarmChannel.Ambient, 107.2), AlertRuleCoding.Decode("temperatureBelow", """{"celsius":107.2,"channel":10}"""));
        Assert.Equal(new K.Stall(1800, 2), AlertRuleCoding.Decode("stall", """{"minRise":2}"""));
        Assert.Null(AlertRuleCoding.Decode("temperatureAbove", "not json"));
    }

    [Fact]
    public void AnUnconfiguredProbeIsNilButAnEmptyListStaysEmpty() => Det.Run(async () =>
    {
        using var store = new SqliteAlertStore(":memory:");
        Assert.Null(await store.LoadRulesAsync(AF.Serial)); // null means: seed the defaults
        await store.SaveRulesAsync([], AF.Serial);
        Assert.Equal(ValueList<AlertRule>.Empty, await store.LoadRulesAsync(AF.Serial)); // the user removed every rule; do not re-seed
        Assert.Null(await store.LoadRulesAsync(AF.Other));
    });

    [Fact]
    public void SavingReplacesTheProbesRulesAndLeavesOtherProbesAlone() => Det.Run(async () =>
    {
        using var store = new SqliteAlertStore(":memory:");
        await store.SaveRulesAsync(new ValueList<AlertRule>(EveryKind.Take(3)), AF.Serial);
        await store.SaveRulesAsync([new AlertRule("x", new K.BatteryLow())], AF.Other);
        await store.SaveRulesAsync([EveryKind[4], EveryKind[0]], AF.Serial);
        Assert.Equal([EveryKind[4], EveryKind[0]], await store.LoadRulesAsync(AF.Serial));
        Assert.Equal([new AlertRule("x", new K.BatteryLow())], await store.LoadRulesAsync(AF.Other));
    });

    [Fact(Skip = "Needs HistoryStore (parallel port)")]
    public void RulesSurviveAReopenAndShareTheFileWithHistory() => Det.Run(async () =>
    {
#if HISTORY_STORE
        var path = TempPath();
        try
        {
            using (new HistoryStore(path, new TestClock()))
            {
            }
            using (var store = new SqliteAlertStore(path))
            {
                await store.SaveRulesAsync(EveryKind, AF.Serial);
            }
            using var reopened = new SqliteAlertStore(path);
            Assert.Equal(EveryKind, await reopened.LoadRulesAsync(AF.Serial));
        }
        finally
        {
            Remove(path);
        }
#else
        await Task.CompletedTask;
#endif
    });

    [Fact]
    public void TheEngineSeedsDefaultsOnceAndARestartedEngineKeepsTheEdits() => Det.Run(async () =>
    {
        var path = TempPath();
        try
        {
            ValueList<AlertRule> defaults;
            using (var firstStore = new SqliteAlertStore(path))
            {
                var first = new AlertEngine(new TestClock(), firstStore, defaultRules: AlertRule.Defaults);
                await first.SetFollowedAsync(AlertRig.Set(AF.Serial));
                defaults = await first.RulesAsync(AF.Serial);
                Assert.Equal(AlertRule.Defaults(AF.Serial), defaults);
                await first.RemoveRuleAsync(AF.Serial, defaults[1].Id);
            }

            using var secondStore = new SqliteAlertStore(path);
            var second = new AlertEngine(new TestClock(), secondStore, defaultRules: AlertRule.Defaults);
            await second.SetFollowedAsync(AlertRig.Set(AF.Serial));
            Assert.Equal(defaults.Where(r => r.Id != defaults[1].Id), await second.RulesAsync(AF.Serial));
        }
        finally
        {
            Remove(path);
        }
    });

    // Alert log

    private static AlertEvent Event(string id, AlertState from, AlertState to, DateTimeOffset firedAt, DateTimeOffset at) =>
        new(new AlertInstance(id, AF.Serial, new AlertSource.Rule(new K.PredictionDone()), to, firedAt, Value: 93.5), from, to, at);

    [Fact]
    public void OneFiringIsOneRowWithItsAcknowledgeAndClearTimes()
    {
        using var store = new SqliteAlertStore(":memory:");
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000);
        store.Record(Event("r", AlertState.Idle, AlertState.Firing, t0, t0));
        store.Record(Event("r", AlertState.Firing, AlertState.Snoozed, t0, t0.AddSeconds(10)));
        store.Record(Event("r", AlertState.Snoozed, AlertState.Firing, t0, t0.AddSeconds(310)));
        store.Record(Event("r", AlertState.Firing, AlertState.Acknowledged, t0, t0.AddSeconds(320)));
        store.Record(Event("r", AlertState.Acknowledged, AlertState.Idle, t0, t0.AddSeconds(900)));

        var log = store.Events(AF.Serial, t0.AddSeconds(-1), t0.AddSeconds(1000));
        Assert.Equal([new AlertLogEntry("r", AF.Serial, t0, t0.AddSeconds(320), t0.AddSeconds(900), 93.5)], log);
    }

    [Fact]
    public void ASecondCrossingIsASecondRow()
    {
        using var store = new SqliteAlertStore(":memory:");
        var t0 = DateTimeOffset.FromUnixTimeSeconds(1_760_000_000);
        store.Record(Event("r", AlertState.Idle, AlertState.Firing, t0, t0));
        store.Record(Event("r", AlertState.Firing, AlertState.Idle, t0, t0.AddSeconds(60)));
        store.Record(Event("r", AlertState.Idle, AlertState.Firing, t0.AddSeconds(120), t0.AddSeconds(120)));
        var log = store.Events(AF.Serial, t0, t0.AddSeconds(200));
        Assert.Equal([t0, t0.AddSeconds(120)], log.Select(e => e.FiredAt));
        Assert.Equal([t0.AddSeconds(60), null], log.Select(e => e.ClearedAt));
    }

    [Fact]
    public void TheAppLogsWhatTheEngineFires() => Det.Run(async () =>
    {
        var rig = new AlertRig();
        using var store = new SqliteAlertStore(":memory:");
        using var cts = new CancellationTokenSource();
        var consumer = store.ConsumeAsync(rig.Engine.Events(), cts.Token);

        await rig.FollowAsync([new AlertRule("hot", new K.TemperatureAbove(AlarmChannel.Core, 60))]);
        var fired = rig.Clock.Now();
        await rig.SnapshotAsync(core: 61);
        await rig.Clock.AdvanceAsync(30);
        await rig.Engine.AcknowledgeAsync("hot");
        await rig.Clock.SettleAsync();

        var log = store.Events(AF.Serial, fired.AddSeconds(-1), fired.AddSeconds(60));
        Assert.Single(log);
        Assert.Equal("hot", log[0].AlertId);
        Assert.Equal(fired.AddSeconds(30), log[0].AcknowledgedAt);
        Assert.Equal(61, log[0].Value);
        cts.Cancel();
        await consumer;
    });
}
