using Combustion.Sim;

namespace Combustion.Core.Tests.EndToEnd;

/// <summary>Delegates to a <see cref="SimulatedTransport"/> and records when <c>ConnectAsync</c> was called.</summary>
public sealed class ConnectSpyTransport(SimulatedTransport inner, TestClock clock) : IBleTransport
{
    private readonly List<TimeSpan> _times = [];

    public SimulatedTransport Inner { get; } = inner;

    /// <summary>Monotonic times of every connect call, successful or not.</summary>
    public IReadOnlyList<TimeSpan> Attempts => [.. _times];

    public AsyncStream<BluetoothState> State() => Inner.State();

    public AsyncStream<RawAdvertisement> Advertisements() => Inner.Advertisements();

    public Task StartScanAsync() => Inner.StartScanAsync();

    public Task StopScanAsync() => Inner.StopScanAsync();

    public Task<IGattConnection> ConnectAsync(PeripheralId id, TimeSpan timeout, CancellationToken ct = default)
    {
        _times.Add(clock.Monotonic());
        return Inner.ConnectAsync(id, timeout, ct);
    }
}

/// <summary>A <see cref="CombustionApp"/> over a simulated transport and a <see cref="TestClock"/>.
/// Use inside <see cref="Det.Run"/>: the clock then settles exactly, so the Swift rig's <c>drain</c> (real-time
/// polling until the pipeline is quiet) is one <see cref="TestClock.SettleAsync"/>.</summary>
public sealed class E2ERig : IDisposable
{
    public E2ERig(
        IConnectionPolicy? policy = null, IReadOnlyList<IAlertSink>? alertSinks = null, IKeepAwake? keepAwake = null,
        ILiveSnapshotWriting? liveSnapshot = null)
    {
        Transport = new SimulatedTransport(Clock);
        Spy = new ConnectSpyTransport(Transport, Clock);
        Trace = new JsonlTraceSink(Clock);
        App = new CombustionApp(
            Spy, Clock, policy: policy, trace: Trace, alertSinks: alertSinks, keepAwake: keepAwake,
            liveSnapshot: liveSnapshot);
    }

    public TestClock Clock { get; } = new();

    public SimulatedTransport Transport { get; }

    public ConnectSpyTransport Spy { get; }

    public CombustionApp App { get; }

    public JsonlTraceSink Trace { get; }

    public void Dispose()
    {
        App.Dispose();
        Trace.Dispose();
    }

    public SimulatedProbe Probe(ProbeSerial serial, int preload = 0, uint sessionId = 1, double offset = 0, TimeSpan? period = null)
    {
        var p = new SimulatedProbe(serial, Transport, Clock, sessionId: sessionId,
            samplePeriod: period ?? TimeSpan.FromSeconds(5), curve: SimulatedProbe.CookCurve(offset: offset));
        if (preload > 0)
        {
            p.Preload(preload);
        }
        p.Start();
        return p;
    }

    /// <summary>Advances virtual time in <paramref name="step"/>s, letting the pipeline settle after each.</summary>
    public async Task RunAsync(TimeSpan total, TimeSpan? step = null)
    {
        var s = step ?? TimeSpan.FromSeconds(5);
        var left = total;
        while (left > TimeSpan.Zero)
        {
            // End each step on a multiple of `step` so the probes' sample ticks (every 5 s) are the last
            // thing in a step: the stages that read the clock on receipt then see the sample's own time.
            var into = Clock.Monotonic().TotalSeconds % s.TotalSeconds;
            var d = Min(left, s - TimeSpan.FromSeconds(into));
            await Clock.AdvanceAsync(d);
            await DrainAsync();
            left -= d;
        }
    }

    public Task RunAsync(double seconds, double step = 5) =>
        RunAsync(TimeSpan.FromSeconds(seconds), TimeSpan.FromSeconds(step));

    /// <summary>Lets the pipeline consume what the last step produced, before time moves again.</summary>
    public Task DrainAsync() => Clock.SettleAsync();

    /// <summary>Scheduler turns (no virtual time) until <paramref name="condition"/> holds.</summary>
    public async Task<bool> EventuallyAsync(Func<bool> condition)
    {
        for (var i = 0; i < 20; i++)
        {
            if (condition())
            {
                return true;
            }
            await Clock.SettleAsync();
        }
        return condition();
    }

    /// <summary>Runs in <paramref name="step"/>s until <paramref name="condition"/> holds or <paramref name="limit"/> of virtual time has passed.</summary>
    public async Task<bool> RunUntilAsync(Func<bool> condition, double limit = 120, double step = 1)
    {
        var spent = 0.0;
        while (spent < limit)
        {
            if (condition())
            {
                return true;
            }
            await RunAsync(step, step);
            spent += step;
        }
        return condition();
    }

    public bool Connected(ProbeSerial serial) =>
        App.Diagnostics().Links.TryGetValue(serial, out var s) && s is ProbeConnectionState.Connected;

    public ProbeConnectionState? LinkState(ProbeSerial serial) =>
        App.Diagnostics().Links.TryGetValue(serial, out var s) ? s : null;

    /// <summary>The seqs stored for the latest session of <paramref name="serial"/>, ascending.</summary>
    public List<uint> StoredSeqs(ProbeSerial serial, int session = 0)
    {
        var sessions = App.History.Sessions(serial);
        if (session >= sessions.Count || App.History.CurrentSeries(sessions[session].Key) is not { } series)
        {
            return [];
        }
        return [.. series.Samples.Select(x => x.Seq)];
    }

    public TemperatureSeries Series(ProbeSerial serial, int session = 0)
    {
        var sessions = App.History.Sessions(serial);
        Assert.True(session < sessions.Count, $"no session {session} for {serial}");
        var series = App.History.CurrentSeries(sessions[session].Key);
        Assert.NotNull(series);
        return series;
    }

    private static TimeSpan Min(TimeSpan a, TimeSpan b) => a < b ? a : b;
}

public static class E2E
{
    public static readonly ProbeSerial SerialA = new(0x1000_000A);
    public static readonly ProbeSerial SerialB = new(0x1000_000B);
    public static readonly ProbeSerial SerialC = new(0x1000_000C);

    public static List<uint> Contiguous(uint from, uint to) =>
        [.. Enumerable.Range((int)from, (int)(to - from + 1)).Select(i => (uint)i)];

    /// <summary>Connect-attempt times (seconds) against the schedule the backoff should produce. Everything runs on
    /// one thread, so no task resumes late in virtual time: the Swift rig's 5 s slack is 0 here.</summary>
    public static void ExpectSchedule(IReadOnlyList<double> actual, IReadOnlyList<double> expected, double slack = 0)
    {
        Assert.True(actual.Count == expected.Count, $"attempts [{string.Join(", ", actual)}]");
        foreach (var (a, e) in actual.Zip(expected))
        {
            Assert.True(a >= e - 1e-9 && a <= e + slack + 1e-9,
                $"attempt at {a}, expected {e} (+{slack} s allowed) in [{string.Join(", ", actual)}]");
        }
    }
}
