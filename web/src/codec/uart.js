// Nordic UART framing, requests and responses. Port of UartFrame.swift, UartRequest.swift, UartResponse.swift.
//
// Probe header: sync CA FE, CRC u16, type, [success], length. Node header: sync, CRC, type (MSB 1 for responses),
// request ID u32, [response ID u32, success], length. The CRC covers every byte after itself.

import { CodecError, crc16Ccitt, u16, u32, pushU16, pushU32, serialHex, cString } from './bytes.js';
import {
  unpackTemperatures, packTemperatures, unpackPredictionLog, packPredictionLog, packAlarms, unpackAlarms,
  encodeSetPredictionData, decodeSetPredictionData, ALARMS_SIZE,
} from './fields.js';

export const MessageType = {
  readSessionInfo: 0x03,
  readLogs: 0x04,
  setPrediction: 0x05,
  setAlarms: 0x0b,
  silenceAlarms: 0x0c,
  probeStatus: 0x45,
  probeFirmware: 0x46,
  probeHardware: 0x47,
  probeModel: 0x48,
  heartbeat: 0x49,
};

const REQUEST_TYPES = {
  readSessionInfo: MessageType.readSessionInfo,
  readLogs: MessageType.readLogs,
  setPrediction: MessageType.setPrediction,
  setAlarms: MessageType.setAlarms,
  silenceAlarms: MessageType.silenceAlarms,
  readProbeFirmware: MessageType.probeFirmware,
  readProbeHardware: MessageType.probeHardware,
  readProbeModel: MessageType.probeModel,
};
const NODE_ONLY = new Set(['readProbeFirmware', 'readProbeHardware', 'readProbeModel']);

export const requestMessageType = (request) => REQUEST_TYPES[request.type];

// MARK: Frames

/**
 * Serializes a frame `{variant, direction, messageType, requestId, responseId, success, payload}` with sync and CRC.
 */
export function encodeFrame(f) {
  const payload = f.payload ?? [];
  if (payload.length > 255) throw CodecError.outOfRange('payload.length', payload.length);
  if (!(f.messageType < 0x80)) throw CodecError.outOfRange('messageType', f.messageType);
  const isResponse = f.direction === 'response';
  const body = [f.variant === 'node' && isResponse ? f.messageType | 0x80 : f.messageType];
  if (f.variant === 'node') {
    if (f.requestId == null) throw CodecError.missingField('requestId');
    pushU32(body, f.requestId);
    if (isResponse) {
      if (f.responseId == null) throw CodecError.missingField('responseId');
      pushU32(body, f.responseId);
    }
  }
  if (isResponse) {
    if (f.success == null) throw CodecError.missingField('success');
    body.push(f.success ? 1 : 0);
  }
  body.push(payload.length, ...payload);
  const out = [0xca, 0xfe];
  pushU16(out, crc16Ccitt(body));
  return out.concat(body);
}

/**
 * Reassembles frames from BLE notifications that may split or merge frames; resynchronizes on CA FE.
 * `push` returns `[{frame}|{error: CodecError}]`. A probe UART carries one direction per stream (`direction`);
 * a node frame says which it is, so `direction` is ignored for `node`.
 */
export class UartFramer {
  constructor(variant, direction = 'response') {
    this.variant = variant;
    this.direction = direction;
    this.buffer = [];
  }

  get bufferedByteCount() { return this.buffer.length; }

  reset() { this.buffer = []; }

  push(bytes) {
    for (const b of bytes) this.buffer.push(b);
    const out = [];
    for (;;) {
      const sync = this.#findSync(0);
      if (sync == null) {
        const keep = this.buffer.length && this.buffer[this.buffer.length - 1] === 0xca ? 1 : 0;
        if (this.buffer.length - keep > 0) this.#drop(this.buffer.length - keep, out);
        return out;
      }
      if (sync > 0) this.#drop(sync, out);
      const parsed = this.#parse(0);
      if (parsed.frame) {
        out.push({ frame: parsed.frame });
        this.buffer.splice(0, parsed.length);
      } else if (parsed.error) {
        out.push({ error: parsed.error });
        this.buffer.splice(0, 2);
      } else {
        // A false sync inside garbage can claim a length that swallows real frames.
        // If a complete valid frame follows, the pending candidate was not a frame.
        const later = this.#laterValidFrame();
        if (later == null) return out;
        this.#drop(later, out);
      }
    }
  }

  #findSync(start) {
    for (let i = start; i < this.buffer.length - 1; i++) {
      if (this.buffer[i] === 0xca && this.buffer[i + 1] === 0xfe) return i;
    }
    return null;
  }

  #drop(count, out) {
    this.buffer.splice(0, count);
    out.push({ error: CodecError.badSync() });
  }

  #laterValidFrame() {
    let from = 1;
    for (let sync = this.#findSync(from); sync != null; sync = this.#findSync(from)) {
      if (this.#parse(sync).frame) return sync;
      from = sync + 1;
    }
    return null;
  }

  #parse(start) {
    const buf = this.buffer;
    const available = buf.length - start;
    let isResponse;
    let headerLength;
    if (this.variant === 'probe') {
      isResponse = this.direction === 'response';
      headerLength = isResponse ? 7 : 6;
    } else {
      if (available < 5) return {};
      isResponse = (buf[start + 4] & 0x80) !== 0;
      headerLength = isResponse ? 15 : 10;
    }
    if (available < headerLength) return {};
    const total = headerLength + buf[start + headerLength - 1];
    if (available < total) return {};
    const bytes = buf.slice(start, start + total);
    const expected = crc16Ccitt(bytes.slice(4));
    const actual = u16(bytes, 2);
    if (expected !== actual) return { error: CodecError.badCrc(expected, actual) };
    const isNode = this.variant === 'node';
    const frame = {
      variant: this.variant,
      direction: isResponse ? 'response' : 'request',
      messageType: isNode && isResponse ? bytes[4] & 0x7f : bytes[4],
      requestId: isNode ? u32(bytes, 5) : null,
      responseId: isNode && isResponse ? u32(bytes, 9) : null,
      success: isResponse ? bytes[headerLength - 2] !== 0 : null,
      payload: bytes.slice(headerLength),
    };
    return { frame, length: total };
  }
}

// MARK: Requests

/** Node Silence Alarms payload: global u8, product type u8, probe serial u32, node serial 10 B. */
const SILENCE_NODE_PAYLOAD_SIZE = 16;

function requestPayload(request) {
  const out = [];
  switch (request.type) {
    case 'readLogs':
      pushU32(out, request.start);
      pushU32(out, request.end);
      break;
    case 'setPrediction':
      pushU16(out, encodeSetPredictionData(request.setpoint, request.mode));
      break;
    case 'setAlarms':
      out.push(...packAlarms(request));
      break;
    default:
      break;
  }
  return out;
}

/**
 * Bytes to write to UART RX. `request` is `{type: 'readSessionInfo'|'readLogs'|'setPrediction'|'setAlarms'|
 * 'silenceAlarms'|'readProbeFirmware'|'readProbeHardware'|'readProbeModel', ...}` (fixture shape).
 * Node variant needs `probe` (serial hex) and `requestId`.
 */
export function encodeRequest(variant, request, { probe = null, requestId = null } = {}) {
  const messageType = requestMessageType(request);
  if (messageType == null) throw CodecError.unknownMessageType(-1);
  let payload = requestPayload(request);
  if (variant === 'probe') {
    if (NODE_ONLY.has(request.type)) throw CodecError.unknownMessageType(messageType);
  } else {
    if (probe == null) throw CodecError.missingField('probe');
    const serial = parseInt(probe, 16) >>> 0;
    const head = [];
    if (request.type === 'silenceAlarms') {
      head.push(0, 1);
      pushU32(head, serial);
      payload = head.concat(new Array(10).fill(0));
    } else {
      pushU32(head, serial);
      payload = head.concat(payload);
    }
  }
  return encodeFrame({
    variant, direction: 'request', messageType, requestId: variant === 'node' ? requestId : null, payload,
  });
}

function requirePayload(frame, count) {
  if (frame.payload.length < count) throw CodecError.tooShort(count, frame.payload.length);
}

/** Reads a request back from a frame: `{probe, request, requestId}`. Inverse of `encodeRequest`. */
export function decodeRequest(frame) {
  if (frame.direction !== 'request') throw CodecError.unknownMessageType(frame.messageType);
  const isNode = frame.variant === 'node';
  const lead = isNode ? 4 : 0;
  const p = frame.payload;
  let request;
  switch (frame.messageType) {
    case MessageType.readSessionInfo:
      requirePayload(frame, lead);
      request = { type: 'readSessionInfo' };
      break;
    case MessageType.readLogs:
      requirePayload(frame, lead + 8);
      request = { type: 'readLogs', start: u32(p, lead), end: u32(p, lead + 4) };
      break;
    case MessageType.setPrediction:
      requirePayload(frame, lead + 2);
      request = { type: 'setPrediction', ...decodeSetPredictionData(u16(p, lead)) };
      break;
    case MessageType.setAlarms:
      requirePayload(frame, lead + ALARMS_SIZE);
      request = { type: 'setAlarms', ...unpackAlarms(p.slice(lead, lead + ALARMS_SIZE)) };
      break;
    case MessageType.silenceAlarms:
      requirePayload(frame, isNode ? SILENCE_NODE_PAYLOAD_SIZE : 0);
      request = { type: 'silenceAlarms' };
      break;
    case MessageType.probeFirmware:
    case MessageType.probeHardware:
    case MessageType.probeModel:
      if (!isNode) throw CodecError.unknownMessageType(frame.messageType);
      requirePayload(frame, lead);
      request = {
        type: { 0x46: 'readProbeFirmware', 0x47: 'readProbeHardware', 0x48: 'readProbeModel' }[frame.messageType],
      };
      break;
    default:
      throw CodecError.unknownMessageType(frame.messageType);
  }
  let probe = null;
  if (isNode) {
    if (frame.messageType === MessageType.silenceAlarms) probe = p[0] === 0 ? serialHex(u32(p, 2)) : null;
    else probe = serialHex(u32(p, 0));
  }
  return { probe, request, requestId: frame.requestId };
}

// MARK: Responses

export const LOG_RECORD_SIZE = 24;
const INFO_KINDS = { 0x46: ['firmware', 20], 0x47: ['hardware', 16], 0x48: ['model', 50] };
const INFO_SIZES = { firmware: 20, hardware: 16, model: 50 };
/** Responses with no payload we read (set ID/color, food safe, power mode, reset, set prediction, alarms). */
const ACK_ONLY = new Set([0x01, 0x02, 0x05, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c]);

/**
 * Interprets a response frame as `{messageType, success, requestId, responseId, body}`. `body.type` is
 * `sessionInfo`, `logRecord`, `revision` or `ack`. A failed response (success = 0) is always `ack`.
 */
export function decodeResponse(frame) {
  if (frame.direction !== 'response') throw CodecError.unknownMessageType(frame.messageType);
  const type = frame.messageType;
  const isNode = frame.variant === 'node';
  const info = isNode ? INFO_KINDS[type] : undefined;
  const known = ACK_ONLY.has(type) || type === MessageType.readSessionInfo || type === MessageType.readLogs || info;
  if (!known) throw CodecError.unknownMessageType(type);
  const success = frame.success ?? false;
  const response = (body) => ({
    messageType: type, success, requestId: frame.requestId ?? null, responseId: frame.responseId ?? null, body,
  });
  if (!success || ACK_ONLY.has(type)) return response({ type: 'ack' });

  const p = frame.payload;
  const lead = isNode ? 4 : 0;
  const probe = isNode ? serialHex(u32(p, 0)) : null;
  if (type === MessageType.readSessionInfo) {
    requirePayload(frame, lead + 6);
    return response({ type: 'sessionInfo', probe, sessionId: u32(p, lead), samplePeriodMs: u16(p, lead + 4) });
  }
  if (type === MessageType.readLogs) {
    requirePayload(frame, lead + LOG_RECORD_SIZE);
    return response({
      type: 'logRecord',
      probe,
      sequence: u32(p, lead),
      temperatures: unpackTemperatures(p.slice(lead + 4, lead + 17)),
      prediction: unpackPredictionLog(p.slice(lead + 17, lead + 24)),
    });
  }
  const [kind, size] = info;
  requirePayload(frame, lead + size);
  return response({ type: 'revision', probe, kind, text: cString(p.slice(lead, lead + size)) });
}

/** Builds a response frame as a simulated probe or node would send it. Node responses need both IDs. */
export function encodeResponse(response, variant) {
  const payload = [];
  const body = response.body;
  const lead = () => {
    if (variant !== 'node') return;
    if (body.probe == null) throw CodecError.missingField('probe');
    pushU32(payload, parseInt(body.probe, 16) >>> 0);
  };
  switch (body.type) {
    case 'sessionInfo':
      lead();
      pushU32(payload, body.sessionId);
      pushU16(payload, body.samplePeriodMs);
      break;
    case 'logRecord':
      lead();
      pushU32(payload, body.sequence);
      payload.push(...packTemperatures(body.temperatures), ...packPredictionLog(body.prediction));
      break;
    case 'revision': {
      lead();
      const bytes = Array.from(new TextEncoder().encode(body.text));
      const size = INFO_SIZES[body.kind];
      if (bytes.length > size) throw CodecError.outOfRange('revision.text', bytes.length);
      payload.push(...bytes, ...new Array(size - bytes.length).fill(0));
      break;
    }
    default:
      break;
  }
  return encodeFrame({
    variant, direction: 'response', messageType: response.messageType, requestId: response.requestId,
    responseId: response.responseId, success: response.success, payload,
  });
}
