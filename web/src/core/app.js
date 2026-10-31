// The app facade: devices and their links, routing, and the store → presenter / history / alerts pipeline.
// Web counterpart of CombustionApp.swift. No DOM here, so it runs under Node tests too.
//
// A device is something the user added: `{id, name, open(), identify(connection, isProbe)}`. `open` returns a GATT
// connection (transport/webBluetooth.js or transport/simulated.js). The app reconnects with backoff 1, 2, 4 ... 30 s
// until the device is removed.

import { Emitter, systemClock } from './support.js';
import { ProbeStore } from './probeStore.js';
import { PredictionPresenter } from './presenter.js';
import { HistoryStore, MemoryHistoryStorage } from './history.js';
import { Commands } from './commands.js';
import { AlertEngine, MemoryRuleStore } from './alerts.js';
import { DirectProbeLink, NodeLink } from './links.js';
import { GATT } from '../transport/gatt.js';
import { decodeAdvertisement } from '../codec/index.js';

const BACKOFF_MS = [1000, 2000, 4000, 8000, 16000, 30000];

export class ColbyApp extends Emitter {
  devices = new Map();
  /** Probes the user hid; they are not evaluated for alerts. */
  hidden = new Set();

  constructor({
    clock = systemClock, historyStorage = new MemoryHistoryStorage(), ruleStore = new MemoryRuleStore(), sinks = [],
    keepAwake = null, requestIds,
  } = {}) {
    super();
    this.clock = clock;
    this.requestIds = requestIds;
    this.store = new ProbeStore({ clock });
    this.presenter = new PredictionPresenter({ clock });
    this.history = new HistoryStore({ storage: historyStorage, clock, fetcher: (serial) => this.route(serial) });
    this.commands = new Commands({ store: this.store, route: (serial) => this.route(serial), clock });
    this.alerts = new AlertEngine({ clock, ruleStore, sinks, keepAwake, silencer: this.commands });

    this.store.on('status', (e) => {
      this.presenter.ingest(e);
      this.history.ingest(e).catch((err) => console.error('history', err));
    });
    this.store.on('probes', (map) => {
      this.alerts.ingestSnapshots(map);
      this.#syncFollowed();
      this.emit('probes', map);
    });
    this.store.on('nodes', (nodes) => this.emit('nodes', nodes));
    this.presenter.on('prediction', (v) => {
      this.alerts.ingestPrediction(v);
      this.emit('prediction', v);
    });
  }

  async start() {
    await this.history.load();
  }

  stop() {
    for (const d of [...this.devices.values()]) this.removeDevice(d.id);
    this.store.stop();
    this.presenter.stop();
    this.alerts.stop();
  }

  // MARK: Devices

  /** Adds a device and connects to it. Returns the device record. */
  addDevice({ id, name, open, identify = null, simulated = false }) {
    const existing = this.devices.get(id);
    if (existing) {
      if (existing.state === 'disconnected') this.#connect(existing);
      return existing;
    }
    const device = {
      id, name, open, identify, simulated, kind: null, serial: null, productType: null, link: null,
      state: 'connecting', error: null, attempt: 0, retryTimer: null, removed: false,
    };
    this.devices.set(id, device);
    this.#connect(device);
    return device;
  }

  removeDevice(id) {
    const d = this.devices.get(id);
    if (!d) return;
    d.removed = true;
    if (d.retryTimer != null) this.clock.clearTimeout(d.retryTimer);
    d.link?.close().catch(() => {});
    d.connection?.close?.().catch?.(() => {});
    this.devices.delete(id);
    if (d.kind === 'node') this.store.removeNode(d.serial);
    this.#emitDevices();
  }

  /** Reconnects now instead of waiting for the backoff. */
  retry(id) {
    const d = this.devices.get(id);
    if (!d || d.link || d.state === 'connecting') return;
    if (d.retryTimer != null) this.clock.clearTimeout(d.retryTimer);
    d.retryTimer = null;
    d.attempt = 0;
    this.#connect(d);
  }

  #emitDevices() { this.emit('devices', [...this.devices.values()]); }

  async #connect(d) {
    d.state = d.attempt ? 'reconnecting' : 'connecting';
    d.error = null;
    this.#emitDevices();
    let connection;
    try {
      connection = await d.open();
      if (d.removed) {
        await connection.close();
        return;
      }
      d.connection = connection;
      const chars = await connection.discover();
      const isProbe = chars.has(GATT.probeStatus);
      const ident = (await d.identify?.(connection, isProbe)) ?? {};
      d.kind = isProbe ? 'probe' : 'node';
      d.serial = ident.serial ?? d.serial ?? connection.id;
      d.productType = ident.productType ?? d.productType ?? (isProbe ? null : 'display');
      const options = { clock: this.clock, requestIds: this.requestIds };
      const link = isProbe
        ? new DirectProbeLink(d.serial, connection, options)
        : new NodeLink(d.serial, d.productType, connection, options);
      link.on('observation', (o) => this.store.ingest(o));
      link.on('node', (n) => this.store.ingestNode(n));
      link.on('disconnected', (reason) => this.#lost(d, link, reason));
      await link.start();
      if (d.removed) {
        await link.close();
        return;
      }
      d.link = link;
      d.state = 'connected';
      d.attempt = 0;
      this.#emitDevices();
      if (isProbe) this.history.resume(d.serial);
    } catch (e) {
      d.error = e?.message ?? String(e);
      connection?.close?.().catch?.(() => {});
      this.#scheduleRetry(d);
    }
  }

  #lost(d, link, reason) {
    if (d.link !== link) return;
    d.link = null;
    if (d.removed) return;
    if (reason === 'requested') {
      d.state = 'disconnected';
      this.#emitDevices();
      return;
    }
    this.#scheduleRetry(d);
  }

  #scheduleRetry(d) {
    if (d.removed) return;
    const delay = BACKOFF_MS[Math.min(d.attempt, BACKOFF_MS.length - 1)];
    d.attempt++;
    d.state = 'reconnecting';
    d.nextRetryAt = this.clock.now() + delay;
    this.#emitDevices();
    d.retryTimer = this.clock.setTimeout(() => {
      d.retryTimer = null;
      if (!d.removed && !d.link) this.#connect(d);
    }, delay);
  }

  // MARK: Routing

  /** The link that can carry requests for a probe: a direct link, else the node link with the fewest hops. */
  route(serial) {
    let best = null;
    let bestHops = Infinity;
    for (const d of this.devices.values()) {
      const link = d.link;
      if (!link || !link.covers(serial)) continue;
      if (link.kind === 'probe') return link;
      const hops = link.snapshot.hopCounts[serial] ?? 4;
      if (hops < bestHops) {
        best = link;
        bestHops = hops;
      }
    }
    return best;
  }

  // MARK: Advertisements (flagged scan API)

  /** Feeds one advertisement (`mfrData` with the vendor ID first). */
  ingestAdvertisement({ mfrData, rssi = null }) {
    let packet;
    try {
      packet = decodeAdvertisement(mfrData);
    } catch {
      return;
    }
    const now = this.clock.now();
    // Serial 0: a node with no probe in that slot yet (a Display right after power-on repeats all-zero packets).
    if ((packet.kind === 'probe' || packet.kind === 'repeated') && packet.serial === '00000000') return;
    if (packet.kind === 'probe' || packet.kind === 'repeated') {
      const { kind, hopCount, ...advertisement } = packet;
      this.store.ingest({
        serial: packet.serial,
        source: kind === 'probe'
          ? { kind: 'advertisement', rssi, highRadioPower: packet.preferences?.highRadioPower ?? null, lastSeen: now }
          : { kind: 'nodeAdvertisement', hopCount, rssi, lastSeen: now },
        payload: { advertisement },
        receivedAt: now,
      });
    } else if (packet.kind === 'node') {
      this.store.ingestNodeSighting({ serial: packet.serial, productType: packet.nodeProductType, rssi, time: now });
    }
  }

  // MARK: Probes

  setHidden(serial, hidden) {
    if (hidden) this.hidden.add(serial);
    else this.hidden.delete(serial);
    this.#syncFollowed();
  }

  #followedKey = '';

  #syncFollowed() {
    const followed = [...this.store.mergers.keys()].filter((s) => !this.hidden.has(s)).sort();
    const key = followed.join(',');
    if (key === this.#followedKey) return;
    this.#followedKey = key;
    this.alerts.setFollowed(followed);
  }
}
