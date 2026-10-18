namespace Combustion.Sim;

/// <summary>
/// Decorator that writes every event crossing the transport to a <see cref="ReplayWriter"/> (docs/02 §16).
/// Events are recorded before they are handed to the consumer, so once a consumer has seen an event it is already in
/// the file.
/// <para>
/// It consumes the inner <c>State()</c> and <c>Advertisements()</c> streams itself (from the constructor) and
/// re-broadcasts them. Call <see cref="Stop"/> to end recording and close the file.
/// </para>
/// </summary>
public sealed class RecordingTransport : IBleTransport
{
    private readonly IBleTransport _inner;
    private readonly Recorder _recorder;
    private readonly Broadcaster<BluetoothState> _stateBroadcast = new(replayLatest: true);
    private readonly Broadcaster<RawAdvertisement> _advBroadcast = new();
    private readonly CancellationTokenSource _cts = new();

    public RecordingTransport(IBleTransport inner, ReplayWriter writer, IClock clock)
    {
        _inner = inner;
        _recorder = new Recorder(writer, clock);
        _ = PumpState(inner.State(), _cts.Token);
        _ = PumpAdvertisements(inner.Advertisements(), _cts.Token);
    }

    private async Task PumpState(AsyncStream<BluetoothState> source, CancellationToken ct)
    {
        try
        {
            await foreach (var s in source.WithCancellation(ct))
            {
                _recorder.Record(ReplayEvent.Kind.State, state: s.RawValue());
                _stateBroadcast.Send(s);
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        _stateBroadcast.Finish();
    }

    private async Task PumpAdvertisements(AsyncStream<RawAdvertisement> source, CancellationToken ct)
    {
        try
        {
            await foreach (var a in source.WithCancellation(ct))
            {
                _recorder.Record(ReplayEvent.Kind.Adv, peripheral: a.Peripheral, hex: HexString.Encode(a.MfrData), rssi: a.Rssi);
                _advBroadcast.Send(a);
            }
        }
        catch (OperationCanceledException)
        {
            return;
        }
        _advBroadcast.Finish();
    }

    public AsyncStream<BluetoothState> State() => _stateBroadcast.Stream();

    public AsyncStream<RawAdvertisement> Advertisements() => _advBroadcast.Stream();

    public Task StartScanAsync() => _inner.StartScanAsync();

    public Task StopScanAsync() => _inner.StopScanAsync();

    public async Task<IGattConnection> ConnectAsync(PeripheralId id, TimeSpan timeout, CancellationToken ct = default)
    {
        var c = await _inner.ConnectAsync(id, timeout, ct);
        _recorder.Record(ReplayEvent.Kind.Connect, peripheral: id);
        return new RecordingConnection(c, _recorder);
    }

    public void Stop()
    {
        _cts.Cancel();
        _recorder.Writer.Close();
    }
}

internal sealed class Recorder
{
    private readonly IClock _clock;
    private readonly TimeSpan _origin;

    public Recorder(ReplayWriter writer, IClock clock)
    {
        Writer = writer;
        _clock = clock;
        _origin = clock.Monotonic();
    }

    public ReplayWriter Writer { get; }

    public void Record(ReplayEvent.Kind type, PeripheralId? peripheral = null, GattUuid? characteristic = null,
        string? hex = null, int? rssi = null, string? state = null)
    {
        Writer.Append(new ReplayEvent((_clock.Monotonic() - _origin).TotalSeconds, type,
            peripheral?.Raw, characteristic?.Raw, hex, rssi, state));
    }
}

internal sealed class RecordingConnection : IGattConnection
{
    private readonly IGattConnection _inner;
    private readonly Recorder _recorder;
    private readonly Broadcaster<DisconnectReason> _disconnectOut = new(replayLatest: true);
    private bool _recordedDisconnect;

    public RecordingConnection(IGattConnection inner, Recorder recorder)
    {
        _inner = inner;
        _recorder = recorder;
        _ = PumpDisconnect(inner.Disconnected(), inner.Peripheral);
    }

    public PeripheralId Peripheral => _inner.Peripheral;

    public int Mtu => _inner.Mtu;

    public AsyncStream<DisconnectReason> Disconnected() => _disconnectOut.Stream();

    private async Task PumpDisconnect(AsyncStream<DisconnectReason> source, PeripheralId id)
    {
        await foreach (var reason in source)
        {
            RecordDisconnectOnce(id);
            _disconnectOut.Send(reason);
        }
        _disconnectOut.Finish();
    }

    private void RecordDisconnectOnce(PeripheralId id)
    {
        var first = !_recordedDisconnect;
        _recordedDisconnect = true;
        if (first)
        {
            _recorder.Record(ReplayEvent.Kind.Disconnect, peripheral: id);
        }
    }

    public Task<IReadOnlyList<GattService>> DiscoverAsync(CancellationToken ct = default) => _inner.DiscoverAsync(ct);

    public Task<byte[]> ReadAsync(GattUuid characteristic, CancellationToken ct = default) => _inner.ReadAsync(characteristic, ct);

    public Task WriteAsync(GattUuid characteristic, byte[] bytes, bool withResponse, CancellationToken ct = default)
    {
        _recorder.Record(ReplayEvent.Kind.Write, peripheral: Peripheral, characteristic: characteristic, hex: HexString.Encode(bytes));
        return _inner.WriteAsync(characteristic, bytes, withResponse, ct);
    }

    public async Task<AsyncStream<byte[]>> SubscribeAsync(GattUuid characteristic, CancellationToken ct = default)
    {
        var source = await _inner.SubscribeAsync(characteristic, ct);
        var stream = new AsyncStream<byte[]>();
        var cts = new CancellationTokenSource();
        _ = PumpNotifications(source, stream, characteristic, cts.Token);
        stream.OnTermination = cts.Cancel;
        return stream;
    }

    private async Task PumpNotifications(AsyncStream<byte[]> source, AsyncStream<byte[]> output, GattUuid characteristic, CancellationToken ct)
    {
        var id = Peripheral;
        try
        {
            await foreach (var bytes in source.WithCancellation(ct))
            {
                _recorder.Record(ReplayEvent.Kind.Notify, peripheral: id, characteristic: characteristic, hex: HexString.Encode(bytes));
                output.Yield(bytes);
            }
        }
        catch (OperationCanceledException)
        {
        }
        output.Finish();
    }

    public async Task CloseAsync()
    {
        await _inner.CloseAsync();
        RecordDisconnectOnce(Peripheral);
    }
}
