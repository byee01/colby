# Combustion.Transport.WinRT

Windows `IBleTransport` / `IGattConnection` on WinRT Bluetooth LE (docs/02 §5.1). Port of
`mac/Sources/CombustionCoreBluetooth`. Targets `net10.0-windows10.0.19041.0` with `EnableWindowsTargeting`, so it
compiles on Linux. **Not yet run on Windows hardware.**

## Implemented

- `WinRtBleTransport`: adapter state from `BluetoothAdapter.GetDefaultAsync()` + `Radio.StateChanged` (current value
  first, deduplicated, `Unknown` not published); scanning with `BluetoothLEAdvertisementWatcher` (Active, manufacturer
  data filter on 0x09C7), advertisements only between start and stop scan; `MfrData` re-assembled with the company ID
  first (`C7 09 ...`); `PeripheralId` = 48-bit address as 12 uppercase hex digits; connect with timeout from `IClock`,
  cancellation, `alreadyConnected`, `notPoweredOn`; radio off stops the scan (not resumed), drops connections with
  `bluetoothOff` and fails pending connects.
- `WinRtGattConnection`: `GattSession` with `MaintainConnection = true`; discovery with `BluetoothCacheMode.Uncached`;
  read; write with and without response; CCCD notify (indicate if the characteristic has no notify) with `ValueChanged`;
  `Mtu` = `GattSession.MaxPduSize`, updated on `MaxPduSizeChanged`; `ConnectionStatusChanged` -> `requested` /
  `bluetoothOff` / `linkLost`; `GattCommunicationStatus` failures -> `TransportException.OperationFailed` (or
  `Disconnected` once the link is gone). Discover/read/write-with-response/subscribe are serialized FIFO as in Swift.
- `WinRtFormat`: pure helpers (address <-> `PeripheralId`, manufacturer data assembly). No WinRT types, but untested:
  no Linux test project can load a Windows-TFM assembly.

## Untested

Everything above on real hardware: connect latency, the "link up" signal, MTU exchange, notifications, radio toggling,
consent errors. No unit tests (WinRT cannot be faked without a seam; the Core suite covers the contract via
`SimulatedTransport`).

## Packaging

The MSIX manifest needs `<DeviceCapability Name="bluetooth" />`. Unpackaged desktop apps need no capability.

## WinRT pitfalls handled

- WinRT strips the company ID from manufacturer data; it is put back little-endian in front.
- `Received` can fire just after `Stop()`; advertisements are dropped unless scanning.
- `Stopped` fires for our own stop and for system stops (radio off, consent); the scan flag is cleared either way, and
  consent / policy errors publish `unauthorized`.
- `Start()` throws while the watcher is still stopping; caught (scan stays off).
- `FromBluetoothAddressAsync` returns null for unknown devices (-> `connectionRefused`); the address type seen in the
  advertisement is passed to the two-argument overload so uncached devices resolve.
- Windows has no explicit disconnect: closing sets `MaintainConnection = false` and disposes the session, services
  and device. Without that the OS keeps the link up.
- With `MaintainConnection = true` Windows would silently reconnect after a drop; the connection is terminated on the
  first `Disconnected` status instead, matching CoreBluetooth (reconnects belong to the link layer).
- The radio-off callback and the device status callback race; the disconnect reason reads the radio state live.
- A drop between "link up" and handler registration is caught by a status re-check after the connection is created.
- WinRT objects throw (`COMException`, `ObjectDisposedException`) when the device disappears mid-call; mapped to
  `disconnected` after termination, else `operationFailed`.
- All callbacks are wrapped so an exception cannot escape onto the thread pool.

## Known differences from the CoreBluetooth transport

- A read does not also feed the characteristic's subscriber (WinRT separates reads from notifications, so nothing is
  lost; Core only reads Device Information characteristics).
- `Mtu` is live (23 until the exchange completes) rather than fixed at connect.
- `DisconnectReason.Timeout` is never reported (WinRT gives no supervision-timeout reason; reported as `linkLost`).
- Write without response is not flow-controlled by a "ready to send" signal; each write awaits
  `WriteValueWithResultAsync`.
- `unauthorized` (watcher consent error) is cleared only by the next radio state change.
