// Packed fields shared by advertisements, statuses and UART messages.
// Port of Temperatures.swift, Identifiers.swift, Alarms.swift, Prediction.swift, FoodSafe.swift.
// Values use the fixture JSON shape (spec/fixtures/README.md): enums are strings, temperatures are °C numbers.

import { BitReader, BitWriter, CodecError, u16, pushU16, scaledRaw } from './bytes.js';

export const SENSORS = ['t1', 't2', 't3', 't4', 't5', 't6', 't7', 't8'];
export const ALARM_CHANNELS = [...SENSORS, 'core', 'surface', 'ambient'];

// MARK: Temperatures (13 bytes, 8 × 13 bit, °C = raw × 0.05 − 20)

export const TEMPERATURES_SIZE = 13;
export const tempFromRaw = (raw) => raw / 20 - 20;

export function unpackTemperatures(bytes) {
  const r = new BitReader(bytes);
  return SENSORS.map(() => tempFromRaw(r.read(13)));
}

export function packTemperatures(celsius) {
  if (celsius.length !== 8) throw CodecError.outOfRange('temperatures.count', celsius.length);
  const w = new BitWriter(TEMPERATURES_SIZE);
  for (const c of celsius) w.write(scaledRaw(c, 'temperature', { offset: 20, scale: 20, max: 0x1fff }), 13);
  return w.bytes;
}

// MARK: Virtual sensors (7 bits: core 3, surface 2, ambient 2)

/** Core values 6 and 7 are undefined; like the Android SDK they read as T1. */
export function virtualSensorsFromBits(bits) {
  const core = bits & 0b111;
  return {
    core: SENSORS[core <= 5 ? core : 0],
    surface: SENSORS[((bits >> 3) & 0b11) + 3],
    ambient: SENSORS[((bits >> 5) & 0b11) + 4],
  };
}

export function virtualSensorsToBits(v) {
  const core = SENSORS.indexOf(v.core);
  const surface = SENSORS.indexOf(v.surface);
  const ambient = SENSORS.indexOf(v.ambient);
  if (core < 0 || core > 5) throw CodecError.outOfRange('virtualSensors.core', core);
  if (surface < 3 || surface > 6) throw CodecError.outOfRange('virtualSensors.surface', surface);
  if (ambient < 4) throw CodecError.outOfRange('virtualSensors.ambient', ambient);
  return core | ((surface - 3) << 3) | ((ambient - 4) << 5);
}

// MARK: Mode / ID byte (mode 2 bits, color 3, probe ID 3)

const MODES = ['normal', 'instantRead', 'reserved', 'error'];

const colorName = (raw) => (raw === 0 ? 'yellow' : raw === 1 ? 'grey' : `unknown(${raw})`);

function colorRaw(name) {
  if (name === 'yellow') return 0;
  if (name === 'grey') return 1;
  const m = /^unknown\((\d+)\)$/.exec(name ?? '');
  const raw = m ? Number(m[1]) : NaN;
  if (!(raw >= 0 && raw <= 7)) throw CodecError.outOfRange('color', raw);
  return raw;
}

export function decodeModeAndId(byte) {
  return { mode: MODES[byte & 0b11], color: colorName((byte >> 2) & 0b111), probeNumber: (byte >> 5) + 1 };
}

export function encodeModeAndId({ mode, color, probeNumber }) {
  if (!(probeNumber >= 1 && probeNumber <= 8)) throw CodecError.outOfRange('probeNumber', probeNumber);
  const m = MODES.indexOf(mode);
  if (m < 0) throw CodecError.outOfRange('mode', m);
  return m | (colorRaw(color) << 2) | ((probeNumber - 1) << 5);
}

// MARK: Thermometer preferences (power mode 2 bits, high radio power 1 bit)

export function decodePreferences(byte) {
  const p = byte & 0b11;
  return {
    powerMode: p === 0 ? 'normal' : p === 1 ? 'alwaysOn' : `reserved(${p})`,
    highRadioPower: (byte & 0b100) !== 0,
  };
}

export function encodePreferences({ powerMode, highRadioPower }) {
  let p = 0;
  if (powerMode === 'alwaysOn') p = 1;
  else if (powerMode !== 'normal') p = Number(/\d+/.exec(powerMode ?? '')?.[0] ?? 0) & 0b11;
  return p | (highRadioPower ? 0b100 : 0);
}

// MARK: Overheat mask (bit n = sensor T(n+1))

export const decodeOverheat = (byte) => SENSORS.filter((_, i) => byte & (1 << i));
export const encodeOverheat = (sensors) => sensors.reduce((acc, s) => acc | (1 << SENSORS.indexOf(s)), 0);

// MARK: Alarms (u16 each: set, tripped, alarming, 13-bit temperature raw × 0.1 − 20)

export const ALARMS_SIZE = 44;
export const ALARM_MIN = -20;
export const ALARM_MAX = 799;
export const unsetAlarm = () => ({ set: false, tripped: false, alarming: false, temperature: -20 });

function decodeAlarm(word) {
  return {
    set: (word & 1) !== 0,
    tripped: (word & 2) !== 0,
    alarming: (word & 4) !== 0,
    temperature: (word >> 3) / 10 - 20,
  };
}

function encodeAlarm(a, field) {
  if (!(a.temperature >= ALARM_MIN && a.temperature <= ALARM_MAX)) throw CodecError.outOfRange(field, a.temperature);
  const raw = scaledRaw(a.temperature, field, { offset: 20, scale: 10, max: 0x1fff });
  return (raw << 3) | (a.set ? 1 : 0) | (a.tripped ? 2 : 0) | (a.alarming ? 4 : 0);
}

/** 44 bytes: 11 high words then 11 low words. Every channel is filled. */
export function unpackAlarms(bytes) {
  const side = (start) =>
    Object.fromEntries(ALARM_CHANNELS.map((ch, i) => [ch, decodeAlarm(u16(bytes, start + i * 2))]));
  return { high: side(0), low: side(22) };
}

/** A channel missing from `config.high`/`config.low` is sent unset. */
export function packAlarms(config) {
  const out = [];
  for (const kind of ['high', 'low']) {
    for (const ch of ALARM_CHANNELS) {
      pushU16(out, encodeAlarm(config[kind]?.[ch] ?? unsetAlarm(), `alarm.${kind}.${ch}`));
    }
  }
  return out;
}

// MARK: Prediction

const PREDICTION_STATES = ['notInserted', 'inserted', 'warming', 'predicting', 'removalPredictionDone'];
export const PREDICTION_MODES = ['none', 'timeToRemoval', 'removalAndResting', 'reserved'];
const PREDICTION_TYPES = ['none', 'removal', 'resting', 'reserved'];

/** Largest prediction set point: 10 bits of 0.1 °C. */
export const MAX_PREDICTION_SETPOINT = 102.3;
export const PREDICTION_SIZE = 7;

const stateName = (raw) => PREDICTION_STATES[raw] ?? 'unknown';
const stateRaw = (name) => {
  const i = PREDICTION_STATES.indexOf(name);
  return i < 0 ? 15 : i;
};

function enumRaw(list, name, field) {
  const i = list.indexOf(name);
  if (i < 0) throw CodecError.outOfRange(field, i);
  return i;
}

const tenths = (value, field, offset, max) => scaledRaw(value, field, { offset, scale: 10, max });

/** Prediction status, 7 bytes: state 4, mode 2, type 2, set point 10, heat start 10, seconds 17, core 11 bits. */
export function unpackPrediction(bytes) {
  const r = new BitReader(bytes);
  return {
    state: stateName(r.read(4)),
    mode: PREDICTION_MODES[r.read(2)],
    type: PREDICTION_TYPES[r.read(2)],
    setpoint: r.read(10) / 10,
    heatStart: r.read(10) / 10,
    rawSecondsRemaining: r.read(17),
    estimatedCore: r.read(11) / 10 - 20,
  };
}

export function packPrediction(p) {
  const w = new BitWriter(PREDICTION_SIZE);
  w.write(stateRaw(p.state), 4);
  w.write(enumRaw(PREDICTION_MODES, p.mode, 'prediction.mode'), 2);
  w.write(enumRaw(PREDICTION_TYPES, p.type, 'prediction.type'), 2);
  w.write(tenths(p.setpoint, 'prediction.setpoint', 0, 1023), 10);
  w.write(tenths(p.heatStart, 'prediction.heatStart', 0, 1023), 10);
  if (!(p.rawSecondsRemaining >= 0 && p.rawSecondsRemaining <= 0x1ffff)) {
    throw CodecError.outOfRange('prediction.seconds', p.rawSecondsRemaining);
  }
  w.write(p.rawSecondsRemaining, 17);
  w.write(tenths(p.estimatedCore, 'prediction.estimatedCore', 20, 2047), 11);
  return w.bytes;
}

/** `(estCore − heatStart) / (setpoint − heatStart)` as 0...100, null when the span is not positive. */
export function percentToRemoval(p) {
  const span = p.setpoint - p.heatStart;
  if (!(span > 0)) return null;
  return Math.min(100, Math.max(0, ((p.estimatedCore - p.heatStart) / span) * 100));
}

/** Prediction log inside log records: virtual sensors 7, state 4, mode 2, type 2, set point 10, seconds 17, core 11. */
export function unpackPredictionLog(bytes) {
  const r = new BitReader(bytes);
  return {
    virtualSensors: virtualSensorsFromBits(r.read(7)),
    state: stateName(r.read(4)),
    mode: PREDICTION_MODES[r.read(2)],
    type: PREDICTION_TYPES[r.read(2)],
    setpoint: r.read(10) / 10,
    rawSecondsRemaining: r.read(17),
    estimatedCore: r.read(11) / 10 - 20,
  };
}

export function packPredictionLog(p) {
  const w = new BitWriter(PREDICTION_SIZE);
  w.write(virtualSensorsToBits(p.virtualSensors), 7);
  w.write(stateRaw(p.state), 4);
  w.write(enumRaw(PREDICTION_MODES, p.mode, 'predictionLog.mode'), 2);
  w.write(enumRaw(PREDICTION_TYPES, p.type, 'predictionLog.type'), 2);
  w.write(tenths(p.setpoint, 'predictionLog.setpoint', 0, 1023), 10);
  if (!(p.rawSecondsRemaining >= 0 && p.rawSecondsRemaining <= 0x1ffff)) {
    throw CodecError.outOfRange('predictionLog.seconds', p.rawSecondsRemaining);
  }
  w.write(p.rawSecondsRemaining, 17);
  w.write(tenths(p.estimatedCore, 'predictionLog.estimatedCore', 20, 2047), 11);
  return w.bytes;
}

/** Set Prediction Data, u16: set point 10 bits (0.1 °C), mode 2 bits. */
export function encodeSetPredictionData(setpoint, mode) {
  const m = PREDICTION_MODES.indexOf(mode);
  if (m < 0 || mode === 'reserved') throw CodecError.outOfRange('prediction.mode', m);
  return tenths(setpoint, 'prediction.setpoint', 0, 1023) | (m << 10);
}

export const decodeSetPredictionData = (value) => ({
  setpoint: (value & 0x3ff) / 10,
  mode: PREDICTION_MODES[(value >> 10) & 0b11],
});

// MARK: Food safe (data 10 B + status 8 B), read-only in v1

export const FOOD_SAFE_DATA_SIZE = 10;
export const FOOD_SAFE_STATUS_SIZE = 8;
const FOOD_SAFE_STATES = ['notSafe', 'safe', 'safetyImpossible'];

/** Returns null for reserved mode, serving or state values (like the Android SDK). */
export function unpackFoodSafe(data, status) {
  const d = new BitReader(data);
  const mode = d.read(3);
  const product = d.read(10);
  const serving = d.read(3);
  const threshold = d.read(13) * 0.05;
  const z = d.read(13) * 0.05;
  const reference = d.read(13) * 0.05;
  const dValue = d.read(13) * 0.05;
  const target = d.read(8) / 10;
  const s = new BitReader(status);
  const state = s.read(3);
  const reduction = s.read(8) / 10;
  const seconds = s.read(16);
  const sequence = s.read(32);
  if (mode > 1 || serving > 1 || state > 2) return null;
  const integrated = mode === 1;
  return {
    mode: integrated ? 'integrated' : 'simplified',
    product,
    serving: serving === 0 ? 'servedImmediately' : 'cookedAndChilled',
    thresholdTemp: integrated ? threshold : null,
    zValue: integrated ? z : null,
    referenceTemp: integrated ? reference : null,
    dValue: integrated ? dValue : null,
    targetLogReduction: target,
    state: FOOD_SAFE_STATES[state],
    logReduction: reduction,
    secondsAboveThreshold: seconds,
    logSequence: sequence,
  };
}

export function packFoodSafe(f) {
  const fine = (v, field) => scaledRaw(v ?? 0, field, { scale: 20, max: 0x1fff });
  if (!(f.product >= 0 && f.product <= 0x3ff)) throw CodecError.outOfRange('foodSafe.product', f.product);
  const d = new BitWriter(FOOD_SAFE_DATA_SIZE);
  d.write(f.mode === 'simplified' ? 0 : 1, 3);
  d.write(f.product, 10);
  d.write(f.serving === 'servedImmediately' ? 0 : 1, 3);
  d.write(fine(f.thresholdTemp, 'foodSafe.thresholdTemp'), 13);
  d.write(fine(f.zValue, 'foodSafe.zValue'), 13);
  d.write(fine(f.referenceTemp, 'foodSafe.referenceTemp'), 13);
  d.write(fine(f.dValue, 'foodSafe.dValue'), 13);
  d.write(scaledRaw(f.targetLogReduction ?? 0, 'foodSafe.targetLogReduction', { scale: 10, max: 255 }), 8);
  const s = new BitWriter(FOOD_SAFE_STATUS_SIZE);
  s.write(Math.max(0, FOOD_SAFE_STATES.indexOf(f.state)), 3);
  s.write(scaledRaw(f.logReduction ?? 0, 'foodSafe.logReduction', { scale: 10, max: 255 }), 8);
  s.write(f.secondsAboveThreshold ?? 0, 16);
  s.write(f.logSequence ?? 0, 32);
  return { data: d.bytes, status: s.bytes };
}
