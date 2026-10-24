using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;
using Combustion.Codec;

namespace Combustion.Core;

/// <summary>What widgets read (docs/02 §18, 06 §17.2): one small JSON file in a shared container. macOS: the App
/// Group container read by the WidgetKit extension; Windows: the package's LocalState read by the widget provider.</summary>
/// <param name="Probes">Soonest finish first: predicting by <c>ReadyAt</c>, then ready, then the rest by probe number.</param>
public sealed record LiveSnapshot(DateTimeOffset WrittenAt, ValueList<LiveSnapshot.Probe> Probes)
{
    /// <param name="Serial">8-character hex serial.</param>
    /// <param name="Name">Cook nickname, if any; widgets fall back to "Probe &lt;number&gt;".</param>
    /// <param name="Core">°C; the widget formats units and clock from the OS and the app's units setting.</param>
    /// <param name="State"><see cref="PredictionState"/> name: notInserted, inserted, warming, predicting, removalPredictionDone, unknown.</param>
    /// <param name="ReadyAt">Completion time; widgets tick the countdown from this with a self-updating timer text.</param>
    /// <param name="Trend">Up to the last 30 core readings in °C, oldest first, for the trend line.</param>
    public sealed record Probe(
        string Serial,
        int Number,
        string? Name,
        double? Core,
        double? Target,
        string State,
        uint? SecondsRemaining,
        DateTimeOffset? ReadyAt,
        DateTimeOffset? ReadySince,
        bool IsOffline,
        bool IsStale,
        ValueList<double> Trend);

    /// <summary>Same JSON as Swift's <c>JSONEncoder</c> with <c>.iso8601</c> dates and <c>.sortedKeys</c>: camelCase
    /// keys in ordinal order, nulls omitted, dates as <c>yyyy-MM-ddTHH:mm:ssZ</c>.</summary>
    public byte[] Encode()
    {
        var node = JsonSerializer.SerializeToNode(this, JsonOptions);
        return JsonSerializer.SerializeToUtf8Bytes(SortKeys(node), JsonOptions);
    }

    public static LiveSnapshot Decode(ReadOnlySpan<byte> json) =>
        JsonSerializer.Deserialize<LiveSnapshot>(json, JsonOptions) ?? throw new JsonException("null snapshot");

    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Converters = { new Iso8601SecondsConverter(), new ValueListConverterFactory() },
    };

    private static JsonNode? SortKeys(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key, StringComparer.Ordinal)
            .Select(kv => KeyValuePair.Create(kv.Key, SortKeys(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(SortKeys).ToArray()),
        null => null,
        _ => node.DeepClone(),
    };

    /// <summary>Swift's <c>.iso8601</c> strategy: whole seconds, UTC, <c>Z</c>.</summary>
    private sealed class Iso8601SecondsConverter : JsonConverter<DateTimeOffset>
    {
        public override DateTimeOffset Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            DateTimeOffset.Parse(reader.GetString()!, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal).ToUniversalTime();

        public override void Write(Utf8JsonWriter writer, DateTimeOffset value, JsonSerializerOptions options) =>
            writer.WriteStringValue(value.UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture));
    }

    private sealed class ValueListConverterFactory : JsonConverterFactory
    {
        public override bool CanConvert(Type typeToConvert) =>
            typeToConvert.IsGenericType && typeToConvert.GetGenericTypeDefinition() == typeof(ValueList<>);

        public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options) =>
            (JsonConverter)Activator.CreateInstance(typeof(ValueListConverter<>).MakeGenericType(typeToConvert.GetGenericArguments()[0]))!;
    }

    private sealed class ValueListConverter<T> : JsonConverter<ValueList<T>>
    {
        public override ValueList<T> Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            new(JsonSerializer.Deserialize<List<T>>(ref reader, options) ?? []);

        public override void Write(Utf8JsonWriter writer, ValueList<T> value, JsonSerializerOptions options) =>
            JsonSerializer.Serialize(writer, value.ToList(), options);
    }
}

/// <summary>Where the snapshot goes.</summary>
public interface ILiveSnapshotWriting
{
    Task WriteAsync(byte[] data);
}

/// <summary>Writes atomically to a file path (temp file in the same folder, then a replacing move), so a widget never
/// reads half a file.</summary>
public sealed class FileLiveSnapshotWriter(string path) : ILiveSnapshotWriting
{
    public string Path { get; } = path;

    public async Task WriteAsync(byte[] data)
    {
        var temp = Path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            await File.WriteAllBytesAsync(temp, data);
            File.Move(temp, Path, overwrite: true);
        }
        catch
        {
            try
            {
                File.Delete(temp);
            }
            catch (IOException)
            {
            }
            throw;
        }
    }
}

/// <summary>Builds <see cref="LiveSnapshot"/> from the stores and writes it at most every <c>minInterval</c>, and at
/// once when something a widget shows as a state changes (prediction state, offline, stale, the probe set).
/// Confined to the core context (Swift: actor).</summary>
public sealed class LiveSnapshotWriter
{
    public const int TrendLength = 30;

    private const int WrittenLimit = 50;

    private readonly IClock _clock;
    private readonly ILiveSnapshotWriting _writer;
    private readonly TimeSpan _minInterval;

    private readonly Dictionary<ProbeSerial, ProbeSnapshot> _snapshots = [];
    private readonly Dictionary<ProbeSerial, PredictionView> _predictions = [];
    private HashSet<ProbeSerial> _followed = [];
    private readonly Dictionary<ProbeSerial, string?> _names = [];
    private readonly Dictionary<ProbeSerial, List<double>> _trends = [];
    private readonly Dictionary<ProbeSerial, DateTimeOffset> _lastTrendAt = [];

    private TimeSpan? _lastWrite;
    private List<string> _lastStateKey = [];
    private CancellationTokenSource? _pending;
    private CancellationTokenSource? _inputs;
    private readonly List<LiveSnapshot> _written = [];

    public LiveSnapshotWriter(IClock clock, ILiveSnapshotWriting writer, TimeSpan? minInterval = null)
    {
        _clock = clock;
        _writer = writer;
        _minInterval = minInterval ?? TimeSpan.FromSeconds(5);
    }

    /// <summary>Snapshots written so far, newest last (for tests and diagnostics).</summary>
    public IReadOnlyList<LiveSnapshot> Written => _written;

    public Exception? LastError { get; private set; }

    public void Start(
        IAsyncEnumerable<IReadOnlyDictionary<ProbeSerial, ProbeSnapshot>> probes,
        IAsyncEnumerable<PredictionUpdate> predictions,
        IAsyncEnumerable<IReadOnlySet<ProbeSerial>> followed)
    {
        if (_inputs is not null)
        {
            return;
        }
        _inputs = new CancellationTokenSource();
        var ct = _inputs.Token;
        _ = Consume(probes, IngestAsync, ct);
        _ = Consume(predictions, u => IngestAsync(u.View), ct);
        _ = Consume(followed, SetFollowedAsync, ct);
    }

    private static async Task Consume<T>(IAsyncEnumerable<T> source, Func<T, Task> body, CancellationToken ct)
    {
        try
        {
            await foreach (var item in source.WithCancellation(ct))
            {
                await body(item);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    public void Stop()
    {
        _inputs?.Cancel();
        _inputs = null;
        _pending?.Cancel();
        _pending = null;
    }

    public async Task SetNameAsync(string? name, ProbeSerial serial)
    {
        _names[serial] = name;
        await ChangedAsync();
    }

    /// <summary>Replaces every cook name (<c>HistoryStore.CookNames</c>).</summary>
    public async Task SetNamesAsync(IReadOnlyDictionary<ProbeSerial, string> map)
    {
        _names.Clear();
        foreach (var (serial, name) in map)
        {
            _names[serial] = name;
        }
        await ChangedAsync();
    }

    public async Task SetFollowedAsync(IReadOnlySet<ProbeSerial> set)
    {
        _followed = [.. set];
        await ChangedAsync();
    }

    public async Task IngestAsync(IReadOnlyDictionary<ProbeSerial, ProbeSnapshot> map)
    {
        var now = _clock.Now();
        foreach (var (serial, snap) in map)
        {
            if (!_followed.Contains(serial))
            {
                continue;
            }
            _snapshots[serial] = snap;
            // One trend point per probe sample period at most (5 s), not per advertisement.
            if (snap.Virtual.Core is { } core && !snap.IsOffline
                && (!_lastTrendAt.TryGetValue(serial, out var lastAt) || now.Since(lastAt) >= 5))
            {
                if (!_trends.TryGetValue(serial, out var t))
                {
                    t = [];
                    _trends[serial] = t;
                }
                t.Add(core);
                if (t.Count > TrendLength)
                {
                    t.RemoveRange(0, t.Count - TrendLength);
                }
                _lastTrendAt[serial] = now;
            }
        }
        await ChangedAsync();
    }

    public async Task IngestAsync(PredictionView view)
    {
        _predictions[view.Serial] = view;
        await ChangedAsync();
    }

    /// <summary>The snapshot for the current inputs.</summary>
    public LiveSnapshot Current()
    {
        var list = new List<LiveSnapshot.Probe>();
        foreach (var serial in _followed)
        {
            if (!_snapshots.TryGetValue(serial, out var snap))
            {
                continue;
            }
            var p = _predictions.GetValueOrDefault(serial);
            list.Add(new LiveSnapshot.Probe(
                serial.Hex, snap.ProbeNumber, _names.GetValueOrDefault(serial),
                snap.Virtual.Core, Target(p, snap.Prediction),
                StateName(p?.State ?? snap.Prediction?.State),
                p?.SecondsRemaining, p?.ReadyAt, p?.ReadySince,
                snap.IsOffline, p?.IsStale ?? false,
                _trends.TryGetValue(serial, out var trend) ? new ValueList<double>(trend) : ValueList<double>.Empty));
        }
        list.Sort(Order);
        return new LiveSnapshot(_clock.Now(), list);
    }

    // Private

    private async Task ChangedAsync()
    {
        var snapshot = Current();
        var key = StateKey(snapshot);
        var now = _clock.Monotonic();
        if (!key.SequenceEqual(_lastStateKey) || _lastWrite is not { } last || now - last >= _minInterval)
        {
            _lastStateKey = key;
            await FlushAsync(snapshot);
            return;
        }
        // Throttled: one trailing write when the interval is up.
        if (_pending is not null)
        {
            return;
        }
        var wait = _minInterval - (now - last);
        var cts = new CancellationTokenSource();
        _pending = cts;
        _ = TrailingAsync(wait, cts.Token);
    }

    private async Task TrailingAsync(TimeSpan wait, CancellationToken ct)
    {
        try
        {
            await _clock.SleepAsync(wait, ct);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        _pending = null;
        var snapshot = Current();
        _lastStateKey = StateKey(snapshot);
        await FlushAsync(snapshot);
    }

    private async Task FlushAsync(LiveSnapshot snapshot)
    {
        _pending?.Cancel();
        _pending = null;
        _lastWrite = _clock.Monotonic();
        try
        {
            await _writer.WriteAsync(snapshot.Encode());
            _written.Add(snapshot);
            if (_written.Count > WrittenLimit)
            {
                _written.RemoveRange(0, _written.Count - WrittenLimit);
            }
        }
        catch (Exception error)
        {
            LastError = error;
        }
    }

    /// <summary>The set point, only while a prediction mode is set (mode none carries a meaningless set point).</summary>
    private static double? Target(PredictionView? view, PredictionStatus? status)
    {
        if (view is not null)
        {
            return view.Mode == PredictionMode.None ? null : view.Setpoint;
        }
        if (status is not { } s || s.Mode == PredictionMode.None)
        {
            return null;
        }
        return s.Setpoint;
    }

    /// <summary>What a widget shows as a state, so a change is written at once: probe set and order, prediction state,
    /// offline, stale, and whether a completion time exists (its value moves every status; that is throttled).</summary>
    private static List<string> StateKey(LiveSnapshot snapshot) =>
        snapshot.Probes.Select(p => $"{p.Serial}:{p.State}:{Bool(p.IsOffline)}:{Bool(p.IsStale)}:{Bool(p.ReadyAt is not null)}").ToList();

    private static string Bool(bool b) => b ? "true" : "false";

    private static string StateName(PredictionState? state)
    {
        if (state is not { } s)
        {
            return "unknown";
        }
        var name = s.ToString();
        return char.ToLowerInvariant(name[0]) + name[1..];
    }

    private static int Order(LiveSnapshot.Probe a, LiveSnapshot.Probe b)
    {
        static int Rank(LiveSnapshot.Probe p)
        {
            if (p.State == "predicting" && p.ReadyAt is not null)
            {
                return 0;
            }
            return p.State == "removalPredictionDone" ? 1 : 2;
        }
        int ra = Rank(a), rb = Rank(b);
        if (ra != rb)
        {
            return ra.CompareTo(rb);
        }
        if (ra == 0 && a.ReadyAt is { } x && b.ReadyAt is { } y && x != y)
        {
            return x.CompareTo(y);
        }
        return a.Number.CompareTo(b.Number);
    }
}
