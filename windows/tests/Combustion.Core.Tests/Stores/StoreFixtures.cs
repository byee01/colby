using System.Runtime.CompilerServices;

namespace Combustion.Core.Tests;

public static class StoreFixtures
{
    public static readonly DateTimeOffset T0 = TestClock.DefaultStart;
    public static readonly ProbeSerial Serial = new(0x1000_5A3F);

    public static VirtualSensors Virtual(SensorIndex core = SensorIndex.T1, SensorIndex surface = SensorIndex.T4, SensorIndex ambient = SensorIndex.T5) =>
        new(core, surface, ambient);

    /// <summary>T1 core, T4 surface, T5 ambient (default virtual sensors); others fill with the core value.</summary>
    public static ProbeTemperatures Temps(double core = 25, double surface = 30, double ambient = 40) =>
        ProbeTemperatures.FromCelsius([core, core, core, surface, ambient, core, core, core]);

    public static PredictionStatus Prediction(
        PredictionState state = PredictionState.NotInserted, PredictionMode mode = PredictionMode.None, double setpoint = 0,
        uint seconds = 0, double est = 25) =>
        new(state, mode, mode == PredictionMode.None ? PredictionType.None : PredictionType.Removal, setpoint, 20, seconds, est);

    public static ProbeStatusPayload Status(
        double core = 25, double surface = 30, double ambient = 40, ProbeMode mode = ProbeMode.Normal,
        uint logMin = 0, uint logMax = 0, uint? sessionId = 1, ushort periodMs = 5000,
        PredictionStatus? prediction = null, AlarmConfig? alarms = null, bool noAlarms = false, bool batteryLow = false) =>
        new(new LogRange(logMin, logMax), Temps(core, surface, ambient), mode, ProbeColor.Yellow, 1, batteryLow, Virtual(),
            prediction ?? Prediction(), FoodSafe: null, Overheating: SensorSet.Empty, Preferences: null,
            Alarms: noAlarms ? null : alarms ?? new AlarmConfig(),
            Session: sessionId is { } id ? new SessionInfo(id, periodMs) : null);

    public static ProbeAdvertisement Advertisement(ProbeSerial? serial = null, double core = 25, ProbeMode mode = ProbeMode.Normal, double? t1 = null)
    {
        var t = Temps(core);
        if (t1 is { } v)
        {
            var c = t.Celsius.ToArray();
            c[0] = v;
            t = ProbeTemperatures.FromCelsius(c);
        }
        return new ProbeAdvertisement(serial ?? Serial, t, mode, ProbeColor.Yellow, 1, false, Virtual());
    }

    public static LinkSource Source(LinkKind kind, string? via = null, int? hop = null, DateTimeOffset? at = null) =>
        new(kind, at ?? T0, via, hop, -60, null);

    public static ProbeObservation Observe(ObservationPayload payload, LinkKind kind, DateTimeOffset at, string? via = null, int? hop = null, ProbeSerial? serial = null) =>
        new(serial ?? Serial, Source(kind, via, hop, at), payload, at);

    public static ObservationPayload Ad(ProbeAdvertisement a) => new ObservationPayload.Advertisement(a);

    public static ObservationPayload St(ProbeStatusPayload s) => new ObservationPayload.Status(s);

    // Log records

    public static LogRecord Record(uint seq, double? core = null, double surface = 30, double ambient = 40,
        PredictionMode mode = PredictionMode.None, double setpoint = 0, PredictionState state = PredictionState.NotInserted)
    {
        var c = core ?? 20 + (seq % 600) * 0.5;
        return new LogRecord(seq, Temps(c, surface, ambient),
            new PredictionLog(Virtual(), state, mode, mode == PredictionMode.None ? PredictionType.None : PredictionType.Removal, setpoint, 0, c));
    }
}

public sealed class FetchFailure : Exception;

/// <summary>Log source for tests. Serves <c>records</c>, optionally withholding seqs (partial results) or failing a request.</summary>
public sealed class StoreFakeFetcher : ILogFetcher
{
    public readonly record struct Request(uint Start, uint End);

    private readonly object _lock = new();
    private readonly Dictionary<uint, LogRecord> _records = [];
    private HashSet<uint> _withheld = [];
    private int? _failOnRequest;
    private readonly List<Request> _log = [];

    public StoreFakeFetcher(uint? first = null, uint? last = null, Func<uint, double>? core = null)
    {
        if (first is { } a && last is { } b)
        {
            for (var s = a; s <= b; s++)
            {
                _records[s] = StoreFixtures.Record(s, core?.Invoke(s));
            }
        }
    }

    public void Add(LogRecord r)
    {
        lock (_lock)
        {
            _records[r.Sequence] = r;
        }
    }

    public void AddRange(uint first, uint last)
    {
        for (var s = first; s <= last; s++)
        {
            Add(StoreFixtures.Record(s));
        }
    }

    public void Withhold(IEnumerable<uint> seqs)
    {
        lock (_lock)
        {
            _withheld = [.. seqs];
        }
    }

    public void Release()
    {
        lock (_lock)
        {
            _withheld = [];
        }
    }

    /// <summary>Throws (after delivering nothing) on the n-th request, 1-based.</summary>
    public void Fail(int? onRequest)
    {
        lock (_lock)
        {
            _failOnRequest = onRequest;
        }
    }

    public IReadOnlyList<Request> Requests
    {
        get
        {
            lock (_lock)
            {
                return [.. _log];
            }
        }
    }

    public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end)
    {
        List<LogRecord> recs;
        bool fails;
        lock (_lock)
        {
            _log.Add(new Request(start, end));
            var n = _log.Count;
            recs = [];
            for (var s = (long)start; s <= end; s++)
            {
                if (!_withheld.Contains((uint)s) && _records.TryGetValue((uint)s, out var r))
                {
                    recs.Add(r);
                }
            }
            fails = _failOnRequest == n;
        }
        var stream = new AsyncStream<LogRecord>();
        if (fails)
        {
            stream.Finish(new FetchFailure());
        }
        else
        {
            foreach (var r in recs)
            {
                stream.Yield(r);
            }
            stream.Finish();
        }
        return stream;
    }
}

/// <summary>Collects a stream's elements on the current context until cancelled (Swift: a Task appending to a log).</summary>
public sealed class Collector<T> : IDisposable
{
    private readonly CancellationTokenSource _cts = new();

    public Collector(IAsyncEnumerable<T> source)
    {
        Done = source.ForEachAsync(Items.Add, _cts.Token);
    }

    public List<T> Items { get; } = [];

    public Task Done { get; }

    public int Count => Items.Count;

    public T? Last => Items.Count > 0 ? Items[^1] : default;

    public void Dispose() => _cts.Cancel();
}

public static class StreamTestExtensions
{
    public static Collector<T> Collect<T>(this IAsyncEnumerable<T> source) => new(source);

    /// <summary>First element matching <paramref name="predicate"/>, or default when the stream ends.</summary>
    public static async Task<T?> FirstAsync<T>(this IAsyncEnumerable<T> source, Func<T, bool> predicate)
    {
        await foreach (var v in source)
        {
            if (predicate(v))
            {
                return v;
            }
        }
        return default;
    }
}
