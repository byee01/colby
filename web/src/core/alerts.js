// Rules, probe alarms and overheat in one pipeline, with acknowledge, snooze and keep-awake. Port of AlertTypes.swift,
// RuleEvaluation.swift, AlertEngine.swift (docs/02 §9, docs/06 §6-7).
//
//   idle ──condition true──▶ firing ──ack──▶ acknowledged ──condition false──▶ idle
//                             │ └─snooze──▶ snoozed ──timer──▶ firing (if still true)
//                             └─condition false (auto-clear)──▶ idle
//
// Rule kinds (`rule.kind.type`): temperatureAbove {channel, celsius, hysteresis}, temperatureBelow {...},
// predictionWithin {seconds}, predictionDone, restingDone, ambientOutOfRange {min, max, sustain},
// stall {window, minRise}, probeOffline {seconds, onlyDuringCook}, batteryLow. Durations in seconds.

import { Emitter, systemClock } from './support.js';
import { ALARM_CHANNELS, SENSORS } from '../codec/index.js';

/** The set a probe gets when first followed (06 §6). Overheat and probe alarms are always on and are not rules. */
export function defaultRules(serial) {
  return [
    { id: `${serial}.ready`, kind: { type: 'predictionDone' }, enabled: true },
    { id: `${serial}.fiveMinutes`, kind: { type: 'predictionWithin', seconds: 300 }, enabled: true },
    { id: `${serial}.offline`, kind: { type: 'probeOffline', seconds: 60, onlyDuringCook: true }, enabled: true },
    { id: `${serial}.battery`, kind: { type: 'batteryLow' }, enabled: true },
  ];
}

const sustainOf = (k) => (k.type === 'ambientOutOfRange' ? k.sustain : k.type === 'probeOffline' ? k.seconds : 0);
const latches = (k) => k.type === 'predictionDone' || k.type === 'restingDone';

/** overheat 3 > probe alarm 2 > prediction done 1 > other 0 (06 §7). */
export function priorityOf(source) {
  if (source.type === 'overheat') return 3;
  if (source.type === 'probeAlarm') return 2;
  if (source.type === 'rule' && latches(source.kind)) return 1;
  return 0;
}

/**
 * The sound for an alert (06 §17.3): 'ready', 'overheat', 'probeAlarm' (these loop until acknowledged),
 * 'countdown' (predictionWithin), 'problem' (offline, battery) and 'custom' (other rules) play once per firing.
 */
export function soundOf(source) {
  if (source.type === 'overheat') return 'overheat';
  if (source.type === 'probeAlarm') return 'probeAlarm';
  const t = source.kind.type;
  if (t === 'predictionDone' || t === 'restingDone') return 'ready';
  if (t === 'predictionWithin') return 'countdown';
  if (t === 'probeOffline' || t === 'batteryLow') return 'problem';
  return 'custom';
}

export const soundLoops = (sound) => sound === 'ready' || sound === 'overheat' || sound === 'probeAlarm';

/** The reading a channel stands for. Instant Read leaves only T1 valid. */
export function channelTemperature(channel, s) {
  if (channel === 'core') return s.virtual.core;
  if (channel === 'surface') return s.virtual.surface;
  if (channel === 'ambient') return s.virtual.ambient;
  return s.temperatures[SENSORS.indexOf(channel)] ?? null;
}

/** Without a prediction, a core above this is taken as "in food on the heat". */
const HOT_CORE = 40;

/** Out of Instant Read and either a prediction under way or clearly hot. Drives keep-awake and probeOffline. */
export function isCooking(s) {
  if (s.mode !== 'normal') return false;
  const state = s.prediction?.state;
  if (['inserted', 'warming', 'predicting', 'removalPredictionDone'].includes(state)) return true;
  return (s.virtual.core ?? 0) >= HOT_CORE;
}

/** One quantum of the countdown (15 s); keeps `predictionWithin` from flapping. */
const PREDICTION_HYSTERESIS = 15;

/**
 * Pure rule logic. Returns `{met, value, since}` or null for "cannot tell right now" (the alert keeps its state).
 * `i`: {snapshot, prediction, now, wasActive, cookActive, coreHistory}.
 */
export function evaluateRule(k, i) {
  const s = i.snapshot;
  switch (k.type) {
    case 'temperatureAbove': {
      const t = channelTemperature(k.channel, s);
      if (t == null) return null;
      return { met: i.wasActive ? t >= k.celsius - (k.hysteresis ?? 1) : t >= k.celsius, value: t };
    }
    case 'temperatureBelow': {
      const t = channelTemperature(k.channel, s);
      if (t == null) return null;
      return { met: i.wasActive ? t <= k.celsius + (k.hysteresis ?? 1) : t <= k.celsius, value: t };
    }
    case 'predictionWithin': {
      const p = i.prediction;
      if (!p || p.isStale) return null;
      if (p.secondsRemaining == null) return { met: false, value: null };
      const limit = i.wasActive ? k.seconds + PREDICTION_HYSTERESIS : k.seconds;
      return { met: p.secondsRemaining <= limit, value: p.secondsRemaining };
    }
    case 'predictionDone': {
      const p = i.prediction;
      if (!p) return null;
      return { met: p.state === 'removalPredictionDone' && p.type !== 'resting', value: null };
    }
    case 'restingDone': {
      const p = i.prediction;
      if (!p) return null;
      const done = p.type === 'resting'
        && (p.state === 'removalPredictionDone' || (p.state === 'predicting' && p.secondsRemaining === 0));
      return { met: done, value: null };
    }
    case 'ambientOutOfRange': {
      const a = s.virtual.ambient;
      if (s.mode !== 'normal' || a == null) return null;
      return { met: a < k.min || a > k.max, value: a };
    }
    case 'stall': {
      const core = s.virtual.core;
      if (core == null) return null;
      const predicting = (i.prediction?.state ?? s.prediction?.state) === 'predicting';
      if (!predicting) return { met: false, value: null };
      const window = (k.window ?? 1800) * 1000;
      const ref = [...i.coreHistory].reverse().find((c) => i.now - c.time >= window - 1000);
      if (!ref) return { met: false, value: null };
      const rise = core - ref.celsius;
      return { met: rise < k.minRise, value: rise };
    }
    case 'probeOffline':
      if (!s.isOffline) return { met: false, value: null };
      return { met: !k.onlyDuringCook || i.cookActive, value: null, since: s.receivedAt };
    case 'batteryLow':
      return { met: s.batteryLow, value: null };
    default:
      return null;
  }
}

/** Rule storage. The browser app passes a localStorage-backed one. */
export class MemoryRuleStore {
  #rules = new Map();
  async load(serial) { return this.#rules.get(serial) ?? null; }
  async save(serial, rules) { this.#rules.set(serial, structuredClone(rules)); }
}

const COOK_IDLE_MS = 600_000;
const MIN_HISTORY_MS = 3_600_000;
const HISTORY_STEP_MS = 4900;
const EPSILON_MS = 1;

export const alarmId = (serial, kind, channel) => `${serial}.alarm.${kind}.${channel}`;
export const overheatId = (serial, sensor) => `${serial}.overheat.${sensor}`;

/**
 * Emits `event` `{instance, from, to, at, failure}` per state change and `active` (sorted list) after each round.
 * Sinks (`deliver(event)`), keepAwake (`setHeld(bool)`) and silencer (`silenceAlarms(serial)`) are optional.
 */
export class AlertEngine extends Emitter {
  followed = new Set();
  ruleSets = new Map();
  snapshots = new Map();
  views = new Map();
  instances = new Map();
  #pending = new Map();
  #history = new Map();
  #cooks = new Map();
  #held = false;
  #wake = null;
  /**
   * Probe alarms a snooze silenced on the probe: they stay active while the alarm is still tripped (the probe no
   * longer says alarming), so the snooze can run out and fire again.
   */
  #snoozeSilenced = new Set();

  constructor({
    clock = systemClock, ruleStore = new MemoryRuleStore(), sinks = [], keepAwake = null, silencer = null,
    seedRules = defaultRules, cookIdleMs = COOK_IDLE_MS,
  } = {}) {
    super();
    Object.assign(this, { clock, ruleStore, sinks, keepAwake, silencer, seedRules, cookIdleMs });
  }

  /** Alerts firing, acknowledged or snoozed: most urgent first, newest first within a level. */
  activeAlerts() {
    return [...this.instances.values()].sort((a, b) =>
      priorityOf(b.source) - priorityOf(a.source) || b.firedAt - a.firedAt || a.id.localeCompare(b.id));
  }

  stop() {
    if (this.#wake != null) this.clock.clearTimeout(this.#wake);
    this.#wake = null;
    if (this.#held) {
      this.#held = false;
      this.keepAwake?.setHeld(false);
    }
  }

  // MARK: Rules

  async rules(serial) {
    await this.#loadRules(serial);
    return this.ruleSets.get(serial) ?? [];
  }

  async setRules(serial, rules) {
    await this.#loadRules(serial);
    const old = new Map((this.ruleSets.get(serial) ?? []).map((r) => [r.id, r]));
    const now = this.clock.now();
    for (const r of rules) {
      const prev = old.get(r.id);
      if (prev && (JSON.stringify(prev.kind) !== JSON.stringify(r.kind) || !r.enabled)) this.#transition(r.id, 'idle', now);
      old.delete(r.id);
    }
    for (const id of old.keys()) this.#transition(id, 'idle', now);
    this.ruleSets.set(serial, rules);
    await this.ruleStore.save(serial, rules);
    this.#evaluate(serial);
    this.#finishRound();
  }

  // MARK: Acknowledge, snooze, silence

  /** Stops the sound; a probe alarm also silences the probe (and its Display and phone). */
  async acknowledge(id) {
    const a = this.instances.get(id);
    if (!a || (a.state !== 'firing' && a.state !== 'snoozed')) return;
    this.#transition(id, 'acknowledged', this.clock.now());
    // An alert kept only by a snooze silence ends here if the probe already stopped alarming.
    if (this.#snoozeSilenced.delete(id)) this.#evaluate(a.serial);
    this.#finishRound();
    if (a.source.type === 'probeAlarm' && this.instances.has(id)) await this.#silenceProbe(a.serial, [id]);
  }

  /**
   * Mutes a firing alert for `ms`; it fires again then if the condition still holds. A probe alarm is also silenced on
   * the probe (so its Display and phone stop too); the alert is kept while the alarm stays tripped and fires again
   * when the snooze runs out. The probe stays quiet after that: it has no snooze.
   */
  async snooze(id, ms) {
    const a = this.instances.get(id);
    if (!a || a.state !== 'firing') return;
    const now = this.clock.now();
    a.snoozedUntil = now + ms;
    this.#transition(id, 'snoozed', now);
    this.#finishRound();
    if (a.source.type === 'probeAlarm') {
      this.#snoozeSilenced.add(id);
      await this.#silenceProbe(a.serial, [id]);
    }
  }

  /** Acknowledges everything firing; sends Silence Alarms to each probe with a probe alarm among them. */
  async silenceAll() {
    const now = this.clock.now();
    const firing = [...this.instances.values()].filter((a) => a.state === 'firing' || a.state === 'snoozed');
    for (const a of firing) this.#transition(a.id, 'acknowledged', now);
    this.#finishRound();
    const bySerial = new Map();
    for (const a of firing) {
      if (a.source.type === 'probeAlarm') bySerial.set(a.serial, [...(bySerial.get(a.serial) ?? []), a.id]);
    }
    for (const [serial, ids] of bySerial) await this.#silenceProbe(serial, ids);
  }

  async #silenceProbe(serial, ids) {
    if (!this.silencer) return;
    try {
      await this.silencer.silenceAlarms(serial);
    } catch (e) {
      // The probe is still alarming: the app must not stay quiet about it.
      const now = this.clock.now();
      for (const id of ids) {
        const state = this.instances.get(id)?.state;
        if (state === 'acknowledged' || state === 'snoozed') this.#transition(id, 'firing', now, String(e?.message ?? e));
      }
      this.#finishRound();
    }
  }

  // MARK: Inputs

  async setFollowed(serials) {
    const set = new Set(serials);
    const added = [...set].filter((s) => !this.followed.has(s)).sort();
    const removed = [...this.followed].filter((s) => !set.has(s));
    this.followed = set;
    for (const s of removed) this.#dropProbe(s);
    for (const s of added) await this.#loadRules(s, true);
    for (const s of added) this.#evaluate(s);
    this.#finishRound();
  }

  ingestSnapshots(map) {
    for (const [serial, snap] of map) {
      if (this.snapshots.get(serial) === snap) continue;
      this.snapshots.set(serial, snap);
      this.#recordCore(serial, snap);
      this.#evaluate(serial);
    }
    this.#finishRound();
  }

  ingestPrediction(view) {
    this.views.set(view.serial, view);
    this.#evaluate(view.serial);
    this.#finishRound();
  }

  // MARK: Evaluation

  async #loadRules(serial, seed = false) {
    if (this.ruleSets.has(serial)) return;
    const stored = await this.ruleStore.load(serial);
    if (stored) this.ruleSets.set(serial, stored);
    else if (seed && this.seedRules) {
      const rules = this.seedRules(serial);
      this.ruleSets.set(serial, rules);
      await this.ruleStore.save(serial, rules);
    } else this.ruleSets.set(serial, []);
  }

  #recordCore(serial, snap) {
    const core = snap.virtual.core;
    if (snap.isOffline || core == null) return;
    const now = this.clock.now();
    const samples = this.#history.get(serial) ?? [];
    const last = samples[samples.length - 1];
    if (last && now - last.time < HISTORY_STEP_MS) return;
    samples.push({ time: now, celsius: core });
    const longest = Math.max(0, ...(this.ruleSets.get(serial) ?? [])
      .filter((r) => r.kind.type === 'stall').map((r) => (r.kind.window ?? 1800) * 1000));
    const keep = Math.max(MIN_HISTORY_MS, longest + 60_000);
    const firstInSpan = samples.findIndex((c) => now - c.time <= keep);
    if (firstInSpan > 1) samples.splice(0, firstInSpan - 1);
    this.#history.set(serial, samples);
  }

  #evaluate(serial) {
    if (!this.followed.has(serial)) return;
    const snap = this.snapshots.get(serial);
    if (!snap) return;
    const now = this.clock.now();
    this.#updateCook(serial, snap, now);
    const desired = new Map();
    const unknown = new Set();

    for (const rule of this.ruleSets.get(serial) ?? []) {
      if (!rule.enabled) continue;
      const outcome = evaluateRule(rule.kind, {
        snapshot: snap, prediction: this.views.get(serial), now, wasActive: this.instances.has(rule.id),
        cookActive: this.#cooks.get(serial)?.active ?? false, coreHistory: this.#history.get(serial) ?? [],
      });
      if (outcome) {
        desired.set(rule.id, {
          source: { type: 'rule', kind: rule.kind }, outcome, sustain: sustainOf(rule.kind) * 1000, latch: latches(rule.kind),
        });
      } else unknown.add(rule.id);
    }

    // Probe alarms and overheat come from the probe's own status; without a source they say nothing current.
    const online = !snap.isOffline;
    if (snap.alarms) {
      for (const kind of ['high', 'low']) {
        for (const channel of ALARM_CHANNELS) {
          const a = snap.alarms[kind][channel];
          const id = alarmId(serial, kind, channel);
          if (!online || !a || !(a.alarming || (a.tripped && this.#snoozeSilenced.has(id)))) continue;
          desired.set(id, {
            source: { type: 'probeAlarm', kind, channel }, outcome: { met: true, value: a.temperature }, sustain: 0, latch: false,
          });
        }
      }
    } else {
      for (const [id, a] of this.instances) if (a.serial === serial && a.source.type === 'probeAlarm') unknown.add(id);
    }
    if (online) {
      for (const sensor of snap.overheating) {
        desired.set(overheatId(serial, sensor), {
          source: { type: 'overheat', sensor },
          outcome: { met: true, value: snap.temperatures[SENSORS.indexOf(sensor)] }, sustain: 0, latch: false,
        });
      }
    }

    for (const id of [...desired.keys()].sort()) this.#apply(id, serial, desired.get(id), now);
    for (const [id, a] of [...this.instances]) {
      if (a.serial !== serial || desired.has(id)) continue;
      if (unknown.has(id)) {
        if (a.state === 'snoozed' && now >= a.snoozedUntil) this.#refire(id, now);
      } else this.#transition(id, 'idle', now);
    }
    for (const id of [...this.#pending.keys()]) {
      if (id.startsWith(`${serial}.`) && !desired.has(id)) this.#pending.delete(id);
    }
  }

  #apply(id, serial, d, now) {
    const a = this.instances.get(id);
    if (d.outcome.met) {
      if (a) {
        if (d.outcome.value != null) a.value = d.outcome.value;
        if (a.state === 'snoozed' && now >= a.snoozedUntil) this.#refire(id, now);
        return;
      }
      const p = this.#pending.get(id) ?? { since: d.outcome.since ?? now };
      if (d.outcome.since != null) p.since = d.outcome.since;
      p.sustain = d.sustain;
      this.#pending.set(id, p);
      if (now - p.since < d.sustain - EPSILON_MS) return;
      this.#pending.delete(id);
      this.instances.set(id, {
        id, serial, source: d.source, state: 'idle', firedAt: now, acknowledgedAt: null, snoozedUntil: null,
        value: d.outcome.value ?? null,
      });
      this.#transition(id, 'firing', now);
    } else {
      this.#pending.delete(id);
      if (!a) return;
      // A latched alert outlives its condition until someone acknowledges it.
      if (d.latch && (a.state === 'firing' || a.state === 'snoozed')) {
        if (a.state === 'snoozed' && now >= a.snoozedUntil) this.#refire(id, now);
        return;
      }
      this.#transition(id, 'idle', now);
    }
  }

  #refire(id, now) {
    this.instances.get(id).snoozedUntil = null;
    this.#transition(id, 'firing', now);
  }

  #transition(id, to, now, failure = null) {
    const a = this.instances.get(id);
    if (!a || a.state === to) return;
    const from = a.state;
    a.state = to;
    if (to === 'firing') {
      if (from === 'idle') a.firedAt = now;
      a.snoozedUntil = null;
    } else if (to === 'acknowledged') {
      a.acknowledgedAt = now;
      a.snoozedUntil = null;
    }
    if (to === 'idle') {
      this.instances.delete(id);
      this.#snoozeSilenced.delete(id);
    }
    const event = { instance: { ...a }, from, to, at: now, failure };
    this.emit('event', event);
    for (const sink of this.sinks) {
      try {
        sink.deliver(event);
      } catch (e) {
        console.error('alert sink failed', e);
      }
    }
  }

  #dropProbe(serial) {
    const now = this.clock.now();
    for (const [id, a] of [...this.instances]) if (a.serial === serial) this.#transition(id, 'idle', now);
    for (const id of [...this.#pending.keys()]) if (id.startsWith(`${serial}.`)) this.#pending.delete(id);
    this.#cooks.delete(serial);
    this.#history.delete(serial);
  }

  #updateCook(serial, snap, now) {
    const c = this.#cooks.get(serial) ?? { active: false, lastActive: null };
    if (!snap.isOffline) {
      c.active = isCooking(snap);
      if (c.active) c.lastActive = now;
    } else if (c.active && c.lastActive != null && now - c.lastActive >= this.cookIdleMs - EPSILON_MS) {
      c.active = false;
    }
    this.#cooks.set(serial, c);
  }

  /** After a round: publish the active list, update keep-awake, set the next wake-up. */
  #finishRound() {
    this.emit('active', this.activeAlerts());
    this.#scheduleWake();
    const want = [...this.followed].some((s) => this.#cooks.get(s)?.active);
    if (want !== this.#held) {
      this.#held = want;
      this.keepAwake?.setHeld(want);
    }
  }

  /** One timer for the earliest of: a sustain about to be met, a snooze ending, a quiet cook that stops counting. */
  #scheduleWake() {
    if (this.#wake != null) this.clock.clearTimeout(this.#wake);
    this.#wake = null;
    const now = this.clock.now();
    const times = [...this.#pending.values()].map((p) => p.since + p.sustain);
    for (const a of this.instances.values()) if (a.state === 'snoozed') times.push(a.snoozedUntil);
    for (const [serial, c] of this.#cooks) {
      if (c.active && this.snapshots.get(serial)?.isOffline && c.lastActive != null) times.push(c.lastActive + this.cookIdleMs);
    }
    const future = times.filter((t) => t > now);
    if (!future.length) return;
    const delay = Math.max(Math.min(...future) - now, 1);
    this.#wake = this.clock.setTimeout(() => {
      this.#wake = null;
      for (const s of [...this.followed].sort()) this.#evaluate(s);
      this.#finishRound();
    }, delay);
  }
}
