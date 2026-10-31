// Merges observations from every link into one snapshot per probe. Port of ProbeMerger.swift, ProbeStore.swift,
// InstantReadFilter.swift (docs/02 §6.1).
//
// Observation: `{serial, source: {kind, via, hopCount, rssi, highRadioPower, lastSeen}, payload, receivedAt}` where
// `payload` is `{advertisement}` (a decoded probe advertisement) or `{status}` (a decoded Probe Status).
// Source kinds: 'directConnection' > 'nodeConnection' > 'advertisement' > 'nodeAdvertisement'.

import { Emitter, systemClock } from './support.js';
import { SENSORS } from '../codec/index.js';

/**
 * Deadband filter for the Instant Read temperature, port of the Android SDK `InstantReadFilter` so the number
 * matches the phone app. The shown value moves only when the reading leaves `display ± (0.5 + 0.05 °C)`, then snaps
 * to a whole degree. Celsius and Fahrenheit are filtered independently. `null` clears.
 */
export class InstantReadFilter {
  static deadband = 0.05;
  celsius = null;
  fahrenheit = null;

  addReading(c) {
    if (c == null) {
      this.celsius = null;
      this.fahrenheit = null;
      return;
    }
    this.celsius = InstantReadFilter.#filtered(c, this.celsius, InstantReadFilter.deadband);
    this.fahrenheit = InstantReadFilter.#filtered((c * 9) / 5 + 32, this.fahrenheit, (InstantReadFilter.deadband * 9) / 5);
  }

  static #filtered(t, current, deadband) {
    const display = current ?? Math.floor(t + 0.5);
    if (t > display + 0.5 + deadband || t < display - 0.5 - deadband) return Math.floor(t + 0.5);
    return display;
  }
}

const RANK = { directConnection: 0, nodeConnection: 1, advertisement: 2, nodeAdvertisement: 3 };

/** directConnection > nodeConnection > advertisement > nodeAdvertisement; then fewest hops, freshest, via. */
export function sourceOrder(a, b) {
  if (RANK[a.kind] !== RANK[b.kind]) return RANK[a.kind] - RANK[b.kind];
  const ha = a.hopCount ?? Infinity;
  const hb = b.hopCount ?? Infinity;
  if (ha !== hb) return ha - hb;
  if (a.lastSeen !== b.lastSeen) return b.lastSeen - a.lastSeen;
  return (a.via ?? '').localeCompare(b.via ?? '');
}

const pathKey = (s) => `${s.kind}|${s.via ?? ''}`;

/** Merge state of one probe. Pure: arrival times are passed in. */
export class ProbeMerger {
  sources = new Map();
  live = null;
  status = null;
  filter = new InstantReadFilter();

  constructor(serial) {
    this.serial = serial;
  }

  /** Returns true if the observation was an accepted (freshest) full status. */
  ingest(o, arrivedAt) {
    this.sources.set(pathKey(o.source), { source: o.source, arrivedAt });
    const p = o.payload.advertisement ?? o.payload.status;
    this.#acceptLive(o.receivedAt, p);
    if (!o.payload.status) return false;
    const s = o.payload.status;
    if (this.status && o.receivedAt < this.status.receivedAt) return false;
    this.status = {
      prediction: s.prediction,
      alarms: s.alarms ?? this.status?.alarms ?? null,
      foodSafe: s.foodSafe ?? this.status?.foodSafe ?? null,
      session: { info: s.session, logRange: s.logRange },
      receivedAt: o.receivedAt,
    };
    return true;
  }

  #acceptLive(receivedAt, p) {
    if (this.live && receivedAt < this.live.receivedAt) return;
    this.live = {
      temperatures: p.temperatures,
      mode: p.mode,
      color: p.color,
      probeNumber: p.probeNumber,
      batteryLow: p.batteryLow,
      virtualSensors: p.virtualSensors,
      overheating: p.overheating ?? this.live?.overheating ?? [],
      receivedAt,
    };
    this.filter.addReading(p.mode === 'instantRead' ? p.temperatures[0] : null);
  }

  /** Drops sources with no data for `ttlMs`. Returns true if any was dropped. */
  expire(now, ttlMs) {
    let dropped = false;
    for (const [key, e] of this.sources) {
      if (now - e.arrivedAt >= ttlMs) {
        this.sources.delete(key);
        dropped = true;
      }
    }
    return dropped;
  }

  snapshot() {
    const live = this.live;
    if (!live) return null;
    const instant = live.mode === 'instantRead';
    const temps = live.temperatures.map((c, i) => (instant && i !== 0 ? null : c));
    const vs = live.virtualSensors;
    const at = (sensor) => temps[SENSORS.indexOf(sensor)];
    const sources = [...this.sources.values()].map((e) => e.source).sort(sourceOrder);
    return {
      serial: this.serial,
      probeNumber: live.probeNumber,
      color: live.color,
      mode: live.mode,
      temperatures: temps,
      instantRead: instant ? this.filter.celsius : null,
      instantReadFahrenheit: instant ? this.filter.fahrenheit : null,
      virtual: {
        coreSensor: vs.core, surfaceSensor: vs.surface, ambientSensor: vs.ambient,
        core: at(vs.core), surface: at(vs.surface), ambient: at(vs.ambient),
      },
      batteryLow: live.batteryLow,
      overheating: live.overheating,
      prediction: this.status?.prediction ?? null,
      alarms: this.status?.alarms ?? null,
      foodSafe: this.status?.foodSafe ?? null,
      session: this.status?.session ?? null,
      link: { sources, primary: sources[0] ?? null },
      receivedAt: live.receivedAt,
      isOffline: sources.length === 0,
    };
  }
}

/**
 * All probes and nodes. Events:
 * - `probes` (Map serial → snapshot), coalesced to at most one per `coalesceMs` (10 Hz);
 * - `status` `{serial, status, receivedAt}` for every accepted full status (not coalesced);
 * - `nodes` (Map serial → node snapshot).
 * A source silent for `sourceTimeoutMs` is dropped; a probe with no source stays, offline.
 */
export class ProbeStore extends Emitter {
  mergers = new Map();
  published = new Map();
  nodes = new Map();
  #dirty = new Set();
  #lastFlush = -Infinity;
  #flushTimer = null;
  #expiryTimer = null;

  constructor({ clock = systemClock, sourceTimeoutMs = 10_000, coalesceMs = 100, expiryCheckMs = 1000 } = {}) {
    super();
    this.clock = clock;
    this.sourceTimeoutMs = sourceTimeoutMs;
    this.coalesceMs = coalesceMs;
    this.expiryCheckMs = expiryCheckMs;
  }

  stop() {
    if (this.#flushTimer != null) this.clock.clearTimeout(this.#flushTimer);
    if (this.#expiryTimer != null) this.clock.clearInterval(this.#expiryTimer);
    this.#flushTimer = null;
    this.#expiryTimer = null;
  }

  snapshot(serial) { return this.mergers.get(serial)?.snapshot() ?? null; }

  snapshots() {
    const out = new Map();
    for (const [serial, m] of this.mergers) {
      const s = m.snapshot();
      if (s) out.set(serial, s);
    }
    return out;
  }

  ingest(o) {
    this.#ensureExpiry();
    let m = this.mergers.get(o.serial);
    if (!m) {
      m = new ProbeMerger(o.serial);
      this.mergers.set(o.serial, m);
    }
    if (m.ingest(o, this.clock.now()) && o.payload.status) {
      this.emit('status', { serial: o.serial, status: o.payload.status, receivedAt: o.receivedAt });
    }
    this.#markDirty(o.serial);
  }

  /** Records a node: `{serial, productType, probes, hopCounts, isConnected, link, firmware, heartbeatCount}`. */
  ingestNode(node) {
    this.#ensureExpiry();
    const prev = this.nodes.get(node.serial);
    this.nodes.set(node.serial, { ...node, firmware: node.firmware ?? prev?.firmware ?? null });
    this.emit('nodes', this.nodes);
  }

  /** A node heard advertising; a connected node is already better known and is left alone. */
  ingestNodeSighting({ serial, productType, rssi, time }) {
    this.#ensureExpiry();
    const prev = this.nodes.get(serial);
    if (prev?.isConnected) return;
    this.nodes.set(serial, {
      serial, productType, probes: prev?.probes ?? [], hopCounts: prev?.hopCounts ?? {}, isConnected: false,
      firmware: prev?.firmware ?? null, heartbeatCount: 0,
      link: { kind: 'nodeAdvertisement', rssi, lastSeen: time },
    });
    this.emit('nodes', this.nodes);
  }

  removeNode(serial) {
    if (this.nodes.delete(serial)) this.emit('nodes', this.nodes);
  }

  /** Forgets a probe entirely (the user removed it). */
  forget(serial) {
    this.mergers.delete(serial);
    this.published.delete(serial);
    this.emit('probes', this.published);
  }

  #ensureExpiry() {
    if (this.#expiryTimer != null) return;
    this.#expiryTimer = this.clock.setInterval(() => this.#expire(), this.expiryCheckMs);
  }

  #expire() {
    const now = this.clock.now();
    for (const [serial, m] of this.mergers) {
      if (m.expire(now, this.sourceTimeoutMs)) this.#markDirty(serial);
    }
    let changed = false;
    for (const [serial, n] of this.nodes) {
      if (!n.isConnected && now - n.link.lastSeen >= this.sourceTimeoutMs) {
        this.nodes.delete(serial);
        changed = true;
      }
    }
    if (changed) this.emit('nodes', this.nodes);
  }

  #markDirty(serial) {
    this.#dirty.add(serial);
    if (this.#flushTimer != null) return;
    const since = this.clock.now() - this.#lastFlush;
    if (since < this.coalesceMs) {
      this.#flushTimer = this.clock.setTimeout(() => {
        this.#flushTimer = null;
        this.#flush();
      }, this.coalesceMs - since);
    } else {
      this.#flush();
    }
  }

  #flush() {
    if (!this.#dirty.size) return;
    this.#lastFlush = this.clock.now();
    for (const serial of this.#dirty) {
      const snap = this.mergers.get(serial)?.snapshot();
      if (snap) this.published.set(serial, snap);
    }
    this.#dirty.clear();
    this.emit('probes', this.published);
  }
}
