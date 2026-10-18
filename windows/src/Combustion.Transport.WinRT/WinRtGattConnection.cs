using System.Runtime.InteropServices.WindowsRuntime;
using Combustion.Core;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Foundation;

namespace Combustion.Transport.WinRT;

/// <summary>
/// <see cref="IGattConnection"/> over a connected <see cref="BluetoothLEDevice"/> with a <see cref="GattSession"/>
/// that keeps the link open. Port of the Swift <c>CoreBluetoothGattConnection</c>.
/// </summary>
/// <remarks>
/// <para>Concurrency: WinRT events (connection status, MTU, notifications) arrive on thread-pool threads and touch only
/// this object's fields under <c>_lock</c> and thread-safe outputs (<see cref="AsyncStream{T}"/>,
/// <see cref="Broadcaster{T}"/>). Public async methods await WinRT operations without <c>ConfigureAwait(false)</c>.</para>
/// <para>Serialization: discover, read, write-with-response and subscribe run one at a time in FIFO order
/// (<see cref="SemaphoreSlim"/> serves async waiters in order), as in the Swift gate. Write-without-response does not take
/// the gate. <see cref="DiscoverAsync"/> must complete before the other calls (characteristics are looked up by UUID from
/// its result). Operations have no timeout of their own (callers such as UartClient time out); all of them fail with
/// <c>disconnected</c> when the link goes down, including ones waiting for the gate.</para>
/// <para>Differences from CoreBluetooth: a read does not also feed the subscriber of that characteristic (WinRT reports
/// reads and notifications separately, so nothing is lost); <see cref="Mtu"/> follows
/// <see cref="GattSession.MaxPduSizeChanged"/> instead of being fixed at connect; a link drop is never reported as
/// <see cref="DisconnectReason.Timeout"/> (WinRT gives no reason), only requested, bluetoothOff or linkLost.</para>
/// </remarks>
public sealed class WinRtGattConnection : IGattConnection
{
    private readonly BluetoothLEDevice _device;
    private readonly GattSession _session;
    private readonly WinRtBleTransport _transport;
    private readonly Broadcaster<DisconnectReason> _disconnectBroadcast = new(replayLatest: true);
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly CancellationTokenSource _linkDown = new();
    private readonly object _lock = new();
    private int _mtu;

    private sealed class Subscription
    {
        public Subscription(GattCharacteristic characteristic, AsyncStream<byte[]> stream)
        {
            Characteristic = characteristic;
            Stream = stream;
            Handler = (_, args) =>
            {
                try
                {
                    stream.Yield(args.CharacteristicValue.ToArray());
                }
                catch (Exception)
                {
                    // A notification racing teardown must not crash the thread pool.
                }
            };
        }

        public GattCharacteristic Characteristic { get; }

        public AsyncStream<byte[]> Stream { get; }

        public TypedEventHandler<GattCharacteristic, GattValueChangedEventArgs> Handler { get; }
    }

    // Everything below: guarded by _lock.
    private bool _terminated;
    private readonly Dictionary<GattUuid, GattCharacteristic> _characteristics = [];
    private readonly List<GattDeviceService> _services = [];
    private readonly Dictionary<GattUuid, Subscription> _subscriptions = [];

    internal WinRtGattConnection(PeripheralId id, BluetoothLEDevice device, GattSession session, WinRtBleTransport transport)
    {
        Peripheral = id;
        _device = device;
        _session = session;
        _transport = transport;
        _mtu = session.MaxPduSize;
        _device.ConnectionStatusChanged += OnConnectionStatusChanged;
        _session.MaxPduSizeChanged += OnMaxPduSizeChanged;
    }

    /// <inheritdoc />
    public PeripheralId Peripheral { get; }

    /// <summary>ATT MTU (<see cref="GattSession.MaxPduSize"/>; 23 until the MTU exchange completes). The usable write
    /// payload is <c>Mtu - 3</c>, as with the CoreBluetooth transport's <c>maximumWriteValueLength + 3</c>.</summary>
    public int Mtu => Volatile.Read(ref _mtu);

    /// <inheritdoc />
    public AsyncStream<DisconnectReason> Disconnected() => _disconnectBroadcast.Stream();

    /// <inheritdoc />
    public Task<IReadOnlyList<GattService>> DiscoverAsync(CancellationToken ct = default) =>
        RunAsync(gated: true, "service discovery", async token =>
        {
            var result = await _device.GetGattServicesAsync(BluetoothCacheMode.Uncached).AsTask(token);
            if (result.Status != GattCommunicationStatus.Success)
            {
                throw Failure("service discovery", result.Status, result.ProtocolError);
            }
            var services = new List<GattService>();
            var found = new Dictionary<GattUuid, GattCharacteristic>();
            string? firstError = null;
            foreach (var service in result.Services)
            {
                lock (_lock)
                {
                    _services.Add(service);
                }
                var chars = await service.GetCharacteristicsAsync(BluetoothCacheMode.Uncached).AsTask(token);
                var uuids = new List<GattUuid>();
                if (chars.Status == GattCommunicationStatus.Success)
                {
                    foreach (var ch in chars.Characteristics)
                    {
                        var uuid = GattUuid.FromGuid(ch.Uuid);
                        found[uuid] = ch;
                        uuids.Add(uuid);
                    }
                }
                else
                {
                    firstError ??= Describe(chars.Status, chars.ProtocolError);
                }
                services.Add(new GattService(GattUuid.FromGuid(service.Uuid), uuids));
            }
            lock (_lock)
            {
                foreach (var (uuid, ch) in found)
                {
                    _characteristics[uuid] = ch;
                }
            }
            if (firstError is not null)
            {
                throw TransportException.OperationFailed($"characteristic discovery: {firstError}");
            }
            return (IReadOnlyList<GattService>)services;
        }, ct);

    /// <inheritdoc />
    public Task<byte[]> ReadAsync(GattUuid characteristic, CancellationToken ct = default) =>
        RunAsync(gated: true, $"read {characteristic}", async token =>
        {
            var ch = Lookup(characteristic);
            var result = await ch.ReadValueAsync(BluetoothCacheMode.Uncached).AsTask(token);
            if (result.Status != GattCommunicationStatus.Success)
            {
                throw Failure($"read {characteristic}", result.Status, result.ProtocolError);
            }
            return result.Value is { } value ? value.ToArray() : [];
        }, ct);

    /// <inheritdoc />
    public Task WriteAsync(GattUuid characteristic, byte[] bytes, bool withResponse, CancellationToken ct = default) =>
        RunAsync(gated: withResponse, $"write {characteristic}", async token =>
        {
            var ch = Lookup(characteristic);
            if (!withResponse && !ch.CharacteristicProperties.HasFlag(GattCharacteristicProperties.WriteWithoutResponse))
            {
                throw TransportException.OperationFailed($"{characteristic} does not support write without response");
            }
            var option = withResponse ? GattWriteOption.WriteWithResponse : GattWriteOption.WriteWithoutResponse;
            var result = await ch.WriteValueWithResultAsync(bytes.AsBuffer(), option).AsTask(token);
            if (result.Status != GattCommunicationStatus.Success)
            {
                throw Failure($"write {characteristic}", result.Status, result.ProtocolError);
            }
            return true;
        }, ct);

    /// <inheritdoc />
    public Task<AsyncStream<byte[]>> SubscribeAsync(GattUuid characteristic, CancellationToken ct = default) =>
        RunAsync(gated: true, $"subscribe {characteristic}", async token =>
        {
            var ch = Lookup(characteristic);
            var stream = new AsyncStream<byte[]>();
            var subscription = new Subscription(ch, stream);
            Subscription? previous;
            lock (_lock)
            {
                if (_terminated)
                {
                    throw TransportException.Disconnected();
                }
                // Register before enabling so the first notification is not missed. A previous subscriber (if any) is
                // finished; it is no longer the registered one, so its termination does not disable notifications.
                _subscriptions.TryGetValue(characteristic, out previous);
                _subscriptions[characteristic] = subscription;
            }
            if (previous is not null)
            {
                previous.Characteristic.ValueChanged -= previous.Handler;
                previous.Stream.Finish();
            }
            ch.ValueChanged += subscription.Handler;
            stream.OnTermination = () => OnSubscriberGone(characteristic, subscription);
            try
            {
                var cccd = ch.CharacteristicProperties.HasFlag(GattCharacteristicProperties.Notify)
                    ? GattClientCharacteristicConfigurationDescriptorValue.Notify
                    : GattClientCharacteristicConfigurationDescriptorValue.Indicate;
                var result = await ch.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(cccd).AsTask(token);
                if (result.Status != GattCommunicationStatus.Success)
                {
                    throw Failure($"subscribe {characteristic}", result.Status, result.ProtocolError);
                }
            }
            catch (Exception)
            {
                lock (_lock)
                {
                    if (_subscriptions.TryGetValue(characteristic, out var s) && ReferenceEquals(s, subscription))
                    {
                        _subscriptions.Remove(characteristic);
                    }
                }
                ch.ValueChanged -= subscription.Handler;
                stream.Finish();
                throw;
            }
            return stream;
        }, ct);

    /// <inheritdoc />
    public Task CloseAsync()
    {
        Terminate(DisconnectReason.Requested);
        return Task.CompletedTask;
    }

    // MARK: Called by WinRtBleTransport

    /// <summary>
    /// Ends the connection (idempotent, any thread): fails pending and queued operations with <c>disconnected</c>,
    /// finishes subscriptions, publishes <paramref name="reason"/> and releases the WinRT objects, which is what makes
    /// Windows drop the link (there is no explicit disconnect call).
    /// </summary>
    internal void Terminate(DisconnectReason reason)
    {
        Subscription[] subs;
        GattDeviceService[] services;
        lock (_lock)
        {
            if (_terminated)
            {
                return;
            }
            _terminated = true;
            subs = [.. _subscriptions.Values];
            _subscriptions.Clear();
            services = [.. _services];
            _services.Clear();
            _characteristics.Clear();
        }
        _linkDown.Cancel();
        foreach (var s in subs)
        {
            try
            {
                s.Characteristic.ValueChanged -= s.Handler;
            }
            catch (Exception)
            {
            }
            s.Stream.Finish();
        }
        _disconnectBroadcast.Send(reason);
        _disconnectBroadcast.Finish();
        _transport.ConnectionTerminated(this);
        Release(services);
    }

    /// <summary>The connect attempt this was built for lost its race (timeout or cancel): drop the link silently.</summary>
    internal void ReleaseUnused()
    {
        lock (_lock)
        {
            _terminated = true;
        }
        _linkDown.Cancel();
        _disconnectBroadcast.Finish();
        Release([]);
    }

    /// <summary>Covers a drop between the link coming up and the status handler being registered.</summary>
    internal void CheckStillConnected()
    {
        try
        {
            if (_device.ConnectionStatus == BluetoothConnectionStatus.Disconnected &&
                _session.SessionStatus != GattSessionStatus.Active)
            {
                Terminate(LinkDownReason());
            }
        }
        catch (Exception)
        {
        }
    }

    // MARK: Helpers

    private async Task<T> RunAsync<T>(bool gated, string what, Func<CancellationToken, Task<T>> body, CancellationToken ct)
    {
        ThrowIfTerminated();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(ct, _linkDown.Token);
        var token = linked.Token;
        var holding = false;
        try
        {
            if (gated)
            {
                await _gate.WaitAsync(token);
                holding = true;
            }
            ThrowIfTerminated();
            return await body(token);
        }
        catch (OperationCanceledException) when (_linkDown.IsCancellationRequested && !ct.IsCancellationRequested)
        {
            throw TransportException.Disconnected();
        }
        catch (Exception e) when (e is not TransportException and not OperationCanceledException)
        {
            // WinRT throws (COMException, ObjectDisposedException) when the device goes away mid-operation.
            throw IsTerminated() ? TransportException.Disconnected() : TransportException.OperationFailed($"{what}: {e.Message}");
        }
        finally
        {
            if (holding)
            {
                _gate.Release();
            }
        }
    }

    private GattCharacteristic Lookup(GattUuid characteristic)
    {
        lock (_lock)
        {
            if (_terminated)
            {
                throw TransportException.Disconnected();
            }
            return _characteristics.TryGetValue(characteristic, out var ch)
                ? ch
                : throw TransportException.CharacteristicNotFound(characteristic);
        }
    }

    private bool IsTerminated()
    {
        lock (_lock)
        {
            return _terminated;
        }
    }

    private void ThrowIfTerminated()
    {
        if (IsTerminated())
        {
            throw TransportException.Disconnected();
        }
    }

    private TransportException Failure(string what, GattCommunicationStatus status, byte? protocolError) =>
        status == GattCommunicationStatus.Unreachable && IsTerminated()
            ? TransportException.Disconnected()
            : TransportException.OperationFailed($"{what}: {Describe(status, protocolError)}");

    private static string Describe(GattCommunicationStatus status, byte? protocolError) =>
        status == GattCommunicationStatus.ProtocolError && protocolError is { } code
            ? $"ProtocolError 0x{code:X2}"
            : status.ToString();

    /// <summary>Consumer stopped iterating: turn notifications off unless already disconnected or replaced.</summary>
    private void OnSubscriberGone(GattUuid characteristic, Subscription subscription)
    {
        lock (_lock)
        {
            if (_terminated || !_subscriptions.TryGetValue(characteristic, out var s) || !ReferenceEquals(s, subscription))
            {
                return;
            }
            _subscriptions.Remove(characteristic);
        }
        subscription.Characteristic.ValueChanged -= subscription.Handler;
        _ = DisableNotificationsAsync(subscription.Characteristic);
    }

    private static async Task DisableNotificationsAsync(GattCharacteristic ch)
    {
        try
        {
            await ch.WriteClientCharacteristicConfigurationDescriptorWithResultAsync(
                GattClientCharacteristicConfigurationDescriptorValue.None);
        }
        catch (Exception)
        {
            // Best effort, as CoreBluetooth's setNotifyValue(false).
        }
    }

    private DisconnectReason LinkDownReason() =>
        _transport.IsRadioOn() ? DisconnectReason.LinkLost : DisconnectReason.BluetoothOff;

    private void OnConnectionStatusChanged(BluetoothLEDevice sender, object args)
    {
        BluetoothConnectionStatus status;
        try
        {
            status = sender.ConnectionStatus;
        }
        catch (Exception)
        {
            status = BluetoothConnectionStatus.Disconnected;
        }
        if (status == BluetoothConnectionStatus.Disconnected)
        {
            // CloseAsync terminates first (reason requested), so a live connection here is a remote or link drop.
            // Terminating (rather than letting MaintainConnection reconnect) matches CoreBluetooth: the link layer
            // owns reconnects.
            Terminate(LinkDownReason());
        }
    }

    private void OnMaxPduSizeChanged(GattSession sender, object args)
    {
        try
        {
            Volatile.Write(ref _mtu, sender.MaxPduSize);
        }
        catch (Exception)
        {
        }
    }

    private void Release(GattDeviceService[] services)
    {
        try
        {
            _device.ConnectionStatusChanged -= OnConnectionStatusChanged;
            _session.MaxPduSizeChanged -= OnMaxPduSizeChanged;
            _session.MaintainConnection = false;
        }
        catch (Exception)
        {
        }
        foreach (var s in services)
        {
            try
            {
                s.Dispose();
            }
            catch (Exception)
            {
            }
        }
        try
        {
            _session.Dispose();
            _device.Dispose();
        }
        catch (Exception)
        {
        }
    }
}
