namespace Combustion.Core.Tests;

using F = StoreFixtures;
using Req = StoreFakeFetcher.Request;

public class HistoryStoreTests
{
    private static readonly DateTimeOffset T0 = StoreFixtures.T0;

    private static ProbeStatusEvent Ev(ProbeStatusPayload s, DateTimeOffset at, ProbeSerial? serial = null) =>
        new(serial ?? F.Serial, s, at);

    private static HistoryStore MakeStore(ILogFetcher? fetcher = null) => new(":memory:", new TestClock(), fetcher);

    private static List<uint> Range(uint first, uint last) => new SeqRange(first, last).Seqs().ToList();

    /// <summary>Serves every requested seq twice.</summary>
    private sealed class Dup : ILogFetcher
    {
        public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end)
        {
            var s = new AsyncStream<LogRecord>();
            for (var q = (long)start; q <= end; q++)
            {
                s.Yield(F.Record((uint)q));
                s.Yield(F.Record((uint)q));
            }
            s.Finish();
            return s;
        }
    }

    /// <summary>Serves 0...end+5 whatever was asked.</summary>
    private sealed class Wild : ILogFetcher
    {
        public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end)
        {
            var s = new AsyncStream<LogRecord>();
            for (var q = 0u; q <= end + 5; q++)
            {
                s.Yield(F.Record(q));
            }
            s.Finish();
            return s;
        }
    }

    /// <summary>One shared fetcher that routes by probe.</summary>
    private sealed class Router(Dictionary<ProbeSerial, StoreFakeFetcher> by) : ILogFetcher
    {
        public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end) => by[probe].ReadLogs(probe, start, end);
    }

    // Time derivation

    [Fact]
    public void TimeDerivationFormula()
    {
        var t = TimeDerivation.TimeOf(7, 10, T0, 5);
        Assert.Equal(T0.AddSeconds(-15), t);
        Assert.Equal(T0.AddSeconds(10), TimeDerivation.TimeOf(12, 10, T0, 5));
        Assert.Equal(7, TimeDerivation.SeqAt(T0.AddSeconds(-15), 10, T0, 5));
    }

    [Fact]
    public void TimesAreDerivedFromLatestAnchorOnRead() => Det.Run(async () =>
    {
        var fetcher = new StoreFakeFetcher(0, 40);
        using var store = MakeStore(fetcher);
        var key = await store.IngestAsync(Ev(F.Status(logMax: 10), T0));
        var series = store.CurrentSeries(key);
        Assert.NotNull(series);
        Assert.Equal(Range(0, 10), series.Samples.Select(s => s.Seq));
        Assert.Equal(T0, series.Samples[^1].Time);
        Assert.Equal(T0.AddSeconds(-50), series.Samples[0].Time);

        // Re-anchor 100 s later: the same seqs move with the anchor; nothing was rewritten.
        await store.IngestAsync(Ev(F.Status(logMax: 30), T0.AddSeconds(100)));
        series = store.CurrentSeries(key);
        Assert.NotNull(series);
        Assert.True(series.AnchorSeq == 30 && series.AnchorTime == T0.AddSeconds(100));
        Assert.Equal(T0, series.Samples.First(s => s.Seq == 10).Time); // 100 - 20 * 5
        Assert.Equal(T0.AddSeconds(100), series.Samples.First(s => s.Seq == 30).Time);

        // A new sample period re-times everything on the next read.
        await store.IngestAsync(Ev(F.Status(logMax: 30, periodMs: 6000), T0.AddSeconds(100)));
        series = store.CurrentSeries(key);
        Assert.NotNull(series);
        Assert.Equal(6, series.SamplePeriod);
        Assert.Equal(T0.AddSeconds(-20), series.Samples.First(s => s.Seq == 10).Time); // 100 - 20 * 6
    });

    [Fact]
    public void AnchorNeverMovesBackwardsInTime() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 30), T0.AddSeconds(100)));
        await store.IngestAsync(Ev(F.Status(logMax: 25), T0.AddSeconds(50)));
        var s = store.CurrentSeries(key);
        Assert.NotNull(s);
        Assert.True(s.AnchorSeq == 30 && s.AnchorTime == T0.AddSeconds(100));
    });

    [Fact]
    public void LegacyStatusWithoutSessionInfoUsesDefaultPeriod() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 4, sessionId: null), T0));
        Assert.Equal(0u, key.SessionId);
        Assert.Equal(5, store.CurrentSeries(key)?.SamplePeriod);
    });

    // Insert idempotence

    [Fact]
    public void InsertsAreIdempotent() => Det.Run(async () =>
    {
        var fetcher = new StoreFakeFetcher(0, 20);
        fetcher.Add(F.Record(5, core: 99)); // same seq, different data: first write wins
        using var store = MakeStore(fetcher);
        var key = await store.IngestAsync(Ev(F.Status(logMax: 20), T0));
        Assert.Equal(21, store.SampleCount(key));
        var first = store.CurrentSeries(key);
        // Everything again: same status, backfill over the full range, backfill with explicit range.
        await store.IngestAsync(Ev(F.Status(logMax: 20), T0));
        var r = await store.BackfillAsync(key, fetcher, new LogRange(0, 20));
        Assert.True(r.Requested == 0 && r.Received == 0); // nothing missing, nothing requested
        Assert.Equal(21, store.SampleCount(key));
        Assert.Equal(first?.Samples, store.CurrentSeries(key)?.Samples);
    });

    [Fact]
    public void DuplicateRecordsInOneStreamAreStoredOnce() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 9), T0));
        var r = await store.BackfillAsync(key, new Dup());
        Assert.Equal(10, store.SampleCount(key));
        Assert.True(r.Received == 9 && r.Remaining == 0); // seq 9 came from the status itself
    });

    // Sessions

    [Fact]
    public void NewSessionIdSplitsCooksAndClosesTheOldOne() => Det.Run(async () =>
    {
        var fetcher = new StoreFakeFetcher(0, 50);
        using var store = MakeStore(fetcher);
        var k1 = await store.IngestAsync(Ev(F.Status(logMax: 20, sessionId: 1), T0));
        await store.IngestAsync(Ev(F.Status(logMax: 30, sessionId: 1), T0.AddSeconds(50)));
        var k2 = await store.IngestAsync(Ev(F.Status(logMax: 3, sessionId: 2), T0.AddSeconds(4000)));
        Assert.True(k1 != k2 && k1.SessionId == 1 && k2.SessionId == 2);

        var list = store.Sessions(F.Serial);
        Assert.Equal([k2, k1], list.Select(s => s.Key)); // newest first
        SessionSummary old = list[1], @new = list[0];
        Assert.Equal(T0.AddSeconds(50), old.End); // last status of the old cook
        Assert.Null(@new.End);
        Assert.Equal(60, old.Thumbnail.Count);
        Assert.Equal(31, old.SampleCount);
        Assert.Equal(4, @new.SampleCount); // 0...3 from the fetcher (live fetch for the new session)
        Assert.Equal(k2, store.CurrentSession(F.Serial));
    });

    [Fact]
    public void ZeroIdCooksStayDistinctByStartTime() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var a = await store.IngestAsync(Ev(F.Status(logMax: 100, sessionId: null), T0));
        var b = await store.IngestAsync(Ev(F.Status(logMax: 5, sessionId: null), T0.AddSeconds(600))); // max decreased
        Assert.True(a.SessionId == 0 && b.SessionId == 0 && a != b);
        Assert.Equal(2, store.Sessions().Count);
    });

    [Fact]
    public void UnknownIdLaterKnownRewritesSessionId() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var a = await store.IngestAsync(Ev(F.Status(logMax: 10, sessionId: null), T0));
        var b = await store.IngestAsync(Ev(F.Status(logMax: 11, sessionId: 77), T0.AddSeconds(5)));
        Assert.True(a.SessionId == 0 && b.SessionId == 77 && a.StartedAtMs == b.StartedAtMs);
        Assert.Single(store.Sessions());
    });

    [Fact]
    public void KindBecomesPredictiveWhenSetpointEverSet() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 1), T0));
        Assert.Equal(SessionKind.Manual, store.Sessions()[0].Kind);
        var pred = F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, 63, 600);
        await store.IngestAsync(Ev(F.Status(logMax: 2, prediction: pred), T0.AddSeconds(5)));
        await store.IngestAsync(Ev(F.Status(logMax: 3), T0.AddSeconds(10))); // prediction cancelled again
        Assert.Equal(SessionKind.Predictive, store.Sessions()[0].Kind);
        Assert.Equal(key, store.Sessions()[0].Key);
    });

    [Fact]
    public void KindFromBackfilledRecords() => Det.Run(async () =>
    {
        var fetcher = new StoreFakeFetcher();
        for (var s = 0u; s <= 5; s++)
        {
            fetcher.Add(F.Record(s, mode: s >= 3 ? PredictionMode.TimeToRemoval : PredictionMode.None, setpoint: s >= 3 ? 70 : 0));
        }
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 5), T0));
        await store.BackfillAsync(key, fetcher);
        var sum = store.Sessions()[0];
        Assert.True(sum.Kind == SessionKind.Predictive && sum.Setpoint == 70);
    });

    [Fact]
    public void ReadySinceSetOnceWhenPredictionDone() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var predicting = F.Prediction(PredictionState.Predicting, PredictionMode.TimeToRemoval, 60, 30);
        var done = F.Prediction(PredictionState.RemovalPredictionDone, PredictionMode.TimeToRemoval, 60);
        await store.IngestAsync(Ev(F.Status(logMax: 1, prediction: predicting), T0));
        Assert.Null(store.Sessions()[0].ReadySince);
        await store.IngestAsync(Ev(F.Status(logMax: 2, prediction: done), T0.AddSeconds(5)));
        await store.IngestAsync(Ev(F.Status(logMax: 3, prediction: done), T0.AddSeconds(10)));
        Assert.Equal(T0.AddSeconds(5), store.Sessions()[0].ReadySince);
        await store.IngestAsync(Ev(F.Status(logMax: 4, prediction: predicting), T0.AddSeconds(15))); // new prediction
        Assert.Null(store.Sessions()[0].ReadySince);
    });

    [Fact]
    public void SummaryHasPeakCoreSetpointCountAndLiveThumbnail() => Det.Run(async () =>
    {
        var fetcher = new StoreFakeFetcher();
        double[] cores = [20, 25, 30, 41, 37, 33, 35, 36, 38, 39];
        for (var s = 0u; s <= 9; s++)
        {
            fetcher.Add(F.Record(s, core: cores[s], mode: PredictionMode.TimeToRemoval, setpoint: 60));
        }
        using var store = MakeStore(fetcher);
        await store.IngestAsync(Ev(F.Status(logMax: 9), T0));
        var s0 = store.Sessions()[0];
        Assert.True(s0.PeakCore == 41 && s0.SampleCount == 10 && s0.Setpoint == 60);
        Assert.True(s0.End is null && s0.Thumbnail.Count == 60); // computed on the fly for the open session
        Assert.True(s0.SamplePeriod == 5 && s0.Nickname is null);
    });

    [Fact]
    public void PeakCoreFollowsEachSamplesCoreSensor() => Det.Run(async () =>
    {
        // Core sensor is T3 for this record: peak must read T3, not T1.
        var vs = new VirtualSensors(SensorIndex.T3, SensorIndex.T4, SensorIndex.T5);
        var temps = ProbeTemperatures.FromCelsius([99, 0, 55, 10, 10, 0, 0, 0]);
        var rec = new LogRecord(0, temps, new PredictionLog(vs, PredictionState.NotInserted, PredictionMode.None, PredictionType.None, 0, 0, 0));
        var f = new StoreFakeFetcher();
        f.Add(rec);
        using var store = MakeStore(f);
        var key = await store.IngestAsync(Ev(F.Status(logMax: 1), T0)); // the status is seq 1 (core 25)
        Assert.Equal(55, store.Sessions()[0].PeakCore);
        var sample = store.CurrentSeries(key)?.Samples.FirstOrDefault();
        Assert.NotNull(sample);
        Assert.True(sample.Core == 55 && sample.Surface == 10 && sample.VirtualSensors == vs);
    });

    [Fact]
    public void RenameAndDelete() => Det.Run(async () =>
    {
        using var store = MakeStore(new StoreFakeFetcher(0, 5));
        var key = await store.IngestAsync(Ev(F.Status(logMax: 5), T0));
        store.Rename(key, "Brisket");
        Assert.Equal("Brisket", store.Sessions()[0].Nickname);
        store.Rename(key, null);
        Assert.Null(store.Sessions()[0].Nickname);
        store.Delete(key);
        Assert.Empty(store.Sessions());
        Assert.Equal(0, store.SampleCount(key));
        Assert.Null(store.CurrentSeries(key));
        Assert.Null(store.CurrentSession(F.Serial));
        // The probe is still being heard: the next status starts a fresh row.
        var again = await store.IngestAsync(Ev(F.Status(logMax: 6), T0.AddSeconds(5)));
        Assert.Equal([again], store.Sessions().Select(s => s.Key));
    });

    [Fact]
    public void EndCurrentSessionClosesAndComputesThumbnail() => Det.Run(async () =>
    {
        using var store = MakeStore(new StoreFakeFetcher(0, 9));
        var key = await store.IngestAsync(Ev(F.Status(logMax: 9), T0));
        store.EndCurrentSession(F.Serial);
        var s = store.Sessions()[0];
        Assert.True(s.End == T0 && s.Thumbnail.Count == 60 && s.Key == key);
        Assert.Null(store.CurrentSession(F.Serial));
        var next = await store.IngestAsync(Ev(F.Status(logMax: 10), T0.AddSeconds(5)));
        Assert.NotEqual(key, next);
    });

    [Fact]
    public void SessionsFilterBySerial() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var other = new ProbeSerial(2);
        await store.IngestAsync(Ev(F.Status(logMax: 1), T0));
        await store.IngestAsync(Ev(F.Status(logMax: 1), T0, other));
        Assert.Equal(2, store.Sessions().Count);
        Assert.Equal([other], store.Sessions(other).Select(s => s.Key.Serial));
    });

    [Fact]
    public void OpenSessionResumesAfterRestartAndSplitsOnNewId() => Det.Run(async () =>
    {
        var path = Path.Combine(Path.GetTempPath(), $"colby-{Guid.NewGuid()}.sqlite");
        try
        {
            SessionKey k1;
            using (var store = new HistoryStore(path, new TestClock()))
            {
                k1 = await store.IngestAsync(Ev(F.Status(logMax: 10, sessionId: 4), T0));
            }
            using (var store = new HistoryStore(path, new TestClock()))
            {
                var k = await store.IngestAsync(Ev(F.Status(logMax: 12, sessionId: 4), T0.AddSeconds(3600)));
                Assert.Equal(k1, k); // same cook continues
                var k2 = await store.IngestAsync(Ev(F.Status(logMax: 1, sessionId: 5), T0.AddSeconds(7200)));
                Assert.NotEqual(k1, k2);
                var list = store.Sessions();
                Assert.True(list.Count == 2 && list[1].End == T0.AddSeconds(3600));
            }
        }
        finally
        {
            foreach (var ext in new[] { "", "-wal", "-shm" })
            {
                File.Delete(path + ext);
            }
        }
    });

    // Series stream

    [Fact]
    public void SeriesStreamReplaysThenUpdatesAndFinishesOnDelete() => Det.Run(async () =>
    {
        var fetcher = new StoreFakeFetcher(0, 40);
        using var store = MakeStore(fetcher);
        var clock = new TestClock();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 4), T0));
        using var log = store.Series(key).Collect();
        await clock.SettleAsync();
        Assert.Single(log.Items);
        Assert.Equal(5, log.Items[0].Samples.Count);
        await store.IngestAsync(Ev(F.Status(logMax: 9), T0.AddSeconds(25)));
        await clock.SettleAsync();
        Assert.Equal(10, log.Last?.Samples.Count);
        // Anchor-only change (no new records) re-publishes with moved times.
        await store.IngestAsync(Ev(F.Status(logMax: 9), T0.AddSeconds(30)));
        await clock.SettleAsync();
        Assert.Equal(T0.AddSeconds(30), log.Last?.AnchorTime);
        store.Delete(key);
        await clock.SettleAsync();
        Assert.True(log.Done.IsCompleted);
        // Unknown session: empty, finished.
        var n = 0;
        await foreach (var _ in store.Series(key))
        {
            n++;
        }
        Assert.Equal(0, n);
    });

    // Downsampling

    private static TemperatureSeries MakeSeries(int count, int? spikeAt = null, uint seqStep = 1)
    {
        var key = new SessionKey(F.Serial, 1, T0);
        var samples = Enumerable.Range(0, count).Select(i =>
        {
            var seq = (uint)i * seqStep;
            var c = i == spikeAt ? 250.0 : 50 + i % 7;
            var t = ProbeTemperatures.FromCelsius([c, 0, 0, c - 10, c - 20, 0, 0, 0]);
            return new TemperatureSample(seq, T0.AddSeconds(seq * 5.0), t.Celsius.ToArray(), F.Virtual(), F.Record(seq).Prediction);
        }).ToList();
        return new TemperatureSeries(key, 5, samples.Count > 0 ? samples[^1].Seq : 0, T0, samples);
    }

    [Fact]
    public void DownsamplingKeepsSpikesAndRespectsMax()
    {
        var s = MakeSeries(10_000, spikeAt: 5123);
        var d = s.Downsampled(200);
        Assert.True(d.Count <= 200 && d.Count >= 190);
        Assert.Equal(250, d.Max(b => b.Core.Max)); // spike survives
        Assert.True((d.FirstOrDefault(b => b.Core.Max == 250)?.Core.Min ?? 0) < 250); // min/max band, not a point
        Assert.Equal(10_000, d.Sum(b => b.SampleCount));
        Assert.True(d[0].FirstSeq == 0 && d[^1].LastSeq == 9_999);
        Assert.All(d.Zip(d.Skip(1)), p => Assert.True(p.First.LastSeq < p.Second.FirstSeq && p.First.EndTime <= p.Second.StartTime));
        Assert.All(d, b => Assert.True(b.Surface.Max == b.Core.Max - 10 || b.Surface.Max < b.Core.Max));
    }

    [Fact]
    public void DownsamplingBelowMaxIsOneBucketPerSample()
    {
        var s = MakeSeries(30);
        var d = s.Downsampled(100);
        Assert.True(d.Count == 30 && d.All(b => b.SampleCount == 1 && b.Core.Min == b.Core.Max));
        Assert.Empty(s.Downsampled(0));
        Assert.Empty(new TemperatureSeries(s.Key, 5, 0, T0, ValueList<TemperatureSample>.Empty).Downsampled(10));
    }

    [Fact]
    public void DownsamplingWithHolesSkipsEmptyBuckets()
    {
        var s = MakeSeries(50, seqStep: 100); // seqs 0,100,...,4900; 100-wide holes
        Assert.Equal(50, s.Downsampled(1000).Count);
        var d2 = s.Downsampled(10);
        Assert.True(d2.Count == 10 && d2.Sum(b => b.SampleCount) == 50);
    }

    [Fact]
    public void DownsamplingMaxPointsOneCoversEverything()
    {
        var s = MakeSeries(100, spikeAt: 40);
        var d = s.Downsampled(1);
        Assert.True(d.Count == 1 && d[0].Core.Max == 250 && d[0].SampleCount == 100);
    }

    // ValueAt

    private static async Task<(HistoryStore Store, SessionKey Key)> ValueStore()
    {
        var f = new StoreFakeFetcher();
        for (var s = 0u; s <= 10; s++)
        {
            f.Add(F.Record(s, core: 20 + s, surface: 100 + s, ambient: 200,
                mode: s >= 8 ? PredictionMode.TimeToRemoval : PredictionMode.None, setpoint: s >= 8 ? 60 : 0,
                state: s >= 8 ? PredictionState.Predicting : PredictionState.NotInserted));
        }
        var store = MakeStore(f);
        // seq 10 at t0, 5 s apart. The status is stored as seq 10, so it carries record 10's values.
        var key = await store.IngestAsync(Ev(F.Status(core: 30, surface: 110, ambient: 200, logMax: 10), T0));
        return (store, key);
    }

    [Fact]
    public void ValueAtExactAndInterpolated() => Det.Run(async () =>
    {
        var (store, key) = await ValueStore();
        using var _ = store;
        var exact = store.ValueAt(key, T0.AddSeconds(-25)); // seq 5
        Assert.NotNull(exact);
        Assert.True(exact.Seq == 5 && exact.Core == 25 && exact.Surface == 105 && exact.Ambient == 200);
        Assert.Equal(PredictionState.NotInserted, exact.PredictionState);
        var mid = store.ValueAt(key, T0.AddSeconds(-22.5)); // seq 5.5
        Assert.NotNull(mid);
        Assert.True(Math.Abs(mid.Core - 25.5) < 1e-9 && Math.Abs(mid.Surface - 105.5) < 1e-9);
        var quarter = store.ValueAt(key, T0.AddSeconds(-28.75)); // seq 4.25
        Assert.NotNull(quarter);
        Assert.True(Math.Abs(quarter.Core - 24.25) < 1e-9 && quarter.Seq == 4);
    });

    [Fact]
    public void ValueAtCarriesPredictionStateAndEdges() => Det.Run(async () =>
    {
        var (store, key) = await ValueStore();
        using var _ = store;
        var late = store.ValueAt(key, T0.AddSeconds(-5)); // seq 9
        Assert.NotNull(late);
        Assert.True(late.PredictionState == PredictionState.Predicting && late.Prediction.Setpoint == 60);
        Assert.Equal(30, store.ValueAt(key, T0)?.Core);
        Assert.Equal(20, store.ValueAt(key, T0.AddSeconds(-50))?.Core); // first sample
        Assert.Equal(10u, store.ValueAt(key, T0.AddSeconds(1))?.Seq); // within half a period past the end
        Assert.Null(store.ValueAt(key, T0.AddSeconds(10)));
        Assert.Null(store.ValueAt(key, T0.AddSeconds(-60)));
    });

    [Fact]
    public void ValueAtAcrossAHoleUsesNearest() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher();
        f.Add(F.Record(0, core: 20));
        f.Add(F.Record(100, core: 120));
        using var store = MakeStore(f);
        var key = await store.IngestAsync(Ev(F.Status(logMax: 100), T0));
        // 70 s in: seq 14 of a 100-seq hole; no interpolation across it, nearest is seq 0.
        var v = store.ValueAt(key, T0.AddSeconds(-430));
        Assert.NotNull(v);
        Assert.True(v.Seq == 0 && v.Core == 20);
        Assert.Equal(100u, store.ValueAt(key, T0.AddSeconds(-20))?.Seq);
    });

    [Fact]
    public void ValueAtUsesLatestAnchor() => Det.Run(async () =>
    {
        var (store, key) = await ValueStore();
        using var _ = store;
        await store.IngestAsync(Ev(F.Status(logMax: 10), T0.AddSeconds(100))); // anchor moved: seq 10 now at t0+100
        Assert.Equal(10u, store.ValueAt(key, T0.AddSeconds(100))?.Seq);
        Assert.Null(store.ValueAt(key, T0));
    });

    // Thumbnail

    [Fact]
    public void ThumbnailHasSixtyPointsAndEndpoints()
    {
        var s = MakeSeries(500);
        var th = Thumbnail.Make(s.Samples);
        Assert.Equal(60, th.Count);
        Assert.True(th[0].Core == s.Samples[0].Core && th[^1].Core == s.Samples[^1].Core);
        Assert.True(th[0].Surface == s.Samples[0].Surface && th[0].Ambient == s.Samples[0].Ambient);
    }

    [Fact]
    public void ThumbnailInterpolatesShortAndSingleSeries()
    {
        var two = MakeSeries(2).Samples.ToList();
        var th = Thumbnail.Make(two);
        Assert.Equal(60, th.Count);
        Assert.True(th.Min(p => p.Core) == Math.Min(two[0].Core, two[1].Core) && th.Max(p => p.Core) == Math.Max(two[0].Core, two[1].Core));
        var one = Thumbnail.Make([two[0]]);
        Assert.True(one.Count == 60 && one.All(p => p.Core == two[0].Core));
        Assert.Empty(Thumbnail.Make([]));
    }

    [Fact]
    public void ThumbnailBlobRoundTrips()
    {
        var th = Thumbnail.Make(MakeSeries(100).Samples);
        var back = Thumbnail.Decode(Thumbnail.Encode(th));
        Assert.Equal(60, back.Count);
        Assert.All(th.Zip(back), p => Assert.True(Math.Abs(p.First.Core - p.Second.Core) < 1e-4));
        Assert.Empty(Thumbnail.Decode([1, 2, 3]));
    }

    [Fact]
    public void ThumbnailStoredOnSessionEndMatchesComputed() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 99);
        using var store = MakeStore(f);
        var k = await store.IngestAsync(Ev(F.Status(logMax: 99, sessionId: 1), T0));
        var series = store.CurrentSeries(k);
        Assert.NotNull(series);
        var expected = Thumbnail.Make(series.Samples);
        await store.IngestAsync(Ev(F.Status(logMax: 1, sessionId: 2), T0.AddSeconds(10)));
        var old = store.Sessions().First(s => s.Key == k);
        Assert.Equal(60, old.Thumbnail.Count);
        Assert.All(old.Thumbnail.Zip(expected), p =>
            Assert.True(Math.Abs(p.First.Core - p.Second.Core) < 1e-3 && Math.Abs(p.First.Ambient - p.Second.Ambient) < 1e-3));
    });

    // Live fetch

    [Fact]
    public void LiveFetchRequestsOnlyNewSeqsWhenMaxAdvances() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 100);
        using var store = MakeStore(f);
        // Each status is stored as the record at its max, so only seqs below it are requested.
        var key = await store.IngestAsync(Ev(F.Status(logMax: 5), T0));
        Assert.Equal([new Req(0, 4)], f.Requests);
        await store.IngestAsync(Ev(F.Status(logMax: 5), T0.AddSeconds(1))); // not advanced
        Assert.Single(f.Requests);
        await store.IngestAsync(Ev(F.Status(logMax: 6), T0.AddSeconds(5))); // next seq: nothing to fetch
        Assert.Single(f.Requests);
        await store.IngestAsync(Ev(F.Status(logMax: 8), T0.AddSeconds(10))); // seq 7 was skipped
        Assert.Equal([new Req(0, 4), new Req(7, 7)], f.Requests);
        Assert.Equal(9, store.SampleCount(key));
    });

    [Fact]
    public void LiveFetchIsCappedToOneChunkAndLeavesOlderHolesForBackfill() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 1000);
        using var store = MakeStore(f);
        var key = await store.IngestAsync(Ev(F.Status(logMax: 1000), T0));
        Assert.Equal([new Req(872, 999)], f.Requests);
        var r = await store.BackfillAsync(key, f);
        Assert.True(r.Remaining == 0 && r.Received == 872);
        Assert.Equal(1001, store.SampleCount(key));
    });

    [Fact]
    public void LiveFetchFailureKeepsPartialAndSessionState() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 10);
        f.Fail(onRequest: 1);
        using var store = MakeStore(f);
        var key = await store.IngestAsync(Ev(F.Status(logMax: 10), T0));
        Assert.Equal(1, store.SampleCount(key)); // only the status's own record
        Assert.Single(store.Sessions()); // status handling was not lost
    });

    [Fact]
    public void ExplicitFetcherOverridesDefault() => Det.Run(async () =>
    {
        var dflt = new StoreFakeFetcher(0, 5);
        var other = new StoreFakeFetcher(0, 5);
        using var store = MakeStore(dflt);
        await store.IngestAsync(Ev(F.Status(logMax: 5), T0), other);
        Assert.True(dflt.Requests.Count == 0 && other.Requests.Count == 1);
    });

    [Fact]
    public void ConsumeIngestsStatusEventsFromProbeStore() => Det.Run(async () =>
    {
        var clock = new TestClock();
        var probes = new ProbeStore(clock);
        using var store = new HistoryStore(":memory:", clock);
        var events = probes.StatusEvents();
        using var cts = new CancellationTokenSource();
        var task = store.ConsumeAsync(events, cts.Token);
        await clock.SettleAsync();
        probes.Ingest(F.Observe(F.St(F.Status(logMax: 3)), LinkKind.DirectConnection, clock.Now()));
        await clock.SettleAsync();
        Assert.Single(store.Sessions());
        cts.Cancel();
        await task;
        probes.Stop();
    });

    // Backfill

    [Fact]
    public void BackfillRequestsChunksOfOneTwentyEightNewestFirst() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 299);
        using var store = MakeStore(); // no live fetching
        var key = await store.IngestAsync(Ev(F.Status(logMax: 299), T0));
        var r = await store.BackfillAsync(key, f);
        // seq 299 is the status's own record.
        Assert.Equal([new Req(171, 298), new Req(43, 170), new Req(0, 42)], f.Requests);
        Assert.Equal(new BackfillResult(299, 299, 0, false), r);
        Assert.Equal(300, store.SampleCount(key));
    });

    [Fact]
    public void BackfillFillsFromTheRight() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 299);
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 299), T0));
        var clock = new TestClock();
        var log = new List<int>();
        using var cts = new CancellationTokenSource();
        var task = store.Series(key).ForEachAsync(s => log.Add(s.Samples.Count > 0 ? (int)s.Samples[0].Seq : -1), cts.Token);
        await clock.SettleAsync();
        Assert.Single(log);
        await store.BackfillAsync(key, f);
        await clock.SettleAsync();
        Assert.Equal(0, log[^1]);
        cts.Cancel();
        await task;
        Assert.Equal([299, 171, 43, 0], log.Where(v => v >= 0)); // earliest stored seq moves left chunk by chunk
    });

    [Fact]
    public void BackfillToleratesPartialResultsAndRetriesOnlyGaps() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 299);
        f.Withhold(Range(100, 110));
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 299), T0));
        var r1 = await store.BackfillAsync(key, f);
        Assert.True(r1.Received == 288 && r1.Remaining == 11 && !r1.Failed); // plus seq 299 from the status
        Assert.Equal(289, store.SampleCount(key));
        f.Release();
        var before = f.Requests.Count;
        var r2 = await store.BackfillAsync(key, f);
        Assert.Equal([new Req(100, 110)], f.Requests.Skip(before));
        Assert.Equal(new BackfillResult(11, 11, 0, false), r2);
        Assert.Equal(300, store.SampleCount(key));
        var r3 = await store.BackfillAsync(key, f);
        Assert.Equal(0, r3.Requested);
    });

    [Fact]
    public void BackfillStopsOnFetcherErrorKeepingWhatArrived() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 299);
        f.Fail(onRequest: 2);
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMax: 299), T0));
        var r1 = await store.BackfillAsync(key, f);
        Assert.True(r1.Failed && r1.Received == 128 && r1.Remaining == 171);
        Assert.Equal(2, f.Requests.Count); // chunk 3 was not attempted
        f.Fail(onRequest: null);
        var r2 = await store.BackfillAsync(key, f);
        Assert.True(!r2.Failed && r2.Remaining == 0);
        Assert.Equal(300, store.SampleCount(key));
    });

    [Fact]
    public void BackfillIgnoresRecordsOutsideTheRequestedRange() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMin: 10, logMax: 20), T0));
        await store.BackfillAsync(key, new Wild());
        Assert.Equal(Range(10, 20), store.CurrentSeries(key)?.Samples.Select(s => s.Seq));
    });

    [Fact]
    public void BackfillWithoutKnownRangeDoesNothing() => Det.Run(async () =>
    {
        using var store = MakeStore();
        var ghost = new SessionKey(F.Serial, 9, T0);
        var r = await store.BackfillAsync(ghost, new StoreFakeFetcher(0, 5));
        Assert.Equal(0, r.Requested);
    });

    [Fact]
    public void BackfillUsesLogRangeMinAfterWrap() => Det.Run(async () =>
    {
        var f = new StoreFakeFetcher(0, 500);
        using var store = MakeStore();
        var key = await store.IngestAsync(Ev(F.Status(logMin: 400, logMax: 500), T0));
        await store.BackfillAsync(key, f);
        Assert.Equal([new Req(400, 499)], f.Requests);
    });

    // Eight concurrent sessions

    [Fact]
    public void EightConcurrentSessions() => Det.Run(async () =>
    {
        var serials = Enumerable.Range(1, 8).Select(i => new ProbeSerial((uint)i)).ToList();
        var fetchers = serials.ToDictionary(s => s, _ => new StoreFakeFetcher(0, 299));
        var router = new Router(fetchers);
        using var store = MakeStore(router);
        var keys = new Dictionary<ProbeSerial, SessionKey>();
        for (var i = 0; i < serials.Count; i++)
        {
            var s = serials[i];
            keys[s] = await store.IngestAsync(Ev(F.Status(logMax: 299, sessionId: (uint)(100 + i)), T0.AddSeconds(i), s));
        }
        await Task.WhenAll(serials.Select(s => store.BackfillAsync(keys[s], router)));
        var list = store.Sessions();
        Assert.Equal(8, list.Count);
        Assert.All(list, x => Assert.True(x.SampleCount == 300 && x.Thumbnail.Count == 60));
        Assert.True(list.Select(x => x.Key.Serial).ToHashSet().SetEquals(serials));
        foreach (var s in serials)
        {
            var series = store.CurrentSeries(keys[s]);
            Assert.NotNull(series);
            Assert.Equal(300, series.Samples.Count);
            Assert.True(series.Downsampled(100).Count <= 100);
        }
    });
}
