namespace Combustion.Core;

/// <summary>Fan-out for <see cref="AsyncStream{T}"/>: every call to <see cref="Stream"/> gets its own stream.
/// With <c>replayLatest</c>, a new stream first receives the most recent value.</summary>
public sealed class Broadcaster<T>
{
    private readonly object _lock = new();
    private readonly Dictionary<ulong, AsyncStream<T>> _streams = [];
    private readonly bool _replayLatest;
    private ulong _nextId;
    private bool _hasLatest;
    private T _latest = default!;
    private bool _finished;

    public Broadcaster(bool replayLatest = false)
    {
        _replayLatest = replayLatest;
    }

    public Broadcaster(T initial, bool replayLatest = true)
    {
        _replayLatest = replayLatest;
        _latest = initial;
        _hasLatest = true;
    }

    public int SubscriberCount
    {
        get
        {
            lock (_lock)
            {
                return _streams.Count;
            }
        }
    }

    public AsyncStream<T> Stream()
    {
        var stream = new AsyncStream<T>();
        ulong id;
        bool finished, replay;
        T latest;
        lock (_lock)
        {
            id = _nextId++;
            finished = _finished;
            replay = _replayLatest && _hasLatest;
            latest = _latest;
            if (!finished)
            {
                _streams[id] = stream;
            }
        }
        if (replay)
        {
            stream.Yield(latest);
        }
        if (finished)
        {
            stream.Finish();
        }
        else
        {
            stream.OnTermination = () =>
            {
                lock (_lock)
                {
                    _streams.Remove(id);
                }
            };
        }
        return stream;
    }

    public void Send(T value)
    {
        AsyncStream<T>[] targets;
        lock (_lock)
        {
            if (_replayLatest)
            {
                _latest = value;
                _hasLatest = true;
            }
            targets = [.. _streams.Values];
        }
        foreach (var s in targets)
        {
            s.Yield(value);
        }
    }

    public void Finish()
    {
        AsyncStream<T>[] targets;
        lock (_lock)
        {
            _finished = true;
            targets = [.. _streams.Values];
            _streams.Clear();
        }
        foreach (var s in targets)
        {
            s.Finish();
        }
    }
}
