using System.Runtime.InteropServices.WindowsRuntime;
using Combustion.Core;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Devices.Radios;
using Windows.Foundation;

namespace Combustion.Transport.WinRT;

/// <summary>
/// Windows <see cref="IBleTransport"/> on WinRT Bluetooth LE (docs/02 §5.1). Port of the Swift
/// <c>CoreBluetoothTransport</c>.
/// </summary>
/// <remarks>
/// <para>Concurrency (docs/02 §12): WinRT raises its events on thread-pool threads. Those handlers touch only this
/// class's own fields (under <c>_lock</c>) and thread-safe outputs (<see cref="Broadcaster{T}"/>,
/// <see cref="AsyncStream{T}"/>, <see cref="TaskCompletionSource{T}"/> created with
/// <see cref="TaskCreationOptions.RunContinuationsAsynchronously"/>). They never call into Core objects. Public async
/// methods await WinRT operations without <c>ConfigureAwait(false)</c>, so their continuations return to the caller's
/// context.</para>
/// <para>Semantics mirror <c>CoreBluetoothTransport</c> / <c>SimulatedTransport</c>:</para>
/// <list type="bullet">
/// <item>Advertisements are delivered only between <see cref="StartScanAsync"/> and <see cref="StopScanAsync"/>.</item>
/// <item>Leaving <see cref="BluetoothState.PoweredOn"/> stops scanning (NOT resumed automatically), drops every
/// connection with <see cref="DisconnectReason.BluetoothOff"/> and fails pending connects with
/// <c>notPoweredOn</c>.</item>
/// <item>A second connect to an already connected (or connecting) peripheral throws <c>alreadyConnected</c>.</item>
/// </list>
/// <para>Manufacturer data: <see cref="RawAdvertisement.MfrData"/> includes the 2-byte company ID (C7 09) in front,
/// as CoreBluetooth delivers it; WinRT reports the company ID separately, so it is re-assembled.</para>
/// <para>State mapping: <see cref="RadioState.On"/> is poweredOn; <see cref="RadioState.Off"/> and
/// <see cref="RadioState.Disabled"/> are poweredOff; <see cref="RadioState.Unknown"/> is not published (as CoreBluetooth's
/// <c>.unknown</c>), so <see cref="State"/> yields nothing until the system knows. No default adapter, no LE support or no
/// radio is unsupported. The watcher stopping with a consent or policy error publishes unauthorized; the next radio state
/// change replaces it.</para>
/// <para><see cref="PeripheralId"/> is the 48-bit Bluetooth address as 12 uppercase hex digits
/// (<see cref="WinRtFormat.FormatPeripheralId"/>).</para>
/// </remarks>
public sealed class WinRtBleTransport : IBleTransport, IDisposable
{
    private readonly IClock _clock;
    private readonly Broadcaster<BluetoothState> _stateBroadcast = new(replayLatest: true);
    private readonly Broadcaster<RawAdvertisement> _advBroadcast = new();
    private readonly Task _initialized;
    private readonly object _lock = new();

    // Everything below: guarded by _lock.
    private Radio? _radio;
    private BluetoothLEAdvertisementWatcher? _watcher;
    private BluetoothState? _lastState;
    private bool _scanning;
    private bool _disposed;
    private readonly Dictionary<PeripheralId, BluetoothAddressType> _addressTypes = [];
    private readonly Dictionary<PeripheralId, ConnectAttempt> _pending = [];
    private readonly Dictionary<PeripheralId, WinRtGattConnection> _connections = [];

    public WinRtBleTransport(IClock clock)
    {
        _clock = clock;
        _initialized = InitializeAsync();
    }

    // MARK: IBleTransport

    /// <inheritdoc />
    public AsyncStream<BluetoothState> State() => _stateBroadcast.Stream();

    /// <inheritdoc />
    public AsyncStream<RawAdvertisement> Advertisements() => _advBroadcast.Stream();

    /// <inheritdoc />
    public async Task StartScanAsync()
    {
        await _initialized;
        lock (_lock)
        {
            if (_disposed || _scanning || _lastState != BluetoothState.PoweredOn || _watcher is null)
            {
                return;
            }
            try
            {
                _watcher.Start();
                _scanning = true;
            }
            catch (Exception)
            {
                // Start throws while the watcher is still stopping or the radio just went away; the next state
                // change (or the caller's retry) recovers. CoreBluetooth's scanForPeripherals cannot fail either.
                _scanning = false;
            }
        }
    }

    /// <inheritdoc />
    public async Task StopScanAsync()
    {
        await _initialized;
        lock (_lock)
        {
            StopWatcherLocked();
        }
    }

    /// <inheritdoc />
    public async Task<IGattConnection> ConnectAsync(PeripheralId id, TimeSpan timeout, CancellationToken ct = default)
    {
        await _initialized;
        ct.ThrowIfCancellationRequested();
        ConnectAttempt attempt;
        BluetoothAddressType? addressType;
        lock (_lock)
        {
            if (_lastState != BluetoothState.PoweredOn || _disposed)
            {
                throw TransportException.NotPoweredOn(_lastState ?? BluetoothState.PoweredOff);
            }
            if (_connections.ContainsKey(id) || _pending.ContainsKey(id))
            {
                throw TransportException.AlreadyConnected(id);
            }
            if (!WinRtFormat.TryParsePeripheralId(id, out var address))
            {
                throw TransportException.ConnectionRefused(id);
            }
            addressType = _addressTypes.TryGetValue(id, out var t) ? t : null;
            attempt = new ConnectAttempt(id, address);
            _pending[id] = attempt;
        }

        // The timeout, the caller's cancellation and the link coming up race; whichever resolves the attempt first
        // wins (the losers find no matching pending entry and do nothing).
        _ = TimeoutAsync(attempt, timeout);
        using var registration = ct.Register(() => FailPending(attempt, new OperationCanceledException(ct)));
        _ = RunConnectAsync(attempt, addressType);
        return await attempt.Result.Task;
    }

    /// <summary>Stops scanning and closes every connection (app shutdown).</summary>
    public void Dispose()
    {
        WinRtGattConnection[] open;
        ConnectAttempt[] failed;
        lock (_lock)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            StopWatcherLocked();
            if (_watcher is not null)
            {
                _watcher.Received -= OnAdvertisementReceived;
                _watcher.Stopped -= OnWatcherStopped;
            }
            if (_radio is not null)
            {
                _radio.StateChanged -= OnRadioStateChanged;
            }
            open = [.. _connections.Values];
            failed = [.. _pending.Values];
            _connections.Clear();
            _pending.Clear();
        }
        foreach (var p in failed)
        {
            p.Fail(TransportException.NotPoweredOn(BluetoothState.PoweredOff));
        }
        foreach (var c in open)
        {
            c.Terminate(DisconnectReason.Requested);
        }
        _advBroadcast.Finish();
        _stateBroadcast.Finish();
    }

    // MARK: Called by WinRtGattConnection

    /// <summary>True while the radio reports On; read live because a connection's status callback can race the radio's.</summary>
    internal bool IsRadioOn()
    {
        Radio? radio;
        lock (_lock)
        {
            radio = _radio;
        }
        try
        {
            return radio is not null && radio.State == RadioState.On;
        }
        catch (Exception)
        {
            return false;
        }
    }

    internal void ConnectionTerminated(WinRtGattConnection connection)
    {
        lock (_lock)
        {
            if (_connections.TryGetValue(connection.Peripheral, out var c) && ReferenceEquals(c, connection))
            {
                _connections.Remove(connection.Peripheral);
            }
        }
    }

    // MARK: Initialization and state

    private async Task InitializeAsync()
    {
        try
        {
            var adapter = await BluetoothAdapter.GetDefaultAsync();
            if (adapter is null || !adapter.IsLowEnergySupported || !adapter.IsCentralRoleSupported)
            {
                PublishState(BluetoothState.Unsupported);
                return;
            }
            var radio = await adapter.GetRadioAsync();
            if (radio is null)
            {
                PublishState(BluetoothState.Unsupported);
                return;
            }
            var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
            // Empty data with the company ID matches any manufacturer data section from that company.
            watcher.AdvertisementFilter.Advertisement.ManufacturerData.Add(
                new BluetoothLEManufacturerData { CompanyId = CombustionVendor.CompanyId });
            watcher.Received += OnAdvertisementReceived;
            watcher.Stopped += OnWatcherStopped;
            lock (_lock)
            {
                if (_disposed)
                {
                    return;
                }
                _radio = radio;
                _watcher = watcher;
            }
            radio.StateChanged += OnRadioStateChanged;
            ApplyRadioState(radio.State);
        }
        catch (Exception)
        {
            // No Bluetooth stack (Windows N without media pack, Server Core, a broken driver): GetDefaultAsync throws.
            PublishState(BluetoothState.Unsupported);
        }
    }

    private static BluetoothState? Map(RadioState s) => s switch
    {
        RadioState.On => BluetoothState.PoweredOn,
        RadioState.Off => BluetoothState.PoweredOff,
        RadioState.Disabled => BluetoothState.PoweredOff,
        _ => null,
    };

    private void OnRadioStateChanged(Radio sender, object args)
    {
        RadioState state;
        try
        {
            state = sender.State;
        }
        catch (Exception)
        {
            state = RadioState.Off;
        }
        ApplyRadioState(state);
    }

    /// <summary>Port of <c>centralManagerDidUpdateState</c>. Any thread.</summary>
    private void ApplyRadioState(RadioState state)
    {
        var mapped = Map(state);
        WinRtGattConnection[] dropped = [];
        ConnectAttempt[] failed = [];
        lock (_lock)
        {
            if (_disposed)
            {
                return;
            }
            if (state != RadioState.On)
            {
                StopWatcherLocked();
                dropped = [.. _connections.Values];
                _connections.Clear();
                failed = [.. _pending.Values];
                _pending.Clear();
            }
        }
        foreach (var p in failed)
        {
            p.Fail(TransportException.NotPoweredOn(mapped ?? BluetoothState.PoweredOff));
        }
        foreach (var c in dropped)
        {
            c.Terminate(DisconnectReason.BluetoothOff);
        }
        if (mapped is { } s)
        {
            PublishState(s);
        }
    }

    private void PublishState(BluetoothState state)
    {
        lock (_lock)
        {
            if (_disposed || _lastState == state)
            {
                return;
            }
            _lastState = state;
            // Sent under the lock so two racing callbacks cannot publish out of order; Broadcaster.Send never blocks.
            _stateBroadcast.Send(state);
        }
    }

    // MARK: Scanning

    private void StopWatcherLocked()
    {
        if (!_scanning)
        {
            return;
        }
        _scanning = false;
        try
        {
            _watcher?.Stop();
        }
        catch (Exception)
        {
            // Already stopped by the system (radio off).
        }
    }

    private void OnAdvertisementReceived(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementReceivedEventArgs args)
    {
        try
        {
            int rssi = args.RawSignalStrengthInDBm;
            if (!WinRtFormat.IsRssiAvailable(rssi))
            {
                return;
            }
            var sections = args.Advertisement.GetManufacturerDataByCompanyId(CombustionVendor.CompanyId);
            if (sections.Count == 0)
            {
                // Active scanning also delivers scan responses; the filter normally drops those without our data.
                return;
            }
            var payload = sections[0].Data.ToArray();
            var id = WinRtFormat.FormatPeripheralId(args.BluetoothAddress);
            lock (_lock)
            {
                // Received can still fire just after Stop(); only deliver while scanning.
                if (!_scanning)
                {
                    return;
                }
                _addressTypes[id] = args.BluetoothAddressType;
            }
            var mfr = WinRtFormat.AssembleManufacturerData(CombustionVendor.CompanyId, payload);
            _advBroadcast.Send(new RawAdvertisement(id, mfr, rssi, _clock.Now()));
        }
        catch (Exception)
        {
            // A malformed or torn-down event must not crash the thread pool.
        }
    }

    private void OnWatcherStopped(BluetoothLEAdvertisementWatcher sender, BluetoothLEAdvertisementWatcherStoppedEventArgs args)
    {
        // Stopped also fires after our own Stop() (Error == Success); _scanning is already false then.
        lock (_lock)
        {
            _scanning = false;
        }
        if (args.Error is BluetoothError.ConsentRequired or BluetoothError.DisabledByUser or BluetoothError.DisabledByPolicy)
        {
            PublishState(BluetoothState.Unauthorized);
        }
    }

    // MARK: Connecting

    /// <summary>One connect call. Resolved exactly once, by success, timeout, cancellation, radio off or failure.</summary>
    private sealed class ConnectAttempt
    {
        public ConnectAttempt(PeripheralId id, ulong address)
        {
            Id = id;
            Address = address;
        }

        public PeripheralId Id { get; }

        public ulong Address { get; }

        /// <summary>Cancelled when the attempt is resolved: stops the timeout and any in-flight WinRT operation.</summary>
        public CancellationTokenSource Done { get; } = new();

        public TaskCompletionSource<IGattConnection> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Fail(Exception error)
        {
            Result.TrySetException(error);
            Done.Cancel();
        }
    }

    private async Task TimeoutAsync(ConnectAttempt attempt, TimeSpan timeout)
    {
        try
        {
            await _clock.SleepAsync(timeout, attempt.Done.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        FailPending(attempt, TransportException.Timeout());
    }

    /// <summary>Fails the pending connect if <paramref name="attempt"/> still owns it (which also aborts its WinRT work).</summary>
    private void FailPending(ConnectAttempt attempt, Exception error)
    {
        lock (_lock)
        {
            if (!_pending.TryGetValue(attempt.Id, out var p) || !ReferenceEquals(p, attempt))
            {
                return;
            }
            _pending.Remove(attempt.Id);
        }
        attempt.Fail(error);
    }

    private async Task RunConnectAsync(ConnectAttempt attempt, BluetoothAddressType? addressType)
    {
        var ct = attempt.Done.Token;
        BluetoothLEDevice? device = null;
        GattSession? session = null;
        try
        {
            // The two-argument overload works for devices the system has not cached yet; the address type is known
            // once the peripheral has been seen advertising.
            device = addressType is { } type
                ? await BluetoothLEDevice.FromBluetoothAddressAsync(attempt.Address, type).AsTask(ct)
                : await BluetoothLEDevice.FromBluetoothAddressAsync(attempt.Address).AsTask(ct);
            if (device is null)
            {
                FailPending(attempt, TransportException.ConnectionRefused(attempt.Id));
                return;
            }
            session = await GattSession.FromDeviceIdAsync(device.BluetoothDeviceId).AsTask(ct);
            if (session is null)
            {
                FailPending(attempt, TransportException.ConnectionRefused(attempt.Id));
                return;
            }
            await WaitForLinkAsync(device, session, ct);

            var connection = new WinRtGattConnection(attempt.Id, device, session, this);
            bool won;
            lock (_lock)
            {
                won = _pending.TryGetValue(attempt.Id, out var p) && ReferenceEquals(p, attempt);
                if (won)
                {
                    _pending.Remove(attempt.Id);
                    _connections[attempt.Id] = connection;
                }
            }
            if (!won)
            {
                // Connected after a timeout/cancel already gave up: undo it.
                connection.ReleaseUnused();
                return;
            }
            attempt.Result.TrySetResult(connection);
            attempt.Done.Cancel();
            // The link may have dropped between WaitForLinkAsync and the handler registration in the constructor.
            connection.CheckStillConnected();
        }
        catch (Exception e)
        {
            session?.Dispose();
            device?.Dispose();
            if (e is not OperationCanceledException || !ct.IsCancellationRequested)
            {
                FailPending(attempt, TransportException.ConnectionRefused(attempt.Id));
            }
        }
    }

    /// <summary>
    /// Port of waiting for <c>didConnect</c>: <see cref="GattSession.MaintainConnection"/> makes Windows open the link;
    /// it is up when the session turns Active or the device reports Connected.
    /// </summary>
    private static async Task WaitForLinkAsync(BluetoothLEDevice device, GattSession session, CancellationToken ct)
    {
        var up = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        TypedEventHandler<GattSession, GattSessionStatusChangedEventArgs> onSession = (_, a) =>
        {
            if (a.Status == GattSessionStatus.Active)
            {
                up.TrySetResult();
            }
        };
        TypedEventHandler<BluetoothLEDevice, object> onDevice = (d, _) =>
        {
            if (d.ConnectionStatus == BluetoothConnectionStatus.Connected)
            {
                up.TrySetResult();
            }
        };
        session.SessionStatusChanged += onSession;
        device.ConnectionStatusChanged += onDevice;
        try
        {
            session.MaintainConnection = true;
            if (session.SessionStatus == GattSessionStatus.Active || device.ConnectionStatus == BluetoothConnectionStatus.Connected)
            {
                up.TrySetResult();
            }
            await up.Task.WaitAsync(ct);
        }
        finally
        {
            session.SessionStatusChanged -= onSession;
            device.ConnectionStatusChanged -= onDevice;
        }
    }
}
