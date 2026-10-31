// Set prediction, set alarms, silence alarms. Port of Commands.swift (docs/02 §8).
//
// Every command is confirmed by the next status, not by the UART ack alone: after the ack it waits up to
// `confirmMs` for a status showing the new value, else fails with `notConfirmed`. Commands for one probe run one at a
// time (two setAlarm calls cannot overwrite each other's read-modify-write).

import { systemClock } from './support.js';
import { UartError } from './uartClient.js';
import { ALARM_CHANNELS, ALARM_MIN, ALARM_MAX, MAX_PREDICTION_SETPOINT, unsetAlarm } from '../codec/index.js';

/** kind: 'notReachable' | 'outOfRange' | 'alarmStateUnknown' | 'notConfirmed' | 'uart'. */
export class CommandError extends Error {
  constructor(kind, detail) {
    super(detail ? `${kind}: ${detail}` : kind);
    this.name = 'CommandError';
    this.kind = kind;
    this.detail = detail;
  }
}

/** Probe resolution is 0.1 °C and the codec rounds to it. */
const TOLERANCE = 0.06;

const clean = (config) => {
  const strip = (side) => Object.fromEntries(ALARM_CHANNELS.map((ch) => {
    const a = side?.[ch] ?? unsetAlarm();
    return [ch, { set: a.set, temperature: a.temperature, tripped: false, alarming: false }];
  }));
  return { high: strip(config.high), low: strip(config.low) };
};

function matches(reported, wanted) {
  if (!reported) return false;
  const same = (got, want) => ALARM_CHANNELS.every((ch) => {
    const w = want[ch] ?? unsetAlarm();
    const g = got[ch];
    if (!g) return !w.set;
    return g.set === w.set && (!w.set || Math.abs(g.temperature - w.temperature) < TOLERANCE);
  });
  return same(reported.high, wanted.high) && same(reported.low, wanted.low);
}

function validateAlarm(value, field) {
  if (!(Number.isFinite(value) && value >= ALARM_MIN && value <= ALARM_MAX)) throw new CommandError('outOfRange', field);
}

export class Commands {
  #chains = new Map();

  /**
   * @param {object} deps
   * @param {import('./probeStore.js').ProbeStore} deps.store
   * @param {(serial: string) => ({send: Function} | null)} deps.route  direct link, else node link, else null
   */
  constructor({ store, route, clock = systemClock, commandMs = 3000, confirmMs = 5000 }) {
    this.store = store;
    this.route = route;
    this.clock = clock;
    this.commandMs = commandMs;
    this.confirmMs = confirmMs;
  }

  /** `mode` is 'timeToRemoval' or 'removalAndResting'; set point 0...102.3 °C. */
  setPrediction(serial, mode, setpoint) {
    if (mode !== 'timeToRemoval' && mode !== 'removalAndResting') return Promise.reject(new CommandError('outOfRange', 'mode'));
    if (!(Number.isFinite(setpoint) && setpoint >= 0 && setpoint <= MAX_PREDICTION_SETPOINT)) {
      return Promise.reject(new CommandError('outOfRange', 'setpoint'));
    }
    return this.#exclusive(serial, () => this.#send(serial, { type: 'setPrediction', setpoint, mode },
      (s) => s.prediction.mode === mode && Math.abs(s.prediction.setpoint - setpoint) < TOLERANCE));
  }

  cancelPrediction(serial) {
    return this.#exclusive(serial, () => this.#send(serial, { type: 'setPrediction', setpoint: 0, mode: 'none' },
      (s) => s.prediction.mode === 'none'));
  }

  /** Sets or clears (temperature null) one alarm, keeping the other 21 as the probe has them. */
  setAlarm(serial, channel, kind, temperature) {
    if (temperature != null) {
      try {
        validateAlarm(temperature, 'temperature');
      } catch (e) {
        return Promise.reject(e);
      }
    }
    return this.#exclusive(serial, async () => {
      const current = this.store.snapshot(serial)?.alarms;
      if (!current) throw new CommandError('alarmStateUnknown');
      const config = clean(current);
      config[kind][channel] = temperature == null
        ? unsetAlarm()
        : { set: true, temperature, tripped: false, alarming: false };
      await this.#send(serial, { type: 'setAlarms', ...config }, (s) => matches(s.alarms, config));
    });
  }

  /** Silences every alarming alarm on the probe (and its Display and phone). Overheat is not silenced. */
  silenceAlarms(serial) {
    return this.#exclusive(serial, () => this.#send(serial, { type: 'silenceAlarms' }, (s) =>
      s.alarms != null && ![...Object.values(s.alarms.high), ...Object.values(s.alarms.low)].some((a) => a.alarming)));
  }

  async #send(serial, request, confirmed) {
    const link = this.route(serial);
    if (!link) throw new CommandError('notReachable');
    // Listen before sending: the confirming status can arrive before the ack does.
    const confirmation = this.store.once('status', {
      filter: (e) => e.serial === serial && confirmed(e.status), timeoutMs: this.confirmMs, clock: this.clock,
    });
    try {
      await link.send(request, serial, this.commandMs);
    } catch (e) {
      throw e instanceof UartError ? new CommandError('uart', e.kind) : e;
    }
    if (!(await confirmation)) throw new CommandError('notConfirmed');
  }

  #exclusive(serial, body) {
    const prev = this.#chains.get(serial) ?? Promise.resolve();
    const run = prev.then(body, body);
    const tail = run.catch(() => {});
    this.#chains.set(serial, tail);
    tail.then(() => {
      if (this.#chains.get(serial) === tail) this.#chains.delete(serial);
    });
    return run;
  }
}
