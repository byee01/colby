// Persistent cooks: sessions, log samples, time derivation, backfill. Port of SessionTracker.swift,
// BackfillPlanner.swift and the parts of HistoryStore.swift the web app needs (docs/02 §6.2, §6.3).
//
// Samples are keyed (session key, seq) so every path (live fetch, backfill, re-delivery) is idempotent. Times are
// derived on read from the session's latest anchor (seq = logRange.max, time = status arrival).

import { Emitter, systemClock } from './support.js';
import { SENSORS } from '../codec/index.js';

/**
 * Detects the start of a new cook from successive statuses of one probe. Pure.
 * 1. First status: new session. 2. Non-zero id changed: new session. 3. With id 0 on either side: `logRange.max`
 * regressed, or a gap over 10 min with `logRange.min` lower: new session. 4. Id 0 → non-zero: same session, adopted.
 */
export class SessionTracker {
  currentSessionId = null;
  lastRange = null;
  lastSeen = null;

  constructor(gapThresholdMs = 600_000) {
    this.gapThresholdMs = gapThresholdMs;
  }

  static restoring(sessionId, logRange, lastSeen, gapThresholdMs) {
    const t = new SessionTracker(gapThresholdMs);
    Object.assign(t, { currentSessionId: sessionId, lastRange: logRange, lastSeen });
    return t;
  }

  /** Returns `{decision: 'new', reason}`, `{decision: 'continuing'}` or `{decision: 'adopted', sessionId}`. */
  observe(sessionId, logRange, time) {
    try {
      const current = this.currentSessionId;
      if (current == null) {
        this.currentSessionId = sessionId;
        return { decision: 'new', reason: 'initial' };
      }
      if (sessionId !== 0 && current !== 0 && sessionId !== current) {
        this.currentSessionId = sessionId;
        return { decision: 'new', reason: 'sessionIdChanged' };
      }
      if (sessionId === 0 || current === 0) {
        const reason = this.#fallback(logRange, time);
        if (reason) {
          this.currentSessionId = sessionId;
          return { decision: 'new', reason };
        }
      }
      if (current === 0 && sessionId !== 0) {
        this.currentSessionId = sessionId;
        return { decision: 'adopted', sessionId };
      }
      return { decision: 'continuing' };
    } finally {
      this.lastRange = logRange;
      this.lastSeen = time;
    }
  }

  #fallback(range, time) {
    const last = this.lastRange;
    if (!last) return null;
    if (range.max < last.max) return 'logRangeRegressed';
    if (this.lastSeen != null && time - this.lastSeen > this.gapThresholdMs && range.min < last.min) return 'returnedAfterGap';
    return null;
  }
}

/**
 * Missing seqs within `range` as inclusive `[start, end]` requests of at most `chunkSize` records, newest first
 * (the graph fills from the right). Holes are never merged across stored records.
 */
export function planBackfill(existing, range, chunkSize = 128) {
  const lo = range.min;
  const hi = range.max;
  if (lo > hi) return [];
  const size = Math.max(1, chunkSize);
  const present = [...new Set(existing)].filter((s) => s >= lo && s <= hi).sort((a, b) => a - b);
  const holes = [];
  let cursor = lo;
  for (const s of present) {
    if (s > cursor) holes.push([cursor, s - 1]);
    cursor = s + 1;
  }
  if (cursor <= hi) holes.push([cursor, hi]);
  const out = [];
  for (const [holeLo, holeHi] of holes.reverse()) {
    let top = holeHi;
    for (;;) {
      const start = Math.max(holeLo, top - (size - 1));
      out.push([start, top]);
      if (start === holeLo) break;
      top = start - 1;
    }
  }
  return out;
}

/** Used when a status carries no sample period (old firmware). */
export const DEFAULT_SAMPLE_PERIOD_MS = 5000;

/** In-memory storage; `storage.js` has the IndexedDB one with the same methods. */
export class MemoryHistoryStorage {
  sessions = new Map();
  samples = new Map();

  async loadSessions() { return [...this.sessions.values()].map((s) => ({ ...s })); }
  async putSession(session) { this.sessions.set(session.key, { ...session }); }

  async deleteSession(key) {
    this.sessions.delete(key);
    this.samples.delete(key);
  }

  async loadSamples(key) { return [...(this.samples.get(key)?.values() ?? [])]; }

  async putSamples(key, samples) {
    if (!this.samples.has(key)) this.samples.set(key, new Map());
    const m = this.samples.get(key);
    for (const s of samples) if (!m.has(s.seq)) m.set(s.seq, s);
  }
}

/** A log record as stored: seq, 8 temperatures, virtual sensor choice, prediction summary. */
export function sampleFromRecord(r) {
  return {
    seq: r.sequence,
    temps: r.temperatures,
    vs: [r.prediction.virtualSensors.core, r.prediction.virtualSensors.surface, r.prediction.virtualSensors.ambient]
      .map((s) => SENSORS.indexOf(s)),
    state: r.prediction.state,
    setpoint: r.prediction.setpoint,
  };
}

/** A Normal status is the log record at `logRange.max` (iOS SDK `addDataToLog`). */
export function sampleFromStatus(status) {
  return sampleFromRecord({
    sequence: status.logRange.max,
    temperatures: status.temperatures,
    prediction: { ...status.prediction, virtualSensors: status.virtualSensors },
  });
}

/**
 * Sessions and their samples. Consumes ProbeStore `status` events; fetches records with `fetcher(serial)` (a link
 * with `readLogs(serial, start, end, onRecord)`, or null when no link can). Emits `sessions` (list) and
 * `samples` `{key}` when a session's data changes.
 */
export class HistoryStore extends Emitter {
  sessions = new Map();
  #samples = new Map();
  #trackers = new Map();
  #current = new Map();
  #busy = new Set();
  #again = new Set();

  constructor({ storage = new MemoryHistoryStorage(), fetcher = () => null, clock = systemClock, chunkSize = 128 } = {}) {
    super();
    Object.assign(this, { storage, fetcher, clock, chunkSize });
  }

  async load() {
    for (const s of await this.storage.loadSessions()) this.sessions.set(s.key, s);
    // Resume the newest session of each probe so a reload continues the same cook.
    for (const s of [...this.sessions.values()].sort((a, b) => a.lastSeen - b.lastSeen)) {
      this.#current.set(s.serial, s.key);
      this.#trackers.set(s.serial, SessionTracker.restoring(s.sessionId, s.logRange, s.lastSeen));
    }
    this.emit('sessions', this.list());
  }

  /** Sessions, newest first. */
  list() { return [...this.sessions.values()].sort((a, b) => b.startedAt - a.startedAt); }

  currentSession(serial) {
    const key = this.#current.get(serial);
    return key ? this.sessions.get(key) ?? null : null;
  }

  /** Samples of a session with derived times, ascending: `{seq, time, temps, vs, state, setpoint}`. */
  async samples(key) {
    const session = this.sessions.get(key);
    if (!session) return [];
    const cache = await this.#cache(key);
    const { anchor, samplePeriodMs } = session;
    return [...cache.values()]
      .sort((a, b) => a.seq - b.seq)
      .map((s) => ({ ...s, time: anchor.time - (anchor.seq - s.seq) * samplePeriodMs }));
  }

  async #cache(key) {
    let cache = this.#samples.get(key);
    if (!cache) {
      cache = new Map((await this.storage.loadSamples(key)).map((s) => [s.seq, s]));
      this.#samples.set(key, cache);
    }
    return cache;
  }

  async rename(key, name) {
    const s = this.sessions.get(key);
    if (!s) return;
    s.name = name;
    await this.storage.putSession(s);
    this.emit('sessions', this.list());
  }

  async deleteSession(key) {
    const s = this.sessions.get(key);
    if (!s) return;
    this.sessions.delete(key);
    this.#samples.delete(key);
    if (this.#current.get(s.serial) === key) {
      this.#current.delete(s.serial);
      this.#trackers.delete(s.serial);
    }
    await this.storage.deleteSession(key);
    this.emit('sessions', this.list());
  }

  /** Feed one ProbeStore `status` event. */
  async ingest({ serial, status, receivedAt }) {
    const sessionId = status.session?.sessionId ?? 0;
    let tracker = this.#trackers.get(serial);
    if (!tracker) {
      tracker = new SessionTracker();
      this.#trackers.set(serial, tracker);
    }
    const d = tracker.observe(sessionId, status.logRange, receivedAt);
    let session = this.currentSession(serial);
    if (d.decision === 'new' || !session) {
      session = {
        key: `${serial}:${sessionId}:${receivedAt}`,
        serial, sessionId, startedAt: receivedAt, name: null,
        samplePeriodMs: status.session?.samplePeriodMs || DEFAULT_SAMPLE_PERIOD_MS,
        anchor: { seq: status.logRange.max, time: receivedAt },
        logRange: status.logRange, lastSeen: receivedAt, fetchedMax: null,
      };
      this.sessions.set(session.key, session);
      this.#current.set(serial, session.key);
      this.#samples.set(session.key, new Map());
    } else if (d.decision === 'adopted') {
      session.sessionId = d.sessionId;
    }
    session.anchor = { seq: status.logRange.max, time: receivedAt };
    session.logRange = status.logRange;
    session.lastSeen = receivedAt;
    if (status.session?.samplePeriodMs) session.samplePeriodMs = status.session.samplePeriodMs;
    // The first sample's time is the true start of the cook (the probe may have logged before the app started).
    session.startedAt = Math.min(session.startedAt, receivedAt - (status.logRange.max - status.logRange.min) * session.samplePeriodMs);
    await this.storage.putSession(session);
    if (d.decision === 'new') this.emit('sessions', this.list());
    // Stored straight from the status, so the newest record is never requested. Instant Read statuses carry only T1.
    if (status.mode !== 'instantRead') {
      const cache = await this.#cache(session.key);
      const sample = sampleFromStatus(status);
      if (!cache.has(sample.seq)) {
        cache.set(sample.seq, sample);
        await this.#store(session, [sample]);
      }
    }
    this.#fetch(session);
  }

  /** Called when a link appears: retries what could not be fetched before. */
  resume(serial) {
    const s = this.currentSession(serial);
    if (s) this.#fetch(s);
  }

  /** One fetch loop per session: fill every hole in the probe's log range, newest first. */
  async #fetch(session) {
    if (this.#busy.has(session.key)) {
      this.#again.add(session.key);
      return;
    }
    const link = this.fetcher(session.serial);
    if (!link) return;
    this.#busy.add(session.key);
    try {
      do {
        this.#again.delete(session.key);
        const cache = await this.#cache(session.key);
        const plan = planBackfill(cache.keys(), session.logRange, this.chunkSize);
        for (const [start, end] of plan) {
          if (this.sessions.get(session.key) !== session) return;
          const batch = [];
          try {
            await link.readLogs(session.serial, start, end, (r) => {
              const sample = sampleFromRecord(r);
              cache.set(sample.seq, sample);
              batch.push(sample);
            });
          } catch {
            // Partial ranges are kept; the next status retries the rest.
            if (batch.length) await this.#store(session, batch);
            return;
          }
          await this.#store(session, batch);
        }
      } while (this.#again.has(session.key));
    } finally {
      this.#busy.delete(session.key);
    }
  }

  async #store(session, batch) {
    if (!batch.length) return;
    await this.storage.putSamples(session.key, batch);
    this.emit('samples', { key: session.key, serial: session.serial });
  }
}
