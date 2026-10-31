// GATT identifiers (docs/01 §2). Lowercase, as Web Bluetooth expects.
export const GATT = {
  probeStatusService: '00000100-caab-3792-3d44-97ae51c1407a',
  probeStatus: '00000101-caab-3792-3d44-97ae51c1407a',
  uartService: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
  /** The app writes requests here. */
  uartRX: '6e400002-b5a3-f393-e0a9-e50e24dcca9e',
  /** Responses and node notifications arrive here. */
  uartTX: '6e400003-b5a3-f393-e0a9-e50e24dcca9e',
  /** 0x180A on every product (the node doc says 0x181A, but the Android SDK reads 0x180A from all devices). */
  deviceInformation: '0000180a-0000-1000-8000-00805f9b34fb',
  modelNumber: '00002a24-0000-1000-8000-00805f9b34fb',
  serialNumber: '00002a25-0000-1000-8000-00805f9b34fb',
  firmwareRevision: '00002a26-0000-1000-8000-00805f9b34fb',
  hardwareRevision: '00002a27-0000-1000-8000-00805f9b34fb',
};

/**
 * A GATT connection as the core sees it (implemented by transport/webBluetooth.js and transport/simulated.js):
 *
 * - `id`, `name`, `mtu`
 * - `discover()` → Set of characteristic UUIDs present
 * - `read(uuid)` → bytes
 * - `write(uuid, bytes)` (with response)
 * - `subscribe(uuid, onBytes)` → unsubscribe function
 * - `onDisconnect(fn)` → unsubscribe; `fn(reason)` is called once ('requested' | 'linkLost')
 * - `close()`
 */
