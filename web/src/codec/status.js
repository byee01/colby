// Probe Status (GATT characteristic) and node 0x45 payloads. Port of ProbeStatus.swift.

import { CodecError, u16, u32, pushU16, pushU32, serialHex } from './bytes.js';
import { hopCount, networkInformation } from './advertisement.js';
import {
  unpackTemperatures, packTemperatures, decodeModeAndId, encodeModeAndId, virtualSensorsFromBits,
  virtualSensorsToBits, unpackPrediction, packPrediction, unpackFoodSafe, packFoodSafe, decodeOverheat,
  encodeOverheat, decodePreferences, encodePreferences, unpackAlarms, packAlarms, ALARMS_SIZE,
} from './fields.js';

// Offsets within the status, excluding a node's leading serial. The node message inserts one Network
// Information byte after Food Safe Status; everything after it shifts by one.
const Offset = {
  temperatures: 8, modeAndId: 21, batteryAndVirtual: 22, prediction: 23, foodSafeData: 30,
  foodSafeStatus: 40, afterFoodSafe: 48, minimum: 30, legacyNodeNetwork: 30,
};

function parseStatus(b, networkByte) {
  if (b.length < Offset.minimum) throw CodecError.tooShort(Offset.minimum, b.length);
  const ident = decodeModeAndId(b[Offset.modeAndId]);
  const battery = b[Offset.batteryAndVirtual];
  const foodSafe = b.length >= Offset.afterFoodSafe
    ? unpackFoodSafe(b.slice(Offset.foodSafeData, Offset.foodSafeStatus), b.slice(Offset.foodSafeStatus, Offset.afterFoodSafe))
    : null;
  const base = Offset.afterFoodSafe + (networkByte ? 1 : 0);
  const alarmsEnd = base + 2 + ALARMS_SIZE;
  let session = null;
  if (b.length >= alarmsEnd + 6) {
    const id = u32(b, alarmsEnd);
    session = id === 0 ? null : { sessionId: id, samplePeriodMs: u16(b, alarmsEnd + 4) };
  }
  return {
    logRange: { min: u32(b, 0), max: u32(b, 4) },
    temperatures: unpackTemperatures(b.slice(Offset.temperatures, Offset.modeAndId)),
    mode: ident.mode,
    color: ident.color,
    probeNumber: ident.probeNumber,
    batteryLow: (battery & 1) !== 0,
    virtualSensors: virtualSensorsFromBits(battery >> 1),
    prediction: unpackPrediction(b.slice(Offset.prediction, Offset.foodSafeData)),
    foodSafe,
    overheating: b.length > base ? decodeOverheat(b[base]) : null,
    preferences: b.length > base + 1 ? decodePreferences(b[base + 1]) : null,
    alarms: b.length >= alarmsEnd ? unpackAlarms(b.slice(base + 2, alarmsEnd)) : null,
    session,
  };
}

/** Decodes the probe's Probe Status characteristic: 94 B (no session fields) or 100 B. Trailing bytes ignored. */
export function decodeProbeStatus(bytes) {
  return parseStatus(Array.from(bytes), false);
}

/** Decodes a node 0x45 payload: `{probeSerial, hopCount, status}`. 99 B, 105 B, or 35 B from the oldest nodes. */
export function decodeNodeProbeStatus(bytes) {
  const b = Array.from(bytes);
  if (b.length < 4 + Offset.minimum + 1) throw CodecError.tooShort(4 + Offset.minimum + 1, b.length);
  const rest = b.slice(4);
  let networkOffset;
  if (rest.length === Offset.legacyNodeNetwork + 1) {
    networkOffset = Offset.legacyNodeNetwork;
  } else {
    networkOffset = Offset.afterFoodSafe;
    if (rest.length <= networkOffset) throw CodecError.tooShort(4 + networkOffset + 1, b.length);
  }
  return {
    probeSerial: serialHex(u32(b, 0)),
    hopCount: hopCount(rest[networkOffset]),
    status: parseStatus(rest, true),
  };
}

function statusBytes(s, networkByte, layout) {
  if (!s.foodSafe) throw CodecError.missingField('foodSafe');
  if (!s.overheating) throw CodecError.missingField('overheating');
  if (!s.preferences) throw CodecError.missingField('preferences');
  if (!s.alarms) throw CodecError.missingField('alarms');
  const out = [];
  pushU32(out, s.logRange.min);
  pushU32(out, s.logRange.max);
  out.push(...packTemperatures(s.temperatures));
  out.push(encodeModeAndId(s));
  out.push((s.batteryLow ? 1 : 0) | (virtualSensorsToBits(s.virtualSensors) << 1));
  out.push(...packPrediction(s.prediction));
  const food = packFoodSafe(s.foodSafe);
  out.push(...food.data, ...food.status);
  if (networkByte != null) out.push(networkByte);
  out.push(encodeOverheat(s.overheating));
  out.push(encodePreferences(s.preferences));
  out.push(...packAlarms(s.alarms));
  if (layout === 'current') {
    pushU32(out, s.session?.sessionId ?? 0);
    pushU16(out, s.session?.samplePeriodMs ?? 0);
  }
  return out;
}

/** Encodes a probe GATT status (`layout` 'current' = 100 B, 'legacy' = 94 B). */
export function encodeProbeStatus(status, layout = 'current') {
  return statusBytes(status, null, layout);
}

/** Encodes a node 0x45 payload from `{probeSerial, hopCount, status}`. */
export function encodeNodeProbeStatus({ probeSerial, hopCount: hops, status }, layout = 'current') {
  const out = [];
  pushU32(out, parseInt(probeSerial, 16));
  out.push(...statusBytes(status, networkInformation(hops), layout));
  return out;
}
