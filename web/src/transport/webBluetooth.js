// Web Bluetooth transport (Chromium: Chrome, Edge, Opera on Windows, macOS, ChromeOS, Android).
//
// Shipped APIs: requestDevice (chooser, needs a user gesture), GATT connect/read/write/notify.
// Behind chrome://flags/#enable-experimental-web-platform-features (used when present, never required):
//   getDevices()            reconnect to devices picked earlier, after a reload
//   watchAdvertisements()   RSSI and the probe serial from manufacturer data
//   requestLEScan()         passive advertisement scanning (live temps without a connection)

import { GATT } from './gatt.js';
import { VENDOR_ID, decodeAdvertisement } from '../codec/index.js';

const bt = () => globalThis.navigator?.bluetooth;

export const capabilities = () => ({
  bluetooth: !!bt(),
  secureContext: !!globalThis.isSecureContext,
  getDevices: typeof bt()?.getDevices === 'function',
  watchAdvertisements: typeof globalThis.BluetoothDevice?.prototype?.watchAdvertisements === 'function',
  scan: typeof bt()?.requestLEScan === 'function',
});

export async function isAvailable() {
  if (!bt()) return false;
  try {
    return (await bt().getAvailability?.()) ?? true;
  } catch {
    return true;
  }
}

const SERVICES = [GATT.probeStatusService, GATT.uartService, GATT.deviceInformation, GATT.deviceInformationAlt];

/** Opens the browser's device chooser filtered to Combustion devices. Must run in a user gesture. */
export function requestDevice() {
  return bt().requestDevice({
    filters: [{ manufacturerData: [{ companyIdentifier: VENDOR_ID }] }, { services: [GATT.uartService] }],
    optionalServices: SERVICES,
  });
}

/** Devices this origin was given before (needs the experimental flag); [] otherwise. */
export async function knownDevices() {
  if (!capabilities().getDevices) return [];
  try {
    return await bt().getDevices();
  } catch {
    return [];
  }
}

/** Manufacturer data as the codec expects it: vendor ID first. */
function mfrBytes(dataView) {
  const body = new Uint8Array(dataView.buffer, dataView.byteOffset, dataView.byteLength);
  return [VENDOR_ID & 0xff, VENDOR_ID >> 8, ...body];
}

/**
 * Listens to one device's advertisements (flagged API). Calls `onAdvert({device, mfrData, rssi})`.
 * Returns a stop function, or null when unsupported.
 */
export async function watchAdvertisements(device, onAdvert) {
  if (typeof device.watchAdvertisements !== 'function') return null;
  const handler = (e) => {
    const data = e.manufacturerData?.get(VENDOR_ID);
    if (data) onAdvert({ device, mfrData: mfrBytes(data), rssi: e.rssi ?? null });
  };
  try {
    device.addEventListener('advertisementreceived', handler);
    await device.watchAdvertisements();
  } catch {
    device.removeEventListener('advertisementreceived', handler);
    return null;
  }
  return () => {
    device.removeEventListener('advertisementreceived', handler);
    device.unwatchAdvertisements?.();
  };
}

/** Passive scan for every Combustion advertisement (flagged API). Must run in a user gesture. Returns stop(). */
export async function startScan(onAdvert) {
  const scan = await bt().requestLEScan({ filters: [{ manufacturerData: [{ companyIdentifier: VENDOR_ID }] }] });
  const handler = (e) => {
    const data = e.manufacturerData?.get(VENDOR_ID);
    if (data) onAdvert({ device: e.device, mfrData: mfrBytes(data), rssi: e.rssi ?? null });
  };
  bt().addEventListener('advertisementreceived', handler);
  return () => {
    bt().removeEventListener('advertisementreceived', handler);
    scan.stop();
  };
}

/**
 * Tries to learn what a device is from one advertisement: `{kind:'probe', serial}` or `{kind:'node', serial,
 * productType}`. Resolves null after `timeoutMs` or when the flagged API is missing.
 */
export function identifyFromAdvertisement(device, timeoutMs = 4000) {
  return new Promise((resolve) => {
    let stop = null;
    const done = (v) => {
      clearTimeout(timer);
      stop?.();
      resolve(v);
    };
    const timer = setTimeout(() => done(null), timeoutMs);
    watchAdvertisements(device, ({ mfrData }) => {
      try {
        const p = decodeAdvertisement(mfrData);
        if (p.kind === 'probe') done({ kind: 'probe', serial: p.serial, probeNumber: p.probeNumber });
        else if (p.kind === 'node') done({ kind: 'node', serial: p.serial, productType: p.nodeProductType });
      } catch {
        /* not ours */
      }
    }).then((s) => {
      if (!s) done(null);
      else stop = s;
    });
  });
}

/** GATT connection over a BluetoothDevice, in the shape described in gatt.js. */
export class WebBleConnection {
  /** Frames are written whole; the browser negotiates the MTU. On failure the write is retried in 20-byte chunks. */
  mtu = 515;
  #chars = new Map();
  #disconnectHandlers = new Set();
  #closing = false;

  static async connect(device, timeoutMs = 15_000) {
    const server = await Promise.race([
      device.gatt.connect(),
      new Promise((_, reject) => setTimeout(() => reject(new Error('connect timed out')), timeoutMs)),
    ]);
    return new WebBleConnection(device, server);
  }

  constructor(device, server) {
    this.device = device;
    this.server = server;
    this.id = device.id;
    this.name = device.name ?? 'Combustion device';
    this.onGattDisconnected = () => {
      device.removeEventListener('gattserverdisconnected', this.onGattDisconnected);
      const reason = this.#closing ? 'requested' : 'linkLost';
      for (const fn of [...this.#disconnectHandlers]) fn(reason);
      this.#disconnectHandlers.clear();
    };
    device.addEventListener('gattserverdisconnected', this.onGattDisconnected);
  }

  async discover() {
    for (const service of SERVICES) {
      let s;
      try {
        s = await this.server.getPrimaryService(service);
      } catch {
        continue;
      }
      for (const c of await s.getCharacteristics().catch(() => [])) this.#chars.set(c.uuid.toLowerCase(), c);
    }
    return new Set(this.#chars.keys());
  }

  #char(uuid) {
    const c = this.#chars.get(uuid);
    if (!c) throw new Error(`characteristic not found: ${uuid}`);
    return c;
  }

  async read(uuid) {
    const v = await this.#char(uuid).readValue();
    return new Uint8Array(v.buffer, v.byteOffset, v.byteLength);
  }

  async write(uuid, bytes) {
    const c = this.#char(uuid);
    const put = (b) => (c.writeValueWithResponse ? c.writeValueWithResponse(Uint8Array.from(b)) : c.writeValue(Uint8Array.from(b)));
    try {
      await put(bytes);
    } catch (e) {
      if (bytes.length <= 20 || !this.device.gatt.connected) throw e;
      for (let i = 0; i < bytes.length; i += 20) await put(bytes.slice(i, i + 20));
    }
  }

  async subscribe(uuid, fn) {
    const c = this.#char(uuid);
    const handler = (e) => {
      const v = e.target.value;
      fn(new Uint8Array(v.buffer, v.byteOffset, v.byteLength));
    };
    c.addEventListener('characteristicvaluechanged', handler);
    await c.startNotifications();
    return () => c.removeEventListener('characteristicvaluechanged', handler);
  }

  onDisconnect(fn) {
    this.#disconnectHandlers.add(fn);
    return () => this.#disconnectHandlers.delete(fn);
  }

  async close() {
    this.#closing = true;
    if (this.device.gatt.connected) this.device.gatt.disconnect();
    else this.onGattDisconnected();
  }
}

/** A stable 8-hex-digit stand-in serial from the browser's device id, for probes whose serial cannot be read. */
export function pseudoSerial(deviceId) {
  let h = 0x811c9dc5;
  for (const ch of deviceId) h = Math.imul(h ^ ch.charCodeAt(0), 0x01000193) >>> 0;
  return h.toString(16).toUpperCase().padStart(8, '0');
}
