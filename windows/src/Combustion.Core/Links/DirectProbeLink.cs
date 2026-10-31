using Combustion.Codec;

namespace Combustion.Core;

/// <summary>
/// One probe connected directly over GATT (docs/02 §5.3).
/// Subscribes to Probe Status and publishes <c>ProbeObservation(Status)</c> with source <c>DirectConnection</c>,
/// and owns a probe-variant <see cref="UartClient"/> on the UART characteristics. The GATT status payload does not carry
/// the probe serial, so the caller supplies it (from the advertisement that led to the connection).
/// <para>
/// The 94 B status (fw v2.3.3 and older) has no session fields. On the first such status the link reads Session
/// Info over UART and fills it into every later status, so history can tell cooks apart (docs/07). Statuses before
/// the answer go out without it (<c>SessionTracker</c> adopts the id). If the log range goes backwards on the same
/// link, the cached info is dropped and read again. Firmware that refuses the read keeps sending none.
/// </para>
/// </summary>
public sealed class DirectProbeLink : ILogFetcher
{
    private readonly IGattConnection _connection;
    private readonly IClock _clock;
    private readonly Broadcaster<ProbeObservation> _observations = new();
    private readonly Broadcaster<DisconnectReason> _disconnect = new(replayLatest: true);
    private readonly CancellationTokenSource _tasks = new();
    private readonly SemaphoreSlim _readTurn = new(1, 1);
    private bool _started;
    private bool _finished;
    private SessionInfo? _sessionInfo;
    private bool _sessionReading;
    private bool _sessionReadRefused;
    private uint? _lastLogMax;

    public DirectProbeLink(ProbeSerial serial, IGattConnection connection, IClock clock)
    {
        Serial = serial;
        _connection = connection;
        _clock = clock;
        Uart = new UartClient(UartVariant.Probe, connection, clock);
    }

    public ProbeSerial Serial { get; }

    public UartClient Uart { get; }

    public AsyncStream<ProbeObservation> Observations() => _observations.Stream();

    /// <summary>Yields the reason once (late subscribers still get it), then finishes.</summary>
    public AsyncStream<DisconnectReason> Disconnected() => _disconnect.Stream();

    /// <summary>Probe Status notifications the codec rejected.</summary>
    public int StatusDecodeErrors { get; private set; }

    /// <summary>Discovers services, starts the UART client and subscribes to Probe Status.
    /// On failure the link is torn down and the error rethrown.</summary>
    public async Task StartAsync()
    {
        if (_started)
        {
            return;
        }
        _started = true;
        // Watch for disconnects first so nothing is missed while setting up.
        _ = WatchDisconnectAsync(_connection.Disconnected(), _tasks.Token);
        try
        {
            var services = await _connection.DiscoverAsync();
            var known = services.SelectMany(s => s.Characteristics).ToHashSet();
            foreach (var needed in new[] { GattUuid.ProbeStatus, GattUuid.UartRx, GattUuid.UartTx })
            {
                if (!known.Contains(needed))
                {
                    throw TransportException.CharacteristicNotFound(needed);
                }
            }
            await Uart.StartAsync();
            var status = await _connection.SubscribeAsync(GattUuid.ProbeStatus);
            _ = status.ForEachAsync(HandleStatus, _tasks.Token);
        }
        catch
        {
            // Tear down fully, including the connection: a half-started link must not hold a probe slot.
            await _connection.CloseAsync();
            Finish(DisconnectReason.Requested);
            throw;
        }
    }

    private async Task WatchDisconnectAsync(AsyncStream<DisconnectReason> drops, CancellationToken ct)
    {
        try
        {
            await foreach (var reason in drops.WithCancellation(ct))
            {
                Finish(reason);
                return;
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        Finish(DisconnectReason.LinkLost);
    }

    /// <summary>Closes the connection and ends all streams.</summary>
    public async Task CloseAsync()
    {
        await _connection.CloseAsync();
        Finish(DisconnectReason.Requested);
    }

    private void Finish(DisconnectReason reason)
    {
        if (_finished)
        {
            return;
        }
        _finished = true;
        _tasks.Cancel();
        Uart.Close();
        _observations.Finish();
        _disconnect.Send(reason);
        _disconnect.Finish();
    }

    private void HandleStatus(byte[] bytes)
    {
        if (_finished)
        {
            return;
        }
        ProbeStatusPayload payload;
        try
        {
            payload = CombustionCodec.DecodeProbeStatus(bytes);
        }
        catch (CodecException)
        {
            StatusDecodeErrors++;
            return;
        }
        if (payload.Session is null)
        {
            if (_lastLogMax is { } last && payload.LogRange.Max < last)
            {
                _sessionInfo = null;
                _sessionReadRefused = false;
            }
            if (_sessionInfo is null)
            {
                RequestSessionInfo();
            }
            payload = payload with { Session = _sessionInfo };
        }
        _lastLogMax = payload.LogRange.Max;
        var now = _clock.Now();
        var source = new LinkSource(LinkKind.DirectConnection, now, HighRadioPower: payload.Preferences?.HighRadioPower);
        _observations.Send(new ProbeObservation(Serial, source, new ObservationPayload.Status(payload), now));
    }

    private void RequestSessionInfo()
    {
        if (_sessionReading || _sessionReadRefused)
        {
            return;
        }
        _sessionReading = true;
        _ = ReadSessionInfoInBackgroundAsync();
    }

    private async Task ReadSessionInfoInBackgroundAsync()
    {
        // Swift starts this in a new Task: let the status that asked for it go out first.
        await Task.Yield();
        SessionInfo? info;
        try
        {
            info = await ReadSessionInfoAsync();
        }
        catch (Exception)
        {
            info = null;
        }
        _sessionReading = false;
        if (_finished)
        {
            return;
        }
        if (info is { } i)
        {
            _sessionInfo = i;
        }
        else
        {
            _sessionReadRefused = true;
        }
    }

    // UART

    /// <summary>Sends any request over the probe UART.</summary>
    public Task<UartResponse> SendAsync(UartRequest request, TimeSpan? timeout = null, int retries = 1) =>
        Uart.SendAsync(request, timeout: timeout, retries: retries);

    public async Task<SessionInfo> ReadSessionInfoAsync()
    {
        var response = await Uart.SendAsync(new UartRequest.ReadSessionInfo());
        return response.Body is ResponseBody.SessionInfoBody { Info: var info }
            ? info
            : throw new UartException(UartErrorKind.Codec, new CodecError.UnknownMessageType(response.MessageType));
    }

    /// <summary>
    /// <paramref name="probe"/> must be this link's probe; anything else fails with <c>Failure</c> (a mismatch would
    /// file another probe's history under the wrong serial).
    /// Reads are serialized per link: the probe UART allows one Read Logs in flight, and live fetches and
    /// backfill run concurrently, so a second caller waits for its turn instead of failing with <c>Busy</c>.
    /// </summary>
    public IAsyncEnumerable<LogRecord> ReadLogs(ProbeSerial probe, uint start, uint end)
    {
        var output = new AsyncStream<LogRecord>();
        if (probe != Serial)
        {
            output.Finish(UartException.Failure);
            return output;
        }
        var cts = new CancellationTokenSource();
        output.OnTermination = cts.Cancel;
        _ = PumpAsync(start, end, output, cts.Token);
        return output;
    }

    private async Task PumpAsync(uint start, uint end, AsyncStream<LogRecord> output, CancellationToken ct)
    {
        try
        {
            await _readTurn.WaitAsync(ct);
        }
        catch (OperationCanceledException e)
        {
            output.Finish(e);
            return;
        }
        try
        {
            await foreach (var r in Uart.ReadLogs(start, end, idleTimeout: TimeSpan.FromSeconds(2)).WithCancellation(ct))
            {
                output.Yield(r);
            }
            output.Finish();
        }
        catch (Exception e)
        {
            output.Finish(e);
        }
        finally
        {
            _readTurn.Release();
        }
    }
}
