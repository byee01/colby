// Plays a hardware capture from spec/replays (macOS/Windows RecordingTransport, format v1) into the web app on a fake
// clock: adverts go to `ingestAdvertisement`, a recorded connection becomes a GATT connection that delivers the
// recorded notifications at their times. The app's own writes are not answered, except that a recorded probe UART
// response can match a pending request of the same type (the probe UART has no request IDs).
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { hexToBytes } from '../src/codec/index.js';
import { GATT } from '../src/transport/gatt.js';

const REPLAYS = fileURLToPath(new URL('../../spec/replays/', import.meta.url));

export function loadReplay(name) {
  const dir = join(REPLAYS, name);
  const meta = JSON.parse(readFileSync(join(dir, 'meta.json'), 'utf8'));
  const events = readFileSync(join(dir, 'events.jsonl'), 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  return { meta, events };
}

/** A GATT connection backed by recorded notifications. */
export class ReplayConnection {
  mtu = 185;
  #subs = new Map();
  #disconnect = new Set();
  closed = false;

  constructor(id, characteristics) {
    this.id = id;
    this.name = id;
    this.characteristics = characteristics;
  }

  async discover() { return this.characteristics; }
  async read() { throw new Error('not recorded'); }
  async write() {}

  async subscribe(uuid, fn) {
    if (!this.#subs.has(uuid)) this.#subs.set(uuid, new Set());
    this.#subs.get(uuid).add(fn);
    return () => this.#subs.get(uuid)?.delete(fn);
  }

  push(uuid, bytes) {
    if (this.closed) return;
    for (const fn of this.#subs.get(uuid) ?? []) fn(Uint8Array.from(bytes));
  }

  onDisconnect(fn) {
    this.#disconnect.add(fn);
    return () => this.#disconnect.delete(fn);
  }

  drop(reason = 'linkLost') {
    if (this.closed) return;
    this.closed = true;
    for (const fn of [...this.#disconnect]) fn(reason);
  }

  async close() { this.drop('requested'); }
}

/**
 * Runs the capture. `devices` maps a peripheral to `{serial, productType?}`; recorded connections to those become app
 * devices. Calls `onEvent(event)` after each event is delivered (and the clock has reached its time).
 */
export async function play({ app, clock, events, devices = {}, onEvent = () => {} }) {
  const current = new Map();
  const charsOf = (peripheral) => {
    const set = new Set([GATT.uartRX, GATT.uartTX]);
    if (!devices[peripheral]?.productType) set.add(GATT.probeStatus);
    for (const e of events) if (e.peripheral === peripheral && e.char) set.add(e.char.toLowerCase());
    return set;
  };
  let elapsed = 0;
  for (const e of events) {
    await clock.advance(Math.max(0, (e.t - elapsed) * 1000));
    elapsed = Math.max(elapsed, e.t);
    const device = devices[e.peripheral];
    switch (e.type) {
      case 'adv':
        app.ingestAdvertisement({ mfrData: hexToBytes(e.hex), rssi: e.rssi });
        break;
      case 'connect':
        if (!device) break;
        current.set(e.peripheral, new ReplayConnection(e.peripheral, charsOf(e.peripheral)));
        if (!app.devices.has(e.peripheral)) {
          app.addDevice({
            id: e.peripheral,
            name: device.serial,
            open: async () => {
              const c = current.get(e.peripheral);
              if (!c || c.closed) throw new Error('out of range');
              return c;
            },
            identify: async () => device,
          });
        } else app.retry(e.peripheral);
        break;
      case 'notify':
        current.get(e.peripheral)?.push(e.char.toLowerCase(), hexToBytes(e.hex));
        break;
      case 'disconnect':
        current.get(e.peripheral)?.drop('linkLost');
        break;
      default:
    }
    onEvent(e);
  }
  await clock.advance(100);
}
