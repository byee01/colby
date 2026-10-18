namespace Combustion.Core.Tests;

/// <summary>The widget snapshot (docs/02 §18): content, order and write throttling.</summary>
public class LiveSnapshotWriterTests
{
    private sealed class CollectingWriter : ILiveSnapshotWriting
    {
        private readonly List<byte[]> _stored = [];

        public IReadOnlyList<byte[]> Writes => _stored;

        public Task WriteAsync(byte[] data)
        {
            _stored.Add(data);
            return Task.CompletedTask;
        }
    }

    private sealed class Rig
    {
        public TestClock Clock { get; } = new();
        public CollectingWriter Out { get; } = new();
        public LiveSnapshotWriter Writer { get; }

        public Rig()
        {
            Writer = new LiveSnapshotWriter(Clock, Out);
        }

        public Task SnapAsync(double? core, ProbeSerial? serial = null, int number = 1, bool offline = false, PredictionStatus? prediction = null)
        {
            var s = AF.Snapshot(Clock.Now(), serial, core: core, offline: offline, prediction: prediction) with { ProbeNumber = number };
            return Writer.IngestAsync(new Dictionary<ProbeSerial, ProbeSnapshot> { [s.Serial] = s });
        }
    }

    private static LiveSnapshot Decode(byte[] data) => LiveSnapshot.Decode(data);

    [Fact]
    public void WritesOnlyFollowedProbesWithTheFieldsAWidgetShows() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.Writer.SetFollowedAsync(AlertRig.Set(AF.Serial));
        await rig.Writer.SetNameAsync("Brisket", AF.Serial);
        await rig.SnapAsync(50, AF.Other, number: 2);
        await rig.SnapAsync(74, prediction: AF.Prediction(PredictionState.Predicting));
        var readyAt = rig.Clock.Now().AddSeconds(222);
        var view = AF.View(seconds: 222) with { ReadyAt = readyAt };
        await rig.Writer.IngestAsync(view);

        Assert.NotEmpty(rig.Out.Writes);
        var last = Decode(rig.Out.Writes[^1]);
        Assert.Single(last.Probes); // probe 2 is not followed
        var p = last.Probes[0];
        Assert.Equal(AF.Serial.Hex, p.Serial);
        Assert.Equal("Brisket", p.Name);
        Assert.Equal(74, p.Core);
        Assert.Equal(60, p.Target);
        Assert.Equal("predicting", p.State);
        Assert.Equal(222u, p.SecondsRemaining);
        Assert.Equal(readyAt, p.ReadyAt);
        Assert.False(p.IsOffline);
        Assert.Equal([74.0], p.Trend);
    });

    /// <summary>The file has the Swift shape (sorted keys, nulls omitted, whole-second ISO 8601 dates), so a widget
    /// reads the same JSON on both platforms.</summary>
    [Fact]
    public void JsonHasTheSwiftShape()
    {
        var t = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
        var snapshot = new LiveSnapshot(t, [new LiveSnapshot.Probe("10005A3F", 1, null, 74, null, "predicting", 222, t.AddSeconds(222), null, false, false, [74, 75.5])]);
        var json = System.Text.Encoding.UTF8.GetString(snapshot.Encode());
        Assert.Equal(
            """{"probes":[{"core":74,"isOffline":false,"isStale":false,"number":1,"readyAt":"2023-11-14T22:17:02Z","secondsRemaining":222,"serial":"10005A3F","state":"predicting","trend":[74,75.5]}],"writtenAt":"2023-11-14T22:13:20Z"}""",
            json);
        Assert.Equal(snapshot, LiveSnapshot.Decode(snapshot.Encode()));
    }

    [Fact]
    public void FileWriterReplacesTheFileAtomically() => Det.Run(async () =>
    {
        var dir = Path.Combine(Path.GetTempPath(), $"colby-{Guid.NewGuid()}");
        Directory.CreateDirectory(dir);
        try
        {
            var path = Path.Combine(dir, "live.json");
            var writer = new FileLiveSnapshotWriter(path);
            await writer.WriteAsync([1, 2, 3]);
            await writer.WriteAsync([4, 5]);
            Assert.Equal([4, 5], await File.ReadAllBytesAsync(path));
            Assert.Equal([path], Directory.GetFiles(dir)); // no temp file left behind
        }
        finally
        {
            Directory.Delete(dir, recursive: true);
        }
    });

    [Fact]
    public void NoTargetWhenNoPredictionModeIsSet() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.Writer.SetFollowedAsync(AlertRig.Set(AF.Serial));
        var status = AF.Prediction(PredictionState.Inserted) with { Mode = PredictionMode.None };
        await rig.SnapAsync(30, prediction: status);
        Assert.Null(rig.Writer.Current().Probes.FirstOrDefault()?.Target);
    });

    [Fact]
    public void SoonestFinishFirstThenReadyThenTheRestByProbeNumber() => Det.Run(async () =>
    {
        var rig = new Rig();
        ProbeSerial a = new(1), b = new(2), c = new(3), d = new(4);
        await rig.Writer.SetFollowedAsync(AlertRig.Set(a, b, c, d));
        foreach (var (s, n) in new[] { (a, 1), (b, 2), (c, 3), (d, 4) })
        {
            await rig.SnapAsync(50, s, number: n);
        }
        PredictionView View(ProbeSerial s, PredictionState state, double? readyIn = null) =>
            AF.View(s, state, seconds: readyIn is { } r ? (uint)r : null) with
            {
                ReadyAt = readyIn is { } r2 ? rig.Clock.Now().AddSeconds(r2) : null,
            };
        await rig.Writer.IngestAsync(View(a, PredictionState.Predicting, readyIn: 3600));
        await rig.Writer.IngestAsync(View(b, PredictionState.RemovalPredictionDone));
        await rig.Writer.IngestAsync(View(c, PredictionState.Predicting, readyIn: 600));
        await rig.Writer.IngestAsync(View(d, PredictionState.Warming));
        Assert.Equal([3, 1, 2, 4], rig.Writer.Current().Probes.Select(p => p.Number));
    });

    [Fact]
    public void TemperatureChangesAreThrottledToOneWriteEveryFiveSecondsButStateChangesWriteAtOnce() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.Writer.SetFollowedAsync(AlertRig.Set(AF.Serial));
        await rig.SnapAsync(70);
        var afterFirst = rig.Out.Writes.Count;
        foreach (var core in new[] { 70.5, 71.0, 71.5 })
        {
            await rig.Clock.AdvanceAsync(1);
            await rig.SnapAsync(core);
        }
        Assert.Equal(afterFirst, rig.Out.Writes.Count); // within 5 s: no write yet

        await rig.Writer.IngestAsync(AF.View(state: PredictionState.RemovalPredictionDone));
        Assert.Equal(afterFirst + 1, rig.Out.Writes.Count); // Ready is written immediately

        await rig.SnapAsync(72);
        await rig.Clock.AdvanceAsync(6);
        Assert.Equal(afterFirst + 2, rig.Out.Writes.Count); // one trailing write when the interval is up
        Assert.Equal(72, Decode(rig.Out.Writes[^1]).Probes.FirstOrDefault()?.Core);
    });

    [Fact]
    public void TrendKeepsOnePointPerFiveSecondsAndTheLastThirty() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.Writer.SetFollowedAsync(AlertRig.Set(AF.Serial));
        for (var i = 0; i < 80; i++)
        {
            await rig.SnapAsync(i);
            await rig.Clock.AdvanceAsync(TimeSpan.FromMilliseconds(2500));
        }
        var trend = rig.Writer.Current().Probes.FirstOrDefault()?.Trend;
        Assert.NotNull(trend);
        Assert.Equal(LiveSnapshotWriter.TrendLength, trend.Count);
        Assert.Equal(78, trend[^1]);
        Assert.True(trend.Zip(trend.Skip(1)).All(p => p.Second - p.First == 2), "every second reading, 5 s apart");
    });

    [Fact]
    public void AnOfflineProbeIsFlaggedAndAddsNoTrendPoint() => Det.Run(async () =>
    {
        var rig = new Rig();
        await rig.Writer.SetFollowedAsync(AlertRig.Set(AF.Serial));
        await rig.SnapAsync(70);
        await rig.Clock.AdvanceAsync(10);
        await rig.SnapAsync(70, offline: true);
        var p = rig.Writer.Current().Probes.FirstOrDefault();
        Assert.NotNull(p);
        Assert.True(p.IsOffline);
        Assert.Equal([70.0], p.Trend);
    });
}
