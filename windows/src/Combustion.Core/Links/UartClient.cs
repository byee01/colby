using Combustion.Codec;

namespace Combustion.Core;

public enum UartErrorKind
{
    /// <summary>No response within the timeout, retries exhausted (or, for <c>ReadLogs</c>, nothing at all arrived).</summary>
    Timeout,
    /// <summary>The device answered with <c>success = 0</c>.</summary>
    Failure,
    /// <summary>The connection went away (or the client was closed / never started).</summary>
    Disconnected,
    /// <summary>A response arrived that the codec could not decode.</summary>
    Codec,
    /// <summary>Probe variant: a request of the same message type is already in flight.</summary>
    Busy,
}

/// <summary>Failures of a UART request (docs/02 §5.5). Swift <c>UartError</c>.</summary>
public sealed class UartException : Exception
{
    public UartException(UartErrorKind kind, CodecError? codecError = null)
        : base(codecError is null ? $"UART {kind}" : $"UART {kind}: {codecError}")
    {
        Kind = kind;
        CodecError = codecError;
    }

    public UartErrorKind Kind { get; }

    public CodecError? CodecError { get; }

    public static UartException Timeout => new(UartErrorKind.Timeout);
    public static UartException Failure => new(UartErrorKind.Failure);
    public static UartException Disconnected => new(UartErrorKind.Disconnected);
    public static UartException Busy => new(UartErrorKind.Busy);
}

/// <summary>Counters for the diagnostics screen. Nothing here is thrown.</summary>
public sealed record UartDiagnostics
{
    /// <summary>Garbage bytes skipped or frames with a bad CRC.</summary>
    public int FramingErrors { get; init; }

    /// <summary>Response frames that matched no in-flight request (late, mismatched ID, or wrong type).</summary>
    public int IgnoredFrames { get; init; }

    /// <summary>Node responses dropped because their Response ID was already seen.</summary>
    public int DuplicateResponses { get; init; }

    /// <summary>Frames that matched a request but failed to decode (the request fails with <c>Codec</c>).</summary>
    public int CodecErrors { get; init; }
}

/// <summary>
/// UART framing, request/response correlation and timeouts over a Nordic UART connection. docs/02 §5.3, §5.4, §5.5.
/// <list type="bullet">
/// <item>Probe variant: no request IDs. One in-flight request per message type, matched by type;
/// a second request of the same type throws <c>Busy</c>.</item>
/// <item>Node variant: a random u32 request ID per request, matched on Request ID. Duplicate Response IDs
/// (the repeater network can deliver copies) are dropped.</item>
/// </list>
/// Call <see cref="StartAsync"/> once before sending (it subscribes to UART TX). Timeouts run on the injected clock.
/// </summary>
public sealed class UartClient
{
    private abstract record Event
    {
        public sealed record Response(UartResponse Value) : Event;
        public sealed record Error(UartException Value) : Event;
        public sealed record TimedOut : Event;
    }

    /// <summary>Probe: by message type; node: by request ID.</summary>
    private readonly record struct Key(bool ById, uint Value);

    private sealed class Pending(ulong token, byte messageType, AsyncStream<Event> events, bool multi)
    {
        public ulong Token { get; } = token;
        public byte MessageType { get; } = messageType;
        public AsyncStream<Event> Events { get; } = events;
        /// <summary>Several responses expected (readLogs); the owner decides when it is finished.</summary>
        public bool Multi { get; } = multi;
        public CancellationTokenSource? Timer { get; set; }
    }

    private const int SeenResponseLimit = 512;

    private readonly IGattConnection _connection;
    private readonly IClock _clock;
    private readonly Func<uint> _nextRequestId;
    private readonly Broadcaster<UartFrame> _unsolicited = new();
    private readonly UartFramer _framer;
    private readonly Dictionary<Key, Pending> _pending = [];
    private readonly HashSet<uint> _seenResponseIds = [];
    private readonly Queue<uint> _seenResponseOrder = new();
    private readonly SemaphoreSlim _writeLock = new(1, 1);
    private bool _started;
    private bool _closed;
    private CancellationTokenSource? _reader;
    private ulong _nextToken;
    private UartDiagnostics _stats = new();

    /// <param name="requestIds">Source of node request IDs; inject a deterministic one in tests.</param>
    public UartClient(UartVariant variant, IGattConnection connection, IClock clock, Func<uint>? requestIds = null)
    {
        Variant = variant;
        _connection = connection;
        _clock = clock;
        _nextRequestId = requestIds ?? (() => (uint)Random.Shared.NextInt64(0, (long)uint.MaxValue + 1));
        _framer = new UartFramer(variant, UartDirection.Response);
    }

    public UartVariant Variant { get; }

    /// <summary>Request-direction frames that are not answers to our requests: node 0x45 status, 0x49 heartbeat, ...
    /// Each call returns a new stream; subscribe before <see cref="StartAsync"/> so nothing is missed.</summary>
    public AsyncStream<UartFrame> Unsolicited() => _unsolicited.Stream();

    public UartDiagnostics Diagnostics => _stats;

    // Lifecycle

    /// <summary>Subscribes to UART TX and starts routing frames. Idempotent. Throws the transport's error
    /// (for example <c>CharacteristicNotFound</c>), or <c>Disconnected</c> once closed.</summary>
    public async Task StartAsync()
    {
        if (_closed)
        {
            throw UartException.Disconnected;
        }
        if (_started)
        {
            return;
        }
        _started = true;
        AsyncStream<byte[]> stream;
        try
        {
            stream = await _connection.SubscribeAsync(GattUuid.UartTx);
        }
        catch
        {
            _started = false;
            throw;
        }
        if (_closed)
        {
            throw UartException.Disconnected;
        }
        _reader = new CancellationTokenSource();
        _ = ReadAsync(stream, _reader.Token);
    }

    private async Task ReadAsync(AsyncStream<byte[]> stream, CancellationToken ct)
    {
        try
        {
            await foreach (var bytes in stream.WithCancellation(ct))
            {
                Handle(bytes);
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        Shutdown();
    }

    /// <summary>Fails every pending request with <c>Disconnected</c> and stops routing. Does not close the connection.</summary>
    public void Close()
    {
        _reader?.Cancel();
        Shutdown();
    }

    private void Shutdown()
    {
        _closed = true;
        _reader = null;
        foreach (var (key, p) in _pending.ToList())
        {
            p.Timer?.Cancel();
            p.Events.Yield(new Event.Error(UartException.Disconnected));
            p.Events.Finish();
            _pending.Remove(key);
        }
        _unsolicited.Finish();
    }

    // Send

    /// <summary>
    /// Sends one request and waits for its response. <paramref name="timeout"/> applies per attempt; on timeout the same
    /// bytes (same request ID) are written again up to <paramref name="retries"/> more times.
    /// For the node variant pass the <paramref name="probe"/> the request is addressed to.
    /// A response with <c>success = 0</c> throws <c>Failure</c>.
    /// </summary>
    public async Task<UartResponse> SendAsync(
        UartRequest request, ProbeSerial? probe = null, TimeSpan? timeout = null, int retries = 1, CancellationToken ct = default)
    {
        var perAttempt = timeout ?? TimeSpan.FromSeconds(3);
        var (key, bytes) = Prepare(request, probe);
        var (token, events) = Register(key, request.MessageType, multi: false);
        try
        {
            var attempts = 0;
            while (true)
            {
                Arm(key, token, perAttempt);
                try
                {
                    await WriteAsync(bytes);
                }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    throw UartException.Disconnected;
                }
                var (has, ev) = await events.NextAsync(ct);
                if (!has)
                {
                    ct.ThrowIfCancellationRequested();
                    throw UartException.Disconnected;
                }
                switch (ev)
                {
                    case Event.Response { Value: var r }:
                        return r.Success ? r : throw UartException.Failure;
                    case Event.Error { Value: var e }:
                        throw e;
                    default:
                        if (attempts >= retries)
                        {
                            throw UartException.Timeout;
                        }
                        attempts++;
                        break;
                }
            }
        }
        finally
        {
            Complete(key, token);
        }
    }

    // ReadLogs

    /// <summary>
    /// Streams log records in [<paramref name="start"/>, <paramref name="end"/>]. One request, N responses. Finishes after
    /// the record with <c>sequence &gt;= end</c>, or after <paramref name="idleTimeout"/> with no further record (partial
    /// range: the caller sees which sequence numbers arrived). Duplicate sequence numbers are dropped; gaps are not filled.
    /// Throws <c>Timeout</c> if nothing at all arrived, <c>Failure</c> on <c>success = 0</c>, <c>Disconnected</c>, <c>Busy</c>.
    /// For the node variant pass the <paramref name="probe"/>; records for other probes are ignored.
    /// </summary>
    public AsyncStream<LogRecord> ReadLogs(uint start, uint end, ProbeSerial? probe = null, TimeSpan? idleTimeout = null)
    {
        var output = new AsyncStream<LogRecord>();
        var cts = new CancellationTokenSource();
        output.OnTermination = cts.Cancel;
        _ = PumpLogsAsync(probe, start, end, idleTimeout ?? TimeSpan.FromSeconds(2), output, cts.Token);
        return output;
    }

    private async Task PumpLogsAsync(ProbeSerial? probe, uint start, uint end, TimeSpan idleTimeout, AsyncStream<LogRecord> output, CancellationToken ct)
    {
        // Let the caller start consuming first (Swift starts the pump in a new Task).
        await Task.Yield();
        try
        {
            var (key, bytes) = Prepare(new UartRequest.ReadLogs(start, end), probe);
            var (token, events) = Register(key, UartMessageType.ReadLogs, multi: true);
            try
            {
                Arm(key, token, idleTimeout);
                try
                {
                    await WriteAsync(bytes);
                }
                catch (Exception e) when (e is not OperationCanceledException)
                {
                    throw UartException.Disconnected;
                }
                var seen = new HashSet<uint>();
                while (true)
                {
                    var (has, ev) = await events.NextAsync(ct);
                    if (!has)
                    {
                        break;
                    }
                    switch (ev)
                    {
                        case Event.TimedOut:
                            if (seen.Count == 0)
                            {
                                throw UartException.Timeout;
                            }
                            output.Finish();
                            return;
                        case Event.Error { Value: var e }:
                            throw e;
                        case Event.Response { Value: var r }:
                            if (!r.Success)
                            {
                                throw UartException.Failure;
                            }
                            if (r.Body is not ResponseBody.LogRecordBody { Probe: var from, Record: var record })
                            {
                                continue;
                            }
                            if (probe is { } p && from is { } f && f != p)
                            {
                                continue;
                            }
                            if (!seen.Add(record.Sequence))
                            {
                                continue;
                            }
                            Arm(key, token, idleTimeout);
                            output.Yield(record);
                            if (record.Sequence >= end)
                            {
                                output.Finish();
                                return;
                            }
                            break;
                    }
                }
                ct.ThrowIfCancellationRequested();
                throw UartException.Disconnected;
            }
            finally
            {
                Complete(key, token);
            }
        }
        catch (Exception e)
        {
            output.Finish(e);
        }
    }

    // Request bookkeeping

    private (Key, byte[]) Prepare(UartRequest request, ProbeSerial? probe)
    {
        if (!_started || _closed)
        {
            throw UartException.Disconnected;
        }
        uint? id = null;
        if (Variant == UartVariant.Node)
        {
            var candidate = _nextRequestId();
            while (_pending.ContainsKey(new Key(true, candidate)))
            {
                candidate = _nextRequestId();
            }
            id = candidate;
        }
        byte[] bytes;
        try
        {
            bytes = CombustionCodec.EncodeRequest(Variant, request, probe, id);
        }
        catch (CodecException e)
        {
            throw new UartException(UartErrorKind.Codec, e.Error);
        }
        var key = id is { } i ? new Key(true, i) : new Key(false, request.MessageType);
        return (key, bytes);
    }

    private (ulong, AsyncStream<Event>) Register(Key key, byte messageType, bool multi)
    {
        if (_pending.ContainsKey(key))
        {
            throw UartException.Busy;
        }
        var token = ++_nextToken;
        var events = new AsyncStream<Event>();
        _pending[key] = new Pending(token, messageType, events, multi);
        return (token, events);
    }

    /// <summary>Removes the request (if still ours) and ends its event stream.</summary>
    private void Complete(Key key, ulong token)
    {
        if (!_pending.TryGetValue(key, out var p) || p.Token != token)
        {
            return;
        }
        p.Timer?.Cancel();
        p.Events.Finish();
        _pending.Remove(key);
    }

    private void Arm(Key key, ulong token, TimeSpan duration)
    {
        if (!_pending.TryGetValue(key, out var p) || p.Token != token)
        {
            return;
        }
        p.Timer?.Cancel();
        var timer = new CancellationTokenSource();
        p.Timer = timer;
        _ = TimerAsync(p, timer, duration);
    }

    private async Task TimerAsync(Pending p, CancellationTokenSource timer, TimeSpan duration)
    {
        try
        {
            await _clock.SleepAsync(duration, timer.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        if (p.Timer == timer && _pending.ContainsValue(p))
        {
            p.Events.Yield(new Event.TimedOut());
        }
    }

    // Writing

    private async Task WriteAsync(byte[] bytes)
    {
        await _writeLock.WaitAsync();
        try
        {
            var chunk = Math.Max(_connection.Mtu - 3, 20);
            for (var offset = 0; offset < bytes.Length; offset += chunk)
            {
                var length = Math.Min(chunk, bytes.Length - offset);
                await _connection.WriteAsync(GattUuid.UartRx, bytes.AsSpan(offset, length).ToArray(), withResponse: true);
            }
        }
        finally
        {
            _writeLock.Release();
        }
    }

    // Receiving

    private void Handle(byte[] bytes)
    {
        foreach (var output in _framer.Push(bytes))
        {
            switch (output)
            {
                case UartFramerOutput.ErrorOutput:
                    _stats = _stats with { FramingErrors = _stats.FramingErrors + 1 };
                    break;
                case UartFramerOutput.FrameOutput { Frame: var frame }:
                    Route(frame);
                    break;
            }
        }
    }

    private void Route(UartFrame frame)
    {
        if (frame.Direction == UartDirection.Request)
        {
            _unsolicited.Send(frame);
            return;
        }
        if (Variant == UartVariant.Node && frame.ResponseId is { } responseId && !RememberResponseId(responseId))
        {
            _stats = _stats with { DuplicateResponses = _stats.DuplicateResponses + 1 };
            return;
        }
        var key = Variant == UartVariant.Node ? new Key(true, frame.RequestId ?? 0) : new Key(false, frame.MessageType);
        if (!_pending.TryGetValue(key, out var p) || p.MessageType != frame.MessageType)
        {
            _stats = _stats with { IgnoredFrames = _stats.IgnoredFrames + 1 };
            return;
        }
        try
        {
            var response = CombustionCodec.DecodeResponse(frame);
            p.Events.Yield(new Event.Response(response));
            if (!p.Multi)
            {
                Complete(key, p.Token);
            }
        }
        catch (CodecException e)
        {
            _stats = _stats with { CodecErrors = _stats.CodecErrors + 1 };
            p.Events.Yield(new Event.Error(new UartException(UartErrorKind.Codec, e.Error)));
            Complete(key, p.Token);
        }
    }

    /// <summary>Returns false if the ID was already seen.</summary>
    private bool RememberResponseId(uint id)
    {
        if (!_seenResponseIds.Add(id))
        {
            return false;
        }
        _seenResponseOrder.Enqueue(id);
        if (_seenResponseOrder.Count > SeenResponseLimit)
        {
            _seenResponseIds.Remove(_seenResponseOrder.Dequeue());
        }
        return true;
    }
}
