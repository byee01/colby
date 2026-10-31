// Prediction countdown shown to the user. Port of PredictionPresenter.swift (iOS SDK `PredictionManager` rules, so
// the numbers match the Display and the phone app). docs/01 §6, docs/02 §7.
//
// - Seconds remaining exist only while `predicting` with a raw value of at most 4 h.
// - Above 300 s: rounded to 15 s, replaced only when the status `seq % 3 == 0` (or there is no value yet).
// - At 300 s and below: a linear countdown, advanced by ticks, aiming at `raw - statusPeriod` by the next status.
// - Stale after 15 s without a status.

import { Emitter, systemClock } from './support.js';
import { percentToRemoval } from '../codec/index.js';

const MAX_SECONDS = 4 * 3600;
const COUNTDOWN_LIMIT = 300;
const ROUND_TO = 15;
const SLACK_MS = 1;

/** Pure countdown logic for one probe; times are passed in (epoch ms). */
export class PredictionSmoother {
  status = null;
  lastStatusAt = null;
  readySince = null;
  #displayed = null;
  #readyAt = null;
  #ramp = null;

  constructor(statusPeriodMs = 5000) {
    this.statusPeriodMs = statusPeriodMs;
  }

  get isRamping() { return this.#ramp != null; }

  ingest(s, seq, now) {
    this.tick(now);
    this.status = s;
    this.lastStatusAt = now;
    if (s.state === 'removalPredictionDone') this.readySince ??= now;
    else this.readySince = null;
    if (s.state !== 'predicting' || s.rawSecondsRemaining > MAX_SECONDS) {
      this.#displayed = null;
      this.#readyAt = null;
      this.#ramp = null;
      return;
    }
    const raw = s.rawSecondsRemaining;
    if (raw > COUNTDOWN_LIMIT) {
      this.#ramp = null;
      if (this.#displayed == null || seq % 3 === 0) {
        const rounded = Math.round(raw / ROUND_TO) * ROUND_TO;
        this.#displayed = rounded;
        this.#readyAt = now + rounded * 1000;
      }
    } else {
      const from = this.#displayed ?? raw;
      this.#displayed = from;
      this.#ramp = { from, to: Math.max(raw - this.statusPeriodMs / 1000, 0), start: now };
      this.#readyAt = now + raw * 1000;
    }
  }

  tick(now) {
    const r = this.#ramp;
    if (!r) return;
    const fraction = Math.min(1, Math.max(0, (now - r.start + SLACK_MS) / this.statusPeriodMs));
    this.#displayed = r.from + (r.to - r.from) * fraction;
    if (fraction >= 1) this.#ramp = null;
  }

  isStale(now, limitMs) {
    return this.lastStatusAt != null && now - this.lastStatusAt + SLACK_MS >= limitMs;
  }

  /** `{state, mode, type, setpoint, estimatedCore, percentToRemoval, secondsRemaining, isStale, readyAt, readySince}`. */
  view(serial, now, staleAfterMs) {
    const s = this.status;
    if (!s) return null;
    return {
      serial,
      state: s.state,
      mode: s.mode,
      type: s.type,
      setpoint: s.setpoint,
      estimatedCore: s.estimatedCore,
      percentToRemoval: percentToRemoval(s),
      secondsRemaining: this.#displayed == null ? null : Math.max(0, Math.round(this.#displayed)),
      isStale: this.isStale(now, staleAfterMs),
      readyAt: this.#readyAt,
      readySince: this.readySince,
    };
  }
}

const sameView = (a, b) => a && b && Object.keys(a).every((k) => a[k] === b[k]);

/**
 * Turns each probe's status events into prediction views. Emits `prediction` (a view) on every change. A 200 ms
 * timer runs only while a countdown is moving; a 1 s timer watches for staleness while any probe is reporting.
 */
export class PredictionPresenter extends Emitter {
  smoothers = new Map();
  last = new Map();
  #ticker = null;
  #staleWatch = null;

  constructor({ clock = systemClock, tickMs = 200, staleAfterMs = 15_000, statusPeriodMs = 5000 } = {}) {
    super();
    this.clock = clock;
    this.tickMs = tickMs;
    this.staleAfterMs = staleAfterMs;
    this.statusPeriodMs = statusPeriodMs;
  }

  /** The view as of now, computed on the spot. */
  view(serial) {
    const s = this.smoothers.get(serial);
    if (!s) return null;
    const now = this.clock.now();
    s.tick(now);
    return s.view(serial, now, this.staleAfterMs);
  }

  ingest({ serial, status }) {
    const now = this.clock.now();
    let s = this.smoothers.get(serial);
    if (!s) {
      s = new PredictionSmoother(this.statusPeriodMs);
      this.smoothers.set(serial, s);
    }
    s.ingest(status.prediction, status.logRange.max, now);
    this.#publish(serial, now);
    this.#reschedule();
  }

  forget(serial) {
    this.smoothers.delete(serial);
    this.last.delete(serial);
  }

  stop() {
    if (this.#ticker != null) this.clock.clearInterval(this.#ticker);
    if (this.#staleWatch != null) this.clock.clearInterval(this.#staleWatch);
    this.#ticker = null;
    this.#staleWatch = null;
  }

  #publish(serial, now) {
    const v = this.smoothers.get(serial)?.view(serial, now, this.staleAfterMs);
    if (!v || sameView(this.last.get(serial), v)) return;
    this.last.set(serial, v);
    this.emit('prediction', v);
  }

  #reschedule() {
    const now = this.clock.now();
    const smoothers = [...this.smoothers.values()];
    if (smoothers.some((s) => s.isRamping)) {
      this.#ticker ??= this.clock.setInterval(() => this.#refresh(), this.tickMs);
    } else if (this.#ticker != null) {
      this.clock.clearInterval(this.#ticker);
      this.#ticker = null;
    }
    if (smoothers.some((s) => s.lastStatusAt != null && !s.isStale(now, this.staleAfterMs))) {
      this.#staleWatch ??= this.clock.setInterval(() => this.#refresh(), 1000);
    } else if (this.#staleWatch != null) {
      this.clock.clearInterval(this.#staleWatch);
      this.#staleWatch = null;
    }
  }

  #refresh() {
    const now = this.clock.now();
    for (const [serial, s] of this.smoothers) {
      s.tick(now);
      this.#publish(serial, now);
    }
    this.#reschedule();
  }
}
