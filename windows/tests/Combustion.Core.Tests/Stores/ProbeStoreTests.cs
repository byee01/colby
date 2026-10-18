namespace Combustion.Core.Tests;

using F = StoreFixtures;

public class ProbeStoreTests
{
    private static ProbeStore MakeStore(TestClock clock) => new(clock);

    // Primary source order

    [Fact]
    public void PrimaryOrderDirectNodeAdvertisementNodeAdvertisement() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        var t = clock.Now();
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.NodeAdvertisement, t, via: "N1", hop: 1));
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, t));
        var snap = store.Snapshot(F.Serial)!;
        Assert.Equal(LinkKind.Advertisement, snap.Link.Primary?.Kind);
        store.Ingest(F.Observe(F.St(F.Status()), LinkKind.NodeConnection, t, via: "N2", hop: 3));
        store.Ingest(F.Observe(F.St(F.Status()), LinkKind.NodeConnection, t, via: "N1", hop: 2));
        snap = store.Snapshot(F.Serial)!;
        Assert.Equal(LinkKind.NodeConnection, snap.Link.Primary?.Kind);
        Assert.Equal("N1", snap.Link.Primary?.Via);
        store.Ingest(F.Observe(F.St(F.Status()), LinkKind.DirectConnection, t));
        snap = store.Snapshot(F.Serial)!;
        Assert.Equal(LinkKind.DirectConnection, snap.Link.Primary?.Kind);
        Assert.Equal([LinkKind.DirectConnection, LinkKind.NodeConnection, LinkKind.NodeConnection, LinkKind.Advertisement, LinkKind.NodeAdvertisement],
            snap.Link.Sources.Select(s => s.Kind));
        Assert.Equal("N1", snap.Link.Sources[1].Via);
        Assert.Equal("N2", snap.Link.Sources[2].Via);
        await Task.CompletedTask;
    });

    [Fact]
    public void SourceUpdatedInPlaceNotDuplicated()
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        for (var i = 0; i < 3; i++)
        {
            store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, clock.Now()));
        }
        Assert.Single(store.Snapshot(F.Serial)!.Link.Sources);
        store.Stop();
    }

    // Field merge

    [Fact]
    public void StatusOnlyFieldsSurviveAdvertisements() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        var pred = F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, 60, 900, 40);
        store.Ingest(F.Observe(F.St(F.Status(logMax: 7, prediction: pred)), LinkKind.DirectConnection, clock.Now()));
        await clock.AdvanceAsync(1);
        store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 33)), LinkKind.Advertisement, clock.Now()));
        var snap = store.Snapshot(F.Serial)!;
        Assert.Equal(pred, snap.Prediction);
        Assert.NotNull(snap.Alarms);
        Assert.Equal(new LogRange(0, 7), snap.Session?.LogRange);
        Assert.Equal(1u, snap.Session?.Info?.SessionId);
        Assert.Equal(33, snap.Virtual.Core);
        store.Stop();
    });

    [Fact]
    public void AdvertisementOnlyHasNoStatusFields()
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, clock.Now()));
        var snap = store.Snapshot(F.Serial)!;
        Assert.True(snap.Prediction is null && snap.Alarms is null && snap.FoodSafe is null && snap.Session is null);
        store.Stop();
    }

    [Fact]
    public void StatusFieldsFromFreshestConnection()
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        var old = F.Prediction(PredictionState.Warming, PredictionMode.TimeToRemoval, 60);
        var @new = F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, 65);
        var t = clock.Now();
        store.Ingest(F.Observe(F.St(F.Status(prediction: old)), LinkKind.DirectConnection, t));
        store.Ingest(F.Observe(F.St(F.Status(prediction: @new)), LinkKind.NodeConnection, t.AddSeconds(1), via: "N", hop: 1));
        Assert.Equal(@new, store.Snapshot(F.Serial)!.Prediction);
        // A late, older direct status does not override.
        store.Ingest(F.Observe(F.St(F.Status(prediction: old)), LinkKind.DirectConnection, t.AddSeconds(0.5)));
        Assert.Equal(@new, store.Snapshot(F.Serial)!.Prediction);
        store.Stop();
    }

    [Fact]
    public void TemperaturesFromFreshestOfAnyKind()
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        var t = clock.Now();
        store.Ingest(F.Observe(F.St(F.Status(core: 50)), LinkKind.DirectConnection, t));
        store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 51)), LinkKind.Advertisement, t.AddSeconds(0.1)));
        Assert.Equal(51, store.Snapshot(F.Serial)!.Virtual.Core);
        // Older node advertisement ignored.
        store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 10)), LinkKind.NodeAdvertisement, t.AddSeconds(-5), via: "N", hop: 1));
        var snap = store.Snapshot(F.Serial)!;
        Assert.Equal(51, snap.Virtual.Core);
        Assert.Equal(t.AddSeconds(0.1), snap.ReceivedAt);
        Assert.Equal(3, snap.Link.Sources.Count); // but the stale-timestamped observation still counts as a live path
        store.Stop();
    }

    [Fact]
    public void SnapshotBuiltFromStatusFields()
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        store.Ingest(F.Observe(F.St(F.Status(core: 60, surface: 70, ambient: 200, batteryLow: true)), LinkKind.DirectConnection, clock.Now()));
        var s = store.Snapshot(F.Serial)!;
        Assert.True(s.Serial == F.Serial && s.ProbeNumber == 1 && s.Color == ProbeColor.Yellow && s.Mode == ProbeMode.Normal);
        Assert.True(s.Temperatures.Count == 8 && s.Temperatures.All(v => v is not null));
        Assert.True(s.Virtual.Core == 60 && s.Virtual.Surface == 70 && s.Virtual.Ambient == 200);
        Assert.True(s.Virtual.CoreSensor == SensorIndex.T1 && s.Virtual.SurfaceSensor == SensorIndex.T4 && s.Virtual.AmbientSensor == SensorIndex.T5);
        Assert.True(s.BatteryLow && s.InstantRead is null);
        store.Stop();
    }

    // Source drop, offline

    [Fact]
    public void SourceDroppedAfterTenSeconds() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, clock.Now()));
        await clock.AdvanceAsync(9);
        Assert.Single(store.Snapshot(F.Serial)!.Link.Sources);
        await clock.AdvanceAsync(1);
        Assert.Empty(store.Snapshot(F.Serial)!.Link.Sources);
        store.Stop();
    });

    [Fact]
    public void RefreshedSourceSurvivesAndOnlyStaleOneDrops() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, clock.Now()));
        store.Ingest(F.Observe(F.St(F.Status()), LinkKind.DirectConnection, clock.Now()));
        await clock.AdvanceAsync(6);
        store.Ingest(F.Observe(F.St(F.Status()), LinkKind.DirectConnection, clock.Now()));
        await clock.AdvanceAsync(6); // t = 12: advertisement 12 s old, direct 6 s old
        var s = store.Snapshot(F.Serial)!;
        Assert.Equal([LinkKind.DirectConnection], s.Link.Sources.Select(x => x.Kind));
        Assert.Equal(LinkKind.DirectConnection, s.Link.Primary?.Kind);
        store.Stop();
    });

    [Fact]
    public void OfflineProbeIsKeptWithLastKnownData() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        var pred = F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, 60, 300);
        store.Ingest(F.Observe(F.St(F.Status(core: 44, prediction: pred)), LinkKind.DirectConnection, clock.Now()));
        await clock.AdvanceAsync(30);
        var latest = await store.Probes().FirstAsync(m => m.TryGetValue(F.Serial, out var p) && p.Link.Sources.Count == 0);
        var s = latest![F.Serial];
        Assert.True(s.IsOffline && s.Link.Primary is null);
        Assert.True(s.Virtual.Core == 44 && s.Prediction == pred);
        store.Stop();
    });

    [Fact]
    public void ProbeOnlineAgainAfterOffline() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, clock.Now()));
        await clock.AdvanceAsync(20);
        store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 30)), LinkKind.Advertisement, clock.Now()));
        var s = store.Snapshot(F.Serial)!;
        Assert.True(s.Link.Sources.Count == 1 && s.Virtual.Core == 30);
        store.Stop();
    });

    // Instant Read

    [Fact]
    public void InstantReadPath() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        async Task Feed(double v, ProbeMode mode = ProbeMode.InstantRead)
        {
            store.Ingest(F.Observe(F.Ad(F.Advertisement(mode: mode, t1: v)), LinkKind.Advertisement, clock.Now()));
            await clock.AdvanceAsync(TimeSpan.FromMilliseconds(83));
        }
        await Feed(20.0);
        var s = store.Snapshot(F.Serial)!;
        Assert.Equal(ProbeMode.InstantRead, s.Mode);
        Assert.Equal(20.0, s.Temperatures[0]);
        Assert.All(s.Temperatures.Skip(1), v => Assert.Null(v));
        Assert.Equal(20.0, s.InstantRead);
        Assert.Equal(20.0, s.Virtual.Core);
        Assert.True(s.Virtual.Surface is null && s.Virtual.Ambient is null);
        await Feed(20.3);
        Assert.Equal(20.0, store.Snapshot(F.Serial)!.InstantRead);
        await Feed(20.7);
        Assert.Equal(21.0, store.Snapshot(F.Serial)!.InstantRead);
        await Feed(25, ProbeMode.Normal);
        s = store.Snapshot(F.Serial)!;
        Assert.True(s.InstantRead is null && s.InstantReadFahrenheit is null);
        Assert.All(s.Temperatures, v => Assert.NotNull(v));
        await Feed(30.0);
        Assert.Equal(30.0, store.Snapshot(F.Serial)!.InstantRead);
        store.Stop();
    });

    [Fact]
    public void InstantReadFilterMatchesAndroidSdkBehaviour()
    {
        var f = new InstantReadFilter();
        f.AddReading(null);
        Assert.True(f.Celsius is null && f.Fahrenheit is null);
        f.AddReading(20.0);
        Assert.True(f.Celsius == 20.0 && f.Fahrenheit == 68.0);
        f.AddReading(20.2);
        Assert.True(f.Celsius == 20.0 && f.Fahrenheit == 68.0);
        f.AddReading(19.68);
        Assert.True(f.Celsius == 20.0 && f.Fahrenheit == 68.0);
        f.AddReading(20.5);
        Assert.True(f.Celsius == 20.0 && f.Fahrenheit == 69.0);
        f.AddReading(21.0);
        Assert.True(f.Celsius == 21.0 && f.Fahrenheit == 70.0);
        f.AddReading(null);
        Assert.Null(f.Celsius);
        f.AddReading(-0.5); // Kotlin roundToInt: halves toward +inf
        Assert.Equal(0.0, f.Celsius!.Value, 9);
    }

    // Status events

    [Fact]
    public void StatusEventsOnlyForAcceptedStatuses() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        using var log = store.StatusEvents().Collect();
        var t = clock.Now();
        store.Ingest(F.Observe(F.Ad(F.Advertisement()), LinkKind.Advertisement, t));
        store.Ingest(F.Observe(F.St(F.Status(logMax: 5)), LinkKind.DirectConnection, t.AddSeconds(1)));
        store.Ingest(F.Observe(F.St(F.Status(logMax: 4)), LinkKind.NodeConnection, t.AddSeconds(0.5), via: "N", hop: 1)); // older
        store.Ingest(F.Observe(F.St(F.Status(logMax: 6)), LinkKind.NodeConnection, t.AddSeconds(2), via: "N", hop: 1));
        await clock.SettleAsync();
        Assert.Equal([5u, 6u], log.Items.Select(e => e.Status.LogRange.Max));
        Assert.All(log.Items, e => Assert.Equal(F.Serial, e.Serial));
        Assert.Equal([t.AddSeconds(1), t.AddSeconds(2)], log.Items.Select(e => e.ReceivedAt));
        store.Stop();
    });

    // Streams and coalescing

    [Fact]
    public void FirstUpdateIsEmittedImmediately() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        using var log = store.Probes().Collect();
        await clock.SettleAsync();
        Assert.Empty(log.Last!); // replayed initial value
        store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 31)), LinkKind.Advertisement, clock.Now()));
        await clock.SettleAsync(); // no time advance
        Assert.Equal(31, log.Last![F.Serial].Virtual.Core);
        store.Stop();
    });

    [Fact]
    public void PerProbeStreamStartsNullThenFollowsAndReplaysLatest() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        using var log = store.Probe(F.Serial).Collect();
        await clock.SettleAsync();
        Assert.Single(log.Items);
        Assert.Null(log.Items[0]);
        store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 22)), LinkKind.Advertisement, clock.Now()));
        await clock.SettleAsync();
        Assert.Equal(22, log.Last!.Virtual.Core);
        // New subscriber gets the latest value first.
        var first = await store.Probe(F.Serial).FirstAsync(_ => true);
        Assert.Equal(22, first!.Virtual.Core);
        store.Stop();
    });

    [Fact]
    public void CoalescesToTenHertzAndDeliversLastValue() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        var emits = new List<(TimeSpan At, double? Core)>();
        using var cts = new CancellationTokenSource();
        var consumer = store.Probe(F.Serial).ForEachAsync(v =>
        {
            if (v is not null)
            {
                emits.Add((clock.Monotonic(), v.Virtual.Core));
            }
        }, cts.Token);
        await clock.SettleAsync();
        for (var i = 0; i < 50; i++)
        {
            store.Ingest(F.Observe(F.Ad(F.Advertisement(core: 20 + i)), LinkKind.Advertisement, clock.Now()));
            await clock.AdvanceAsync(TimeSpan.FromMilliseconds(83));
        }
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(100));
        cts.Cancel();
        await consumer;

        Assert.Equal(20, emits[0].Core);
        Assert.InRange(emits.Count, 30, 43); // 4.15 s at 10 Hz
        Assert.Equal(69, emits[^1].Core);
        // On one thread the spacing is exact: never closer than 100 ms.
        for (var i = 1; i < emits.Count; i++)
        {
            Assert.True(emits[i].At - emits[i - 1].At >= TimeSpan.FromMilliseconds(100), $"emit {i} at {emits[i].At}");
        }
        var cores = emits.Select(e => e.Core!.Value).ToList();
        Assert.Equal(cores.Order(), cores);
        store.Stop();
    });

    [Fact]
    public void MapStreamCoalescesAcrossProbes() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        using var log = store.Probes().Collect();
        await clock.SettleAsync();
        var serials = Enumerable.Range(1, 8).Select(i => new ProbeSerial((uint)i)).ToList();
        for (var round = 0; round < 5; round++)
        {
            foreach (var s in serials)
            {
                store.Ingest(F.Observe(F.Ad(F.Advertisement(serial: s, core: 20 + round)), LinkKind.Advertisement, clock.Now(), serial: s));
            }
            await clock.AdvanceAsync(TimeSpan.FromMilliseconds(10));
        }
        await clock.AdvanceAsync(TimeSpan.FromMilliseconds(100));
        Assert.True(log.Count <= 4, $"{log.Count} emits"); // initial {}, immediate first, one coalesced flush at 100 ms
        var final = log.Last!;
        Assert.Equal(8, final.Count);
        Assert.All(final.Values, p => Assert.Equal(24, p.Virtual.Core));
        store.Stop();
    });

    // Follow

    private sealed class MemoryFollowed : IFollowedProbePersistence
    {
        public HashSet<ProbeSerial> Saved { get; } = [];

        public Task<IReadOnlySet<ProbeSerial>> LoadFollowedAsync() => Task.FromResult<IReadOnlySet<ProbeSerial>>(new HashSet<ProbeSerial>(Saved));

        public Task SetFollowedAsync(ProbeSerial serial, bool followed)
        {
            if (followed)
            {
                Saved.Add(serial);
            }
            else
            {
                Saved.Remove(serial);
            }
            return Task.CompletedTask;
        }
    }

    [Fact]
    public void FollowUnfollowPublishesAndPersists() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var persistence = new MemoryFollowed();
        var store = new ProbeStore(clock, persistence);
        using var log = store.Followed().Collect();
        await store.StartAsync();
        await store.FollowAsync(F.Serial);
        await store.FollowAsync(new ProbeSerial(2));
        await store.UnfollowAsync(new ProbeSerial(2));
        await clock.SettleAsync();
        Assert.Equal(new ValueSet<ProbeSerial>([F.Serial]), log.Last);
        Assert.Equal([F.Serial], store.FollowedSerials());

        var reopened = new ProbeStore(clock, persistence);
        await reopened.StartAsync();
        Assert.Equal([F.Serial], reopened.FollowedSerials());
    });

    /// <summary>Swift <c>followUnfollowPublishesAndPersists</c>: the same flow against a real HistoryStore.</summary>
    [Fact]
    public void FollowUnfollowPersistsInHistoryStore() => Det.Run(async () =>
    {
        var clock = new TestClock();
        using var history = new HistoryStore(":memory:", clock);
        var store = new ProbeStore(clock, history);
        using var log = store.Followed().Collect();
        await store.StartAsync();
        await store.FollowAsync(F.Serial);
        await store.FollowAsync(new ProbeSerial(2));
        await store.UnfollowAsync(new ProbeSerial(2));
        await clock.SettleAsync();
        Assert.Equal(new ValueSet<ProbeSerial>([F.Serial]), log.Last);
        Assert.Equal([F.Serial], store.FollowedSerials());

        var reopened = new ProbeStore(clock, history);
        await reopened.StartAsync();
        Assert.Equal([F.Serial], reopened.FollowedSerials());
    });

    [Fact]
    public void FollowWithoutPersistenceWorks() => Det.Run(async () =>
    {
        var store = MakeStore(new TestClock());
        await store.FollowAsync(F.Serial);
        Assert.Equal([F.Serial], store.FollowedSerials());
        await store.UnfollowAsync(F.Serial);
        Assert.Empty(store.FollowedSerials());
    });

    [Fact]
    public void EightProbesAtOnce()
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        for (var i = 1; i <= 8; i++)
        {
            var s = new ProbeSerial((uint)i);
            store.Ingest(F.Observe(F.St(F.Status(core: i * 10)), LinkKind.DirectConnection, clock.Now(), serial: s));
        }
        var all = store.Snapshots();
        Assert.Equal(8, all.Count);
        Assert.Equal(30, all[new ProbeSerial(3)].Virtual.Core);
        store.Stop();
    }

    // Nodes

    [Fact]
    public void NodeSightingsAndSnapshotsMergeAndExpire() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var store = MakeStore(clock);
        store.Ingest(new NodeSighting("D1", NodeProductType.Display, "p1", -50, clock.Now()));
        Assert.Equal(LinkKind.NodeAdvertisement, store.NodeSnapshots()["D1"].Link.Kind);
        var connected = new NodeSnapshot("D1", NodeProductType.Display, F.Source(LinkKind.DirectConnection, at: clock.Now()), IsConnected: true,
            Firmware: new DeviceInfo("1.2.3"));
        store.Ingest(connected);
        store.Ingest(connected with { Firmware = null });
        Assert.Equal("1.2.3", store.NodeSnapshots()["D1"].Firmware?.Firmware); // firmware not yet read keeps the known one
        store.Ingest(new NodeSighting("D1", NodeProductType.Display, "p1", -40, clock.Now()));
        Assert.True(store.NodeSnapshots()["D1"].IsConnected); // connected node ignores sightings
        store.Ingest(new NodeSighting("B2", NodeProductType.Booster, "p2", -70, clock.Now()));
        await clock.AdvanceAsync(10);
        Assert.Equal(["D1"], store.NodeSnapshots().Keys);
        store.Stop();
    });
}
