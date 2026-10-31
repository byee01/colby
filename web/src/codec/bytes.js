// Byte helpers shared by the codec. Port of mac/Sources/CombustionCodec (BitReader.swift, CRC.swift, CodecError.swift).

/** Typed failures of the pure codec (docs/02 §10). `kind` matches spec/fixtures/README.md. */
export class CodecError extends Error {
  /**
   * @param {'tooShort'|'badSync'|'badCrc'|'unknownMessageType'|'outOfRange'|'missingField'} kind
   * @param {object} [details] expected/actual (tooShort, badCrc), type (unknownMessageType), field/value
   */
  constructor(kind, details = {}) {
    super(`${kind} ${JSON.stringify(details)}`);
    this.name = 'CodecError';
    this.kind = kind;
    Object.assign(this, details);
  }

  static tooShort(expected, actual) { return new CodecError('tooShort', { expected, actual }); }
  static badSync() { return new CodecError('badSync'); }
  static badCrc(expected, actual) { return new CodecError('badCrc', { expected, actual }); }
  static unknownMessageType(type) { return new CodecError('unknownMessageType', { type }); }
  static outOfRange(field, value) { return new CodecError('outOfRange', { field, value }); }
  static missingField(field) { return new CodecError('missingField', { field }); }
}

/** CRC-16-CCITT (poly 0x1021, init 0xFFFF, no reflection, no final xor). */
export function crc16Ccitt(bytes) {
  let crc = 0xffff;
  for (const byte of bytes) {
    crc ^= byte << 8;
    for (let i = 0; i < 8; i++) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

/** Reads LSB-first packed fields; bit 1 in the specs is the LSB of byte 0. Callers check the length. */
export class BitReader {
  constructor(bytes) {
    this.bytes = bytes;
    this.position = 0;
  }

  /** Reads `count` bits (at most 32) as an unsigned number. */
  read(count) {
    let value = 0;
    for (let i = 0; i < count; i++) {
      const bit = (this.bytes[this.position >> 3] >> (this.position & 7)) & 1;
      value += bit * 2 ** i;
      this.position++;
    }
    return value;
  }
}

/** Writes LSB-first packed fields into a zeroed buffer of fixed size. */
export class BitWriter {
  constructor(byteCount) {
    this.bytes = new Array(byteCount).fill(0);
    this.position = 0;
  }

  write(value, count) {
    for (let i = 0; i < count; i++) {
      if (Math.floor(value / 2 ** i) % 2 === 1) this.bytes[this.position >> 3] |= 1 << (this.position & 7);
      this.position++;
    }
  }
}

export const u16 = (b, offset) => b[offset] | (b[offset + 1] << 8);
export const u32 = (b, offset) => (u16(b, offset) | (u16(b, offset + 2) << 16)) >>> 0;

export function pushU16(out, value) {
  out.push(value & 0xff, (value >>> 8) & 0xff);
}

export function pushU32(out, value) {
  pushU16(out, value & 0xffff);
  pushU16(out, (value >>> 16) & 0xffff);
}

/** Swift `rounded()`: halves away from zero. */
export const roundHalfAway = (v) => (v < 0 ? -Math.round(-v) : Math.round(v));

/** Rounds a scaled value to the nearest integer and range-checks it for a wire field. */
export function scaledRaw(value, field, { offset = 0, scale, max }) {
  const raw = roundHalfAway((value + offset) * scale);
  if (!(raw >= 0 && raw <= max)) throw CodecError.outOfRange(field, value);
  return raw;
}

export function hexToBytes(hex) {
  const clean = hex.replace(/[^0-9a-fA-F]/g, '');
  const out = [];
  for (let i = 0; i + 1 < clean.length; i += 2) out.push(parseInt(clean.slice(i, i + 2), 16));
  return out;
}

export const bytesToHex = (bytes) =>
  Array.from(bytes, (b) => b.toString(16).toUpperCase().padStart(2, '0')).join('');

/** Probe serials are u32 shown as 8 uppercase hex characters. */
export const serialHex = (value) => (value >>> 0).toString(16).toUpperCase().padStart(8, '0');

/** Decodes bytes up to the first NUL as UTF-8. */
export function cString(bytes) {
  const end = bytes.indexOf(0);
  const slice = end < 0 ? bytes : bytes.slice(0, end);
  return new TextDecoder().decode(Uint8Array.from(slice));
}
