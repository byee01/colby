// In-browser simulated probes and MeatNet node, speaking the real wire format through the codec. Used for demo mode
// (no hardware) and end-to-end tests. Loosely follows mac/Sources/CombustionSim (SimulatedProbe, SimulatedNode).

import { systemClock } from '../core/support.js';
import {
  encodeProbeStatus, encodeNodeProbeStatus, encodeResponse, encodeFrame, decodeRequest, UartFramer, unsetAlarm,
  ALARM_CHANNELS, SENSORS, MessageType,
} from '../codec/index.js';
import { GATT } from './gatt.js';

const text = (s) => Array.from(new TextEncoder().encode(s));

/**
 * A cook curve: core approaches `asymptote` exponentially, ambient holds an oven temperature with a small wobble.
 * Returns 8 temperatures for `t` seconds into the cook.
 */
export function cookCurve({ start = 4, asymptote = 112, tauHours = 3, oven = 121 } = {}) {
  const tau = tauHours * 3600;
  return {
    core: (t) => start + (asymptote - start) * (1 - Math.exp(-Math.max(0, t) / tau)),
    /** Seconds from cook start until the core reaches `c` (Infinity if never). */
    timeTo: (c) => (c >= asymptote ? Infinity : c <= start ? 0 : -tau * Math.log(1 - (c - start) / (asymptote - start))),
    temps(t) {
      const warm = Math.min(1, Math.max(0, t) / 600);
      const ambient = 20 + (oven - 20) * warm + 2.5 * Math.sin(t / 300);
      const core = this.core(t);
      const surface = core + (ambient - core) * 0.35;
      return [core + 1, core, core + 3, core + (surface - core) * 0.5, surface,
        surface + (ambient - surface) * 0.4, surface + (ambient - surface) * 0.75, ambient]
        .map((c) => Math.round(Math.min(369, Math.max(-20, c)) * 20) / 20);
    },
  };
}

/** One virtual probe: logs every `samplePeriodMs` since `startedAt`, answers UART requests, keeps alarms. */
export class SimProbe {
  constructor({
    serial, probeNumber = 1, color = 'yellow', sessionId = 0x1a2b3c4d, samplePeriodMs = 5000, clock = systemClock,
    startedAt = clock.now(), curve = cookCurve(), setpoint = null, mode = 'none',
  }) {
    Object.assign(this, { serial, probeNumber, color, sessionId, samplePeriodMs, clock, startedAt, curve });
    this.virtualSensors = { core: 't2', surface: 't5', ambient: 't8' };
    this.prediction = { mode, setpoint: setpoint ?? 0 };
    this.alarms = { high: {}, low: {} };
    this.silenced = new Set();
  }

  elapsed(time = this.clock.now()) { return (time - this.startedAt) / 1000; }

  logRange(time = this.clock.now()) {
    return { min: 0, max: Math.max(0, Math.floor((time - this.startedAt) / this.samplePeriodMs)) };
  }

  temperaturesAt(seq) { return this.curve.temps((seq * this.samplePeriodMs) / 1000); }

  #predictionAt(t) {
    const { mode, setpoint } = this.prediction;
    const core = this.curve.core(t);
    const heatStart = Math.round(this.curve.core(0) * 10) / 10;
    const base = {
      mode, type: mode === 'none' ? 'none' : 'removal', setpoint: mode === 'none' ? 0 : setpoint,
      heatStart: mode === 'none' ? 0 : heatStart, rawSecondsRemaining: 0,
      estimatedCore: Math.round(Math.min(184, core) * 10) / 10,
    };
    if (mode === 'none') return { ...base, state: core > 25 ? 'inserted' : 'notInserted' };
    if (core >= setpoint) return { ...base, state: 'removalPredictionDone' };
    if (t < 300) return { ...base, state: 'warming' };
    const left = Math.min(0x1ffff, Math.round(this.curve.timeTo(setpoint) - t));
    return { ...base, state: 'predicting', rawSecondsRemaining: Number.isFinite(left) ? left : 0x1ffff };
  }

  #alarmsFor(temps) {
    const byChannel = (ch) => {
      if (ch === 'core' || ch === 'surface' || ch === 'ambient') return temps[SENSORS.indexOf(this.virtualSensors[ch])];
      return temps[SENSORS.indexOf(ch)];
    };
    const side = (kind) => Object.fromEntries(ALARM_CHANNELS.map((ch) => {
      const a = this.alarms[kind][ch];
      if (!a?.set) return [ch, unsetAlarm()];
      const t = byChannel(ch);
      const tripped = kind === 'high' ? t >= a.temperature : t <= a.temperature;
      if (!tripped) this.silenced.delete(`${kind}.${ch}`);
      return [ch, { set: true, temperature: a.temperature, tripped, alarming: tripped && !this.silenced.has(`${kind}.${ch}`) }];
    }));
    return { high: side('high'), low: side('low') };
  }

  /** The full status at `time`, as a decoded payload. */
  status(time = this.clock.now()) {
    const range = this.logRange(time);
    const temps = this.curve.temps(this.elapsed(time));
    return {
      logRange: range,
      temperatures: temps,
      mode: 'normal',
      color: this.color,
      probeNumber: this.probeNumber,
      batteryLow: false,
      virtualSensors: this.virtualSensors,
      prediction: this.#predictionAt(this.elapsed(time)),
      foodSafe: {
        mode: 'simplified', product: 0, serving: 'servedImmediately', thresholdTemp: null, zValue: null,
        referenceTemp: null, dValue: null, targetLogReduction: 0, state: 'notSafe', logReduction: 0,
        secondsAboveThreshold: 0, logSequence: 0,
      },
      overheating: [],
      preferences: { powerMode: 'normal', highRadioPower: false },
      alarms: this.#alarmsFor(temps),
      session: { sessionId: this.sessionId, samplePeriodMs: this.samplePeriodMs },
    };
  }

  logRecord(seq) {
    const t = (seq * this.samplePeriodMs) / 1000;
    const p = this.#predictionAt(t);
    return {
      sequence: seq,
      temperatures: this.temperaturesAt(seq),
      prediction: {
        virtualSensors: this.virtualSensors, state: p.state, mode: p.mode, type: p.type, setpoint: p.setpoint,
        rawSecondsRemaining: p.rawSecondsRemaining, estimatedCore: p.estimatedCore,
      },
    };
  }

  /** Applies a decoded request; returns response bodies (several for readLogs). */
  handle(request) {
    switch (request.type) {
      case 'readSessionInfo':
        return [{ type: 'sessionInfo', sessionId: this.sessionId, samplePeriodMs: this.samplePeriodMs }];
      case 'readLogs': {
        const { max } = this.logRange();
        const out = [];
        for (let s = request.start; s <= Math.min(request.end, max); s++) out.push({ type: 'logRecord', ...this.logRecord(s) });
        return out;
      }
      case 'setPrediction':
        this.prediction = { mode: request.mode, setpoint: request.setpoint };
        return [{ type: 'ack' }];
      case 'setAlarms':
        this.alarms = { high: request.high, low: request.low };
        this.silenced.clear();
        return [{ type: 'ack' }];
      case 'silenceAlarms': {
        const a = this.#alarmsFor(this.curve.temps(this.elapsed()));
        for (const kind of ['high', 'low']) {
          for (const ch of ALARM_CHANNELS) if (a[kind][ch].alarming) this.silenced.add(`${kind}.${ch}`);
        }
        return [{ type: 'ack' }];
      }
      case 'readProbeFirmware': return [{ type: 'revision', kind: 'firmware', text: 'v2.4.0' }];
      case 'readProbeHardware': return [{ type: 'revision', kind: 'hardware', text: 'v1.2' }];
      case 'readProbeModel': return [{ type: 'revision', kind: 'model', text: 'Predictive Probe' }];
      default:
        return [{ type: 'ack', success: false }];
    }
  }
}

/** Base for simulated GATT connections: subscriptions, disconnect, chunked notifications. */
class SimConnection {
  mtu = 185;
  #subs = new Map();
  #disconnectHandlers = new Set();
  #timers = [];
  closed = false;

  constructor(id, name, clock, characteristics, info) {
    Object.assign(this, { id, name, clock, characteristics: new Set(characteristics), info });
  }

  async discover() { return this.characteristics; }

  async read(uuid) {
    if (this.closed) throw new Error('disconnected');
    const value = this.info[uuid];
    if (value == null) throw new Error(`no characteristic ${uuid}`);
    return text(value);
  }

  async subscribe(uuid, fn) {
    if (!this.characteristics.has(uuid)) throw new Error(`no characteristic ${uuid}`);
    if (!this.#subs.has(uuid)) this.#subs.set(uuid, new Set());
    this.#subs.get(uuid).add(fn);
    return () => this.#subs.get(uuid)?.delete(fn);
  }

  notify(uuid, bytes) {
    if (this.closed) return;
    const chunk = this.mtu - 3;
    for (let i = 0; i < bytes.length; i += chunk) {
      for (const fn of [...(this.#subs.get(uuid) ?? [])]) fn(Uint8Array.from(bytes.slice(i, i + chunk)));
    }
  }

  every(ms, fn) { this.#timers.push(this.clock.setInterval(fn, ms)); }

  onDisconnect(fn) {
    this.#disconnectHandlers.add(fn);
    return () => this.#disconnectHandlers.delete(fn);
  }

  /** Simulates link loss (out of range). */
  drop(reason = 'linkLost') {
    if (this.closed) return;
    this.closed = true;
    for (const t of this.#timers) this.clock.clearInterval(t);
    for (const fn of [...this.#disconnectHandlers]) fn(reason);
  }

  async close() { this.drop('requested'); }
}

/** A direct connection to a SimProbe: Probe Status notifications plus the probe UART. */
export class SimProbeConnection extends SimConnection {
  #framer = new UartFramer('probe', 'request');

  constructor(probe) {
    super(`sim-probe-${probe.serial}`, `Probe ${probe.serial}`, probe.clock,
      [GATT.probeStatus, GATT.uartRX, GATT.uartTX, GATT.firmwareRevision, GATT.serialNumber, GATT.modelNumber],
      { [GATT.firmwareRevision]: 'v2.4.0', [GATT.serialNumber]: probe.serial, [GATT.modelNumber]: 'Predictive Probe' });
    this.probe = probe;
    this.every(probe.samplePeriodMs, () => this.notify(GATT.probeStatus, encodeProbeStatus(probe.status())));
  }

  async write(uuid, bytes) {
    if (this.closed) throw new Error('disconnected');
    if (uuid !== GATT.uartRX) return;
    for (const o of this.#framer.push(bytes)) {
      if (!o.frame) continue;
      const { request } = decodeRequest(o.frame);
      const type = o.frame.messageType;
      // Answer after the write completes, as a real probe would.
      this.clock.setTimeout(() => {
        for (const body of this.probe.handle(request)) {
          const success = body.success !== false;
          this.notify(GATT.uartTX, encodeResponse({ messageType: type, success, body: success ? body : { type: 'ack' } }, 'probe'));
        }
        if (type !== MessageType.readLogs && type !== MessageType.readSessionInfo) {
          this.notify(GATT.probeStatus, encodeProbeStatus(this.probe.status()));
        }
      }, 20);
    }
  }
}

/** A MeatNet node relaying SimProbes: 0x45 per probe per sample, 0x49 heartbeats, node UART requests. */
export class SimNodeConnection extends SimConnection {
  #framer = new UartFramer('node');
  #nextResponseId = 1;

  constructor({ serial = 'DISPLAY01', probes, clock = systemClock, hops = 1 }) {
    super(`sim-node-${serial}`, `Display ${serial}`, clock,
      [GATT.uartRX, GATT.uartTX, GATT.firmwareRevision, GATT.modelNumber, GATT.serialNumber],
      { [GATT.firmwareRevision]: 'v3.1.0', [GATT.modelNumber]: 'Display', [GATT.serialNumber]: serial });
    Object.assign(this, { serial, probes, hops });
    const period = probes[0]?.samplePeriodMs ?? 5000;
    this.every(period, () => {
      for (const p of this.probes) this.#sendStatus(p);
    });
    this.every(5000, () => this.notify(GATT.uartTX, encodeFrame({
      variant: 'node', direction: 'request', messageType: MessageType.heartbeat, requestId: this.#id(), payload: [0, 0, 0, 0],
    })));
  }

  #id() { return (Math.random() * 2 ** 32) >>> 0; }

  #sendStatus(p) {
    const payload = encodeNodeProbeStatus({ probeSerial: p.serial, hopCount: this.hops, status: p.status() });
    this.notify(GATT.uartTX, encodeFrame({
      variant: 'node', direction: 'request', messageType: MessageType.probeStatus, requestId: this.#id(), payload,
    }));
  }

  async write(uuid, bytes) {
    if (this.closed) throw new Error('disconnected');
    if (uuid !== GATT.uartRX) return;
    for (const o of this.#framer.push(bytes)) {
      if (!o.frame || o.frame.direction !== 'request') continue;
      const { probe: serial, request, requestId } = decodeRequest(o.frame);
      const probe = this.probes.find((p) => p.serial === serial);
      const type = o.frame.messageType;
      this.clock.setTimeout(() => {
        const bodies = probe ? probe.handle(request) : [{ type: 'ack', success: false }];
        for (const body of bodies) {
          const success = body.success !== false;
          this.notify(GATT.uartTX, encodeResponse({
            messageType: type, success, requestId, responseId: this.#nextResponseId++,
            body: success ? { ...body, probe: serial } : { type: 'ack' },
          }, 'node'));
        }
        if (probe && type !== MessageType.readLogs && type !== MessageType.readSessionInfo) this.#sendStatus(probe);
      }, 30);
    }
  }
}
