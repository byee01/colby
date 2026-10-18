namespace Combustion.Core;

/// <summary>
/// Deterministic clock. Time moves only in <see cref="AdvanceAsync"/>.
/// <list type="bullet">
/// <item>Sleepers and timer ticks fire in deadline order (ties: registration order), and
/// <see cref="Monotonic"/>/<see cref="Now"/> read the deadline of the entry being fired.</item>
/// <item>After each fired entry, <c>AdvanceAsync</c> waits until all other work on the
/// <see cref="DeterministicContext"/> has run to its next suspension (<see cref="SettleAsync"/>), so a loop that
/// re-sleeps registers its next sleep, which is then honoured in the same advance if due.</item>
/// <item>Outside a <see cref="DeterministicContext"/>, settling only yields a few times.</item>
/// </list>
/// Swift's <c>wakeGrace</c> is not needed: everything runs on one thread.
/// </summary>
public sealed class TestClock : IClock
{
    public static readonly DateTimeOffset DefaultStart = DateTimeOffset.FromUnixTimeSeconds(1_700_000_000);
    private const int YieldsWithoutContext = 8;

    private abstract record Kind;
    private sealed record Sleeper(TaskCompletionSource Completion) : Kind;
    private sealed record Ticker(AsyncStream<TimeSpan> Stream, TimeSpan Period) : Kind;

    private sealed class Entry(ulong id, TimeSpan deadline, Kind kind)
    {
        public ulong Id { get; } = id;
        public TimeSpan Deadline { get; set; } = deadline;
        public Kind Kind { get; } = kind;
    }

    private readonly object _lock = new();
    private readonly DateTimeOffset _start;
    private readonly List<Entry> _entries = [];
    private TimeSpan _offset = TimeSpan.Zero;
    private ulong _nextId;

    public TestClock(DateTimeOffset? start = null)
    {
        _start = start ?? DefaultStart;
    }

    public DateTimeOffset Now() => _start + Monotonic();

    public TimeSpan Monotonic()
    {
        lock (_lock)
        {
            return _offset;
        }
    }

    /// <summary>Sleepers currently waiting.</summary>
    public int SleeperCount
    {
        get
        {
            lock (_lock)
            {
                return _entries.Count(e => e.Kind is Sleeper);
            }
        }
    }

    /// <summary>Timers currently live.</summary>
    public int TimerCount
    {
        get
        {
            lock (_lock)
            {
                return _entries.Count(e => e.Kind is Ticker);
            }
        }
    }

    public Task SleepAsync(TimeSpan duration, CancellationToken ct = default)
    {
        if (ct.IsCancellationRequested)
        {
            return Task.FromCanceled(ct);
        }
        if (duration <= TimeSpan.Zero)
        {
            return Task.CompletedTask;
        }
        var tcs = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        ulong id;
        lock (_lock)
        {
            id = _nextId++;
            _entries.Add(new Entry(id, _offset + duration, new Sleeper(tcs)));
        }
        if (ct.CanBeCanceled)
        {
            var reg = ct.Register(() =>
            {
                lock (_lock)
                {
                    _entries.RemoveAll(e => e.Id == id);
                }
                tcs.TrySetCanceled(ct);
            });
            tcs.Task.ContinueWith(_ => reg.Dispose(), TaskScheduler.Default);
        }
        return tcs.Task;
    }

    public AsyncStream<TimeSpan> Timer(TimeSpan period)
    {
        var stream = new AsyncStream<TimeSpan>();
        if (period <= TimeSpan.Zero)
        {
            stream.Finish();
            return stream;
        }
        ulong id;
        lock (_lock)
        {
            id = _nextId++;
            _entries.Add(new Entry(id, _offset + period, new Ticker(stream, period)));
        }
        stream.OnTermination = () =>
        {
            lock (_lock)
            {
                _entries.RemoveAll(e => e.Id == id);
            }
        };
        return stream;
    }

    /// <summary>Lets all other ready work run until it waits on something.</summary>
    public async Task SettleAsync()
    {
        if (DeterministicContext.Current is { } context)
        {
            await context.IdleAsync();
            return;
        }
        for (var i = 0; i < YieldsWithoutContext; i++)
        {
            await Task.Yield();
        }
    }

    public async Task AdvanceAsync(TimeSpan duration)
    {
        if (duration < TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(nameof(duration), "TestClock cannot go backwards");
        }
        await SettleAsync();
        TimeSpan target;
        lock (_lock)
        {
            target = _offset + duration;
        }
        while (FireNext(target) is { } fire)
        {
            fire();
            await SettleAsync();
        }
        lock (_lock)
        {
            _offset = target;
        }
        await SettleAsync();
    }

    public Task AdvanceAsync(double seconds) => AdvanceAsync(TimeSpan.FromSeconds(seconds));

    /// <summary>Pops the earliest due entry, moves time to its deadline and returns the action that wakes it (run outside the lock).</summary>
    private Action? FireNext(TimeSpan target)
    {
        lock (_lock)
        {
            Entry? best = null;
            foreach (var e in _entries)
            {
                if (e.Deadline <= target && (best is null || e.Deadline < best.Deadline || (e.Deadline == best.Deadline && e.Id < best.Id)))
                {
                    best = e;
                }
            }
            if (best is null)
            {
                return null;
            }
            if (best.Deadline > _offset)
            {
                _offset = best.Deadline;
            }
            switch (best.Kind)
            {
                case Sleeper s:
                    _entries.Remove(best);
                    return () => s.Completion.TrySetResult();
                case Ticker t:
                    var at = best.Deadline;
                    best.Deadline += t.Period;
                    return () => t.Stream.Yield(at);
                default:
                    return null;
            }
        }
    }
}
