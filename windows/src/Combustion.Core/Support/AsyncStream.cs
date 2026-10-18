using System.Runtime.CompilerServices;
using System.Threading.Channels;

namespace Combustion.Core;

/// <summary>
/// Port of Swift's <c>AsyncStream</c>/<c>AsyncThrowingStream</c>: an unbounded, single-consumer stream that a producer
/// feeds with <see cref="Yield"/> and ends with <see cref="Finish"/>. <see cref="OnTermination"/> runs once, when the
/// producer finishes or the consumer stops iterating. Thread-safe on the producer side.
/// </summary>
public sealed class AsyncStream<T> : IAsyncEnumerable<T>
{
    private readonly Channel<T> _channel = Channel.CreateUnbounded<T>(new UnboundedChannelOptions { SingleReader = true });
    private Action? _onTermination;
    private int _terminated;
    private int _enumerated;

    /// <summary>Runs once on finish or consumer cancel. Runs at once if the stream already terminated.</summary>
    public Action? OnTermination
    {
        get => _onTermination;
        set
        {
            _onTermination = value;
            if (Volatile.Read(ref _terminated) == 1 && Interlocked.Exchange(ref _onTermination, null) is { } run)
            {
                run();
            }
        }
    }

    public bool IsTerminated => Volatile.Read(ref _terminated) == 1;

    /// <summary>False once the stream has finished or its consumer has gone.</summary>
    public bool Yield(T value) => _channel.Writer.TryWrite(value);

    /// <summary>Ends the stream; with <paramref name="error"/> the consumer's <c>await foreach</c> throws it after the buffered elements.</summary>
    public void Finish(Exception? error = null)
    {
        _channel.Writer.TryComplete(error);
        Terminate();
    }

    private void Terminate()
    {
        if (Interlocked.Exchange(ref _terminated, 1) == 0 && Interlocked.Exchange(ref _onTermination, null) is { } run)
        {
            run();
        }
    }

    public async IAsyncEnumerator<T> GetAsyncEnumerator(CancellationToken ct = default)
    {
        if (Interlocked.Exchange(ref _enumerated, 1) == 1)
        {
            throw new InvalidOperationException("AsyncStream supports a single consumer");
        }
        try
        {
            var reader = _channel.Reader;
            while (await reader.WaitToReadAsync(ct))
            {
                while (reader.TryRead(out var item))
                {
                    yield return item;
                }
            }
        }
        finally
        {
            _channel.Writer.TryComplete();
            Terminate();
        }
    }

    /// <summary>Reads one element; null-like default plus false when the stream ended.</summary>
    public async Task<(bool HasValue, T Value)> NextAsync(CancellationToken ct = default)
    {
        if (await _channel.Reader.WaitToReadAsync(ct) && _channel.Reader.TryRead(out var item))
        {
            return (true, item);
        }
        return (false, default!);
    }

    /// <summary>Buffered elements not yet consumed (tests).</summary>
    public int BufferedCount => _channel.Reader.CanCount ? _channel.Reader.Count : 0;

    public static AsyncStream<T> Finished()
    {
        var s = new AsyncStream<T>();
        s.Finish();
        return s;
    }
}

public static class AsyncEnumerableExtensions
{
    /// <summary>Collects every element (tests and small finite streams).</summary>
    public static async Task<List<T>> ToListAsync<T>(this IAsyncEnumerable<T> source, CancellationToken ct = default)
    {
        var list = new List<T>();
        await foreach (var item in source.WithCancellation(ct))
        {
            list.Add(item);
        }
        return list;
    }

    /// <summary>Starts consuming <paramref name="source"/> on the current context, calling <paramref name="onItem"/> per element.</summary>
    public static async Task ForEachAsync<T>(this IAsyncEnumerable<T> source, Action<T> onItem, CancellationToken ct = default)
    {
        try
        {
            await foreach (var item in source.WithCancellation(ct))
            {
                onItem(item);
            }
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
        }
    }

    public static async IAsyncEnumerable<T> TakeAsync<T>(this IAsyncEnumerable<T> source, int count, [EnumeratorCancellation] CancellationToken ct = default)
    {
        if (count <= 0)
        {
            yield break;
        }
        var n = 0;
        await foreach (var item in source.WithCancellation(ct))
        {
            yield return item;
            if (++n >= count)
            {
                yield break;
            }
        }
    }
}
