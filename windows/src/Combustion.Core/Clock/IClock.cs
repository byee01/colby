namespace Combustion.Core;

/// <summary>
/// Injectable time (docs/02 §15). Nothing outside <see cref="SystemClock"/> may read
/// <c>DateTime.Now</c>, call <c>Task.Delay</c> or create a timer (enforced by BannedSymbols.txt).
/// </summary>
public interface IClock
{
    /// <summary>Wall clock (UTC).</summary>
    DateTimeOffset Now();

    /// <summary>Interval time since an arbitrary origin; never jumps.</summary>
    TimeSpan Monotonic();

    /// <summary>Cancellable. Throws <see cref="OperationCanceledException"/> when <paramref name="ct"/> fires.</summary>
    Task SleepAsync(TimeSpan duration, CancellationToken ct = default);

    /// <summary>Ticks every <paramref name="period"/>; each element is the monotonic time of the tick.
    /// The stream ends when its consumer stops iterating.</summary>
    AsyncStream<TimeSpan> Timer(TimeSpan period);
}

/// <summary>Real time, from <see cref="TimeProvider.System"/>.</summary>
public sealed class SystemClock : IClock
{
    private readonly TimeProvider _time;
    private readonly long _origin;

    public SystemClock(TimeProvider? time = null)
    {
        _time = time ?? TimeProvider.System;
        _origin = _time.GetTimestamp();
    }

    public DateTimeOffset Now() => _time.GetUtcNow();

    public TimeSpan Monotonic() => _time.GetElapsedTime(_origin);

    public Task SleepAsync(TimeSpan duration, CancellationToken ct = default) =>
        duration <= TimeSpan.Zero
            ? (ct.IsCancellationRequested ? Task.FromCanceled(ct) : Task.CompletedTask)
            : Task.Delay(duration, _time, ct);

    public AsyncStream<TimeSpan> Timer(TimeSpan period)
    {
        var stream = new AsyncStream<TimeSpan>();
        if (period <= TimeSpan.Zero)
        {
            stream.Finish();
            return stream;
        }
        var timer = _time.CreateTimer(_ => stream.Yield(Monotonic()), null, period, period);
        stream.OnTermination = () => timer.Dispose();
        return stream;
    }
}
