// Manufacturer data decode/encode. Port of Advertisement.swift.
//
// Layout (vendor ID first): 0-1 vendor 0x09C7 LE, 2 product type, 3-6 serial, 7-19 raw temperatures,
// 20 mode/ID, 21 battery + virtual sensors, 22 network information, 23 overheating, 24 preferences (probe only).

import { CodecError, u32, pushU32, serialHex, cString } from './bytes.js';
import {
  unpackTemperatures, packTemperatures, decodeModeAndId, encodeModeAndId, virtualSensorsFromBits,
  virtualSensorsToBits, decodeOverheat, encodeOverheat, decodePreferences, encodePreferences,
} from './fields.js';

export const VENDOR_ID = 0x09c7;
const VENDOR = [0xc7, 0x09];
const NODE_PRODUCT_TYPES = { 2: 'repeater', 3: 'gauge', 4: 'display', 5: 'booster', 6: 'engine' };

const Ad = {
  productType: 2, probeSerial: 3, temperatures: 7, modeAndId: 20, battery: 21, network: 22,
  overheat: 23, preferences: 24, nodeSerial: 3, nodeSerialLength: 10, nodePreferences: 13, packetSize: 25,
};

/** Network Information byte: hop count (1...4) in the top two bits (both SDKs; see docs/01). */
export const hopCount = (byte) => (byte >> 6) + 1;

export function networkInformation(hops) {
  if (!(hops >= 1 && hops <= 4)) throw CodecError.outOfRange('hopCount', hops);
  return (hops - 1) << 6;
}

function probeAdvertisement(b) {
  const ident = decodeModeAndId(b[Ad.modeAndId]);
  return {
    serial: serialHex(u32(b, Ad.probeSerial)),
    temperatures: unpackTemperatures(b.slice(Ad.temperatures, Ad.modeAndId)),
    mode: ident.mode,
    color: ident.color,
    probeNumber: ident.probeNumber,
    batteryLow: (b[Ad.battery] & 1) !== 0,
    virtualSensors: virtualSensorsFromBits(b[Ad.battery] >> 1),
    overheating: b.length > Ad.overheat ? decodeOverheat(b[Ad.overheat]) : null,
    preferences: b.length > Ad.preferences ? decodePreferences(b[Ad.preferences]) : null,
  };
}

/**
 * Decodes manufacturer data (vendor ID first). Returns one of
 * `{kind:'probe', ...}`, `{kind:'repeated', hopCount, ...}`, `{kind:'node', productType, nodeProductType, serial,
 * preferences}`, `{kind:'unknown', productType}`. Throws `badSync` for another vendor.
 */
export function decodeAdvertisement(mfrData) {
  const b = Array.from(mfrData);
  if (b.length <= Ad.productType) throw CodecError.tooShort(Ad.productType + 1, b.length);
  if (b[0] !== VENDOR[0] || b[1] !== VENDOR[1]) throw CodecError.badSync();
  const type = b[Ad.productType];
  if (type === 1 || type === 2) {
    const needed = type === 1 ? Ad.network : Ad.network + 1;
    if (b.length < needed) throw CodecError.tooShort(needed, b.length);
    const probe = probeAdvertisement(b);
    return type === 1 ? { kind: 'probe', ...probe } : { kind: 'repeated', ...probe, hopCount: hopCount(b[Ad.network]) };
  }
  if (type >= 3 && type <= 6) {
    const end = Ad.nodeSerial + Ad.nodeSerialLength;
    if (b.length < end) throw CodecError.tooShort(end, b.length);
    const nodeProductType = NODE_PRODUCT_TYPES[type];
    const hasPreferences = nodeProductType === 'display' || nodeProductType === 'booster';
    return {
      kind: 'node',
      productType: type,
      nodeProductType,
      serial: cString(b.slice(Ad.nodeSerial, end)),
      preferences: hasPreferences && b.length > Ad.nodePreferences ? b[Ad.nodePreferences] : null,
    };
  }
  return { kind: 'unknown', productType: type };
}

/** Builds manufacturer data (vendor ID first). Inverse of `decodeAdvertisement`. */
export function encodeAdvertisement(packet) {
  switch (packet.kind) {
    case 'probe':
      return encodeProbe(packet, 1, 0);
    case 'repeated':
      return encodeProbe(packet, 2, networkInformation(packet.hopCount));
    case 'node': {
      const serial = Array.from(new TextEncoder().encode(packet.serial));
      if (serial.length > Ad.nodeSerialLength) throw CodecError.outOfRange('node.serial', serial.length);
      const type = packet.productType ?? Number(Object.keys(NODE_PRODUCT_TYPES).find((k) => NODE_PRODUCT_TYPES[k] === packet.nodeProductType));
      const out = [...VENDOR, type, ...serial];
      while (out.length < Ad.packetSize) out.push(0);
      if (packet.preferences != null) out[Ad.nodePreferences] = packet.preferences;
      return out;
    }
    default:
      return [...VENDOR, packet.productType];
  }
}

function encodeProbe(p, productType, network) {
  const out = [...VENDOR, productType];
  pushU32(out, parseInt(p.serial, 16));
  out.push(...packTemperatures(p.temperatures));
  out.push(encodeModeAndId(p));
  out.push((p.batteryLow ? 1 : 0) | (virtualSensorsToBits(p.virtualSensors) << 1));
  out.push(network);
  if (p.overheating != null || p.preferences != null) out.push(encodeOverheat(p.overheating ?? []));
  if (p.preferences != null) out.push(encodePreferences(p.preferences));
  return out;
}
