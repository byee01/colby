using Combustion.Codec;

namespace Combustion.Core;

/// <summary>What the UI shows for one probe's prediction. docs/02 §3, §7, §18.</summary>
/// <param name="PercentToRemoval">0...100; null when the set point is not above the heat-start temperature.</param>
/// <param name="SecondsRemaining">Smoothed and rounded; null unless predicting with at most 4 h to go.</param>
/// <param name="IsStale">No status for 15 s. The numbers are the last known ones.</param>
/// <param name="ReadyAt">Completion time shown beside the countdown. Anchored to the status that last moved the
/// countdown, so it does not creep while the (held) countdown stands still.</param>
/// <param name="ReadySince">When the state became <c>RemovalPredictionDone</c> ("Ready since 13:18"); null in any other state.</param>
public sealed record PredictionView(
    ProbeSerial Serial,
    PredictionState State,
    PredictionMode Mode,
    PredictionType Type,
    double Setpoint,
    double EstimatedCore,
    double? PercentToRemoval = null,
    uint? SecondsRemaining = null,
    bool IsStale = false,
    DateTimeOffset? ReadyAt = null,
    DateTimeOffset? ReadySince = null);

/// <summary>
/// Pure countdown logic for one probe: a port of the iOS SDK <c>PredictionManager</c> so the numbers match the
/// Display and the phone app. Times are passed in; nothing here reads a clock. docs/02 §7.
/// <list type="bullet">
/// <item>Seconds remaining exist only while <c>Predicting</c> with a raw value of at most 4 h.</item>
/// <item>Above 300 s: rounded to the nearest 15 s, and replaced only when the status <c>seq % 3 == 0</c> (or there is
/// no value yet). The Display and phone round the same way, so the three agree.</item>
/// <item>At 300 s and below: a linear countdown, advanced by <see cref="Tick"/>, aiming at <c>raw - statusPeriod</c>
/// by the time the next status is due.</item>
/// </list>
/// A value type, as in Swift: copies tick independently.
/// </summary>
internal struct PredictionSmoother
{
    public const uint MaxSeconds = 4 * 3600;
    public const uint CountdownLimit = 300;
    public const double RoundTo = 15.0;

    /// <summary>Dates near 2^31 s resolve to ~0.2 µs; a tick that lands this close to a deadline counts as on it.</summary>
    public const double Slack = 0.001;

    private double? _displayed;
    private DateTimeOffset? _readyAt;
    private (double From, double To, DateTimeOffset Start)? _ramp;

    public PredictionSmoother(double statusPeriod)
    {
        StatusPeriod = statusPeriod;
    }

    public double StatusPeriod { get; }

    public PredictionStatus? Status { get; private set; }

    public DateTimeOffset? LastStatusAt { get; private set; }

    public DateTimeOffset? ReadySince { get; private set; }

    /// <summary>True while the countdown still has to move between statuses (needs 200 ms ticks).</summary>
    public readonly bool IsRamping => _ramp is not null;

    public void Ingest(PredictionStatus s, uint seq, DateTimeOffset now)
    {
        // Bring the countdown up to this instant first, so a new ramp starts from what is on screen even if a
        // timer tick has not been delivered yet.
        Tick(now);
        Status = s;
        LastStatusAt = now;
        if (s.State == PredictionState.RemovalPredictionDone)
        {
            ReadySince ??= now;
        }
        else
        {
            ReadySince = null;
        }
        if (!(s.State == PredictionState.Predicting && s.RawSecondsRemaining <= MaxSeconds))
        {
            _displayed = null;
            _readyAt = null;
            _ramp = null;
            return;
        }
        double raw = s.RawSecondsRemaining;
        if (s.RawSecondsRemaining > CountdownLimit)
        {
            _ramp = null;
            if (_displayed is null || seq % 3 == 0)
            {
                var rounded = Math.Round(raw / RoundTo, MidpointRounding.AwayFromZero) * RoundTo;
                _displayed = rounded;
                _readyAt = now.AddSecondsExact(rounded);
            }
        }
        else
        {
            var from = _displayed ?? raw;
            _displayed = from;
            _ramp = (from, Math.Max(raw - StatusPeriod, 0), now);
            _readyAt = now.AddSecondsExact(raw);
        }
    }

    public void Tick(DateTimeOffset now)
    {
        if (_ramp is not { } r)
        {
            return;
        }
        var fraction = Math.Min(1, Math.Max(0, (now.Since(r.Start) + Slack) / StatusPeriod));
        _displayed = r.From + (r.To - r.From) * fraction;
        if (fraction >= 1)
        {
            _ramp = null;
        }
    }

    public readonly bool IsStale(DateTimeOffset now, double after)
    {
        if (LastStatusAt is not { } last)
        {
            return false;
        }
        return now.Since(last) + Slack >= after;
    }

    public readonly PredictionView? View(ProbeSerial serial, DateTimeOffset now, double staleAfter)
    {
        if (Status is not { } s)
        {
            return null;
        }
        return new PredictionView(
            serial, s.State, s.Mode, s.Type, s.Setpoint, s.EstimatedCore, s.PercentToRemoval,
            _displayed is { } d ? (uint)Math.Max(0, Math.Round(d, MidpointRounding.AwayFromZero)) : null,
            IsStale(now, staleAfter), _readyAt, ReadySince);
    }
}

/// <summary>A view change for one probe (all probes on one stream, for the alert engine and widgets).</summary>
public sealed record PredictionUpdate(ProbeSerial Serial, PredictionView View);

/// <summary>
/// Turns each probe's raw <see cref="PredictionStatus"/> into a <see cref="PredictionView"/> stream. docs/02 §7.
/// <para>Input: <see cref="ProbeStore.StatusEvents"/> (every accepted full status; <c>LogRange.Max</c> is the status
/// sequence). Output: <see cref="Predictions"/> per probe (latest value first, only changes after) and
/// <see cref="Updates"/> for all probes.</para>
/// <para>Timing runs on the injected <see cref="IClock"/>. A 200 ms timer runs only while some countdown is still
/// moving between statuses (the last five minutes). A 1 s timer watches for staleness (15 s after a probe's last
/// status, seen within a second) while any probe is reporting. With nothing counting down, that is all there is.</para>
/// Confined to the core context (Swift: actor).
/// </summary>
public sealed class PredictionPresenter
{
    public static readonly TimeSpan TickInterval = TimeSpan.FromMilliseconds(200);
    public static readonly TimeSpan StaleAfter = TimeSpan.FromSeconds(15);

    /// <summary>How often staleness is checked while a probe is reporting.</summary>
    internal static readonly TimeSpan StaleCheckInterval = TimeSpan.FromSeconds(1);

    private readonly ProbeStore _probes;
    private readonly IClock _clock;
    private readonly TimeSpan _tick;
    private readonly TimeSpan _stale;
    private readonly double _statusPeriod;

    private readonly ViewHub _hub = new();
    private readonly Broadcaster<PredictionUpdate> _updates = new();
    private readonly Dictionary<ProbeSerial, PredictionSmoother> _smoothers = [];
    private readonly Dictionary<ProbeSerial, PredictionView> _last = [];
    private CancellationTokenSource? _task;
    private CancellationTokenSource? _staleWatch;
    private CancellationTokenSource? _ticker;

    public PredictionPresenter(
        ProbeStore probes, IClock clock, TimeSpan? tickInterval = null, TimeSpan? staleAfter = null, double statusPeriod = 5)
    {
        _probes = probes;
        _clock = clock;
        _tick = tickInterval ?? TickInterval;
        _stale = staleAfter ?? StaleAfter;
        _statusPeriod = statusPeriod;
    }

    // Observables

    /// <summary>One probe's view: the latest value first (if any), then every change.</summary>
    public AsyncStream<PredictionView> Predictions(ProbeSerial serial) => _hub.Stream(serial);

    /// <summary>Every probe's changes, no replay.</summary>
    public AsyncStream<PredictionUpdate> Updates() => _updates.Stream();

    /// <summary>The view as of now, computed on the spot, so it is right even if a timer tick is still on its way.</summary>
    public PredictionView? View(ProbeSerial serial)
    {
        if (!_smoothers.TryGetValue(serial, out var s))
        {
            return null;
        }
        var now = _clock.Now();
        s.Tick(now);
        return s.View(serial, now, _stale.TotalSeconds);
    }

    // Lifecycle

    /// <summary>Subscribes to the store's status events. Idempotent.</summary>
    public void Start()
    {
        if (_task is not null)
        {
            return;
        }
        _task = new CancellationTokenSource();
        _ = _probes.StatusEvents().ForEachAsync(Ingest, _task.Token);
    }

    /// <summary>Stops listening and timing. Streams stay open.</summary>
    public void Stop()
    {
        _task?.Cancel();
        _task = null;
        _staleWatch?.Cancel();
        _staleWatch = null;
        _ticker?.Cancel();
        _ticker = null;
    }

    // Input

    public void Ingest(ProbeStatusEvent e)
    {
        var now = _clock.Now();
        var s = _smoothers.TryGetValue(e.Serial, out var known) ? known : new PredictionSmoother(_statusPeriod);
        s.Ingest(e.Status.Prediction, e.Status.LogRange.Max, now);
        _smoothers[e.Serial] = s;
        Publish(e.Serial, now);
        Reschedule();
    }

    // Timing

    private void Publish(ProbeSerial serial, DateTimeOffset now)
    {
        if (!_smoothers.TryGetValue(serial, out var s) || s.View(serial, now, _stale.TotalSeconds) is not { } v)
        {
            return;
        }
        if (_last.TryGetValue(serial, out var previous) && previous == v)
        {
            return;
        }
        _last[serial] = v;
        _hub.Send(v);
        _updates.Send(new PredictionUpdate(serial, v));
    }

    /// <summary>Starts or stops the two timers: 200 ms while a countdown is moving, 1 s while any probe could still go stale.</summary>
    private void Reschedule()
    {
        var now = _clock.Now();
        var limit = _stale.TotalSeconds;
        if (_smoothers.Values.Any(s => s.IsRamping))
        {
            _ticker ??= Run(_tick, Ticked);
        }
        else
        {
            _ticker?.Cancel();
            _ticker = null;
        }
        if (_smoothers.Values.Any(s => s.LastStatusAt is not null && !s.IsStale(now, limit)))
        {
            _staleWatch ??= Run(StaleCheckInterval, StaleChecked);
        }
        else
        {
            _staleWatch?.Cancel();
            _staleWatch = null;
        }
    }

    /// <summary>Runs <paramref name="body"/> on every tick of a clock timer until it returns false. Timers, not chains
    /// of sleeps: they re-arm themselves, so a tick is not lost when this loop is slow to run.</summary>
    private CancellationTokenSource Run(TimeSpan period, Func<bool> body)
    {
        var cts = new CancellationTokenSource();
        _ = Loop(_clock.Timer(period), body, cts.Token);
        return cts;
    }

    private static async Task Loop(AsyncStream<TimeSpan> ticks, Func<bool> body, CancellationToken ct)
    {
        try
        {
            await foreach (var _ in ticks.WithCancellation(ct))
            {
                if (ct.IsCancellationRequested || !body())
                {
                    return;
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
    }

    /// <summary>Returns false when no countdown is moving any more (the ticker then ends).</summary>
    private bool Ticked()
    {
        Refresh();
        return _ticker is not null;
    }

    /// <summary>Returns false once every probe is stale (the watcher then ends).</summary>
    private bool StaleChecked()
    {
        Refresh();
        return _staleWatch is not null;
    }

    private void Refresh()
    {
        var now = _clock.Now();
        foreach (var serial in _smoothers.Keys.ToList())
        {
            var s = _smoothers[serial];
            s.Tick(now);
            _smoothers[serial] = s;
            Publish(serial, now);
        }
        Reschedule();
    }

    /// <summary>Per-probe broadcasters behind a lock, so <see cref="Predictions"/> may be called from any thread.</summary>
    private sealed class ViewHub
    {
        private readonly object _lock = new();
        private readonly Dictionary<ProbeSerial, Broadcaster<PredictionView>> _casters = [];

        private Broadcaster<PredictionView> Caster(ProbeSerial serial)
        {
            lock (_lock)
            {
                if (!_casters.TryGetValue(serial, out var b))
                {
                    b = new Broadcaster<PredictionView>(replayLatest: true);
                    _casters[serial] = b;
                }
                return b;
            }
        }

        public AsyncStream<PredictionView> Stream(ProbeSerial serial) => Caster(serial).Stream();

        public void Send(PredictionView view) => Caster(view.Serial).Send(view);
    }
}
