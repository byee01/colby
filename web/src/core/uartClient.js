// UART framing, request/response correlation and timeouts over a Nordic UART connection. Port of UartClient.swift
// (docs/02 §5.5).
//
// - Probe variant: no request IDs; one request in flight per message type, matched by type (a second one throws busy).
// - Node variant: a random u32 request ID per request; duplicate Response IDs (the repeater network can deliver
//   copies) are dropped.
//
// A connection (see transport/) offers `subscribe(uuid, onBytes)`, `write(uuid, bytes)`, `mtu`.

import { Emitter, systemClock } from './support.js';
import { CodecError, UartFramer, encodeRequest, decodeResponse, requestMessageType, MessageType } from '../codec/index.js';
import { GATT } from '../transport/gatt.js';

/** Failure of a UART request: kind is 'timeout' | 'failure' | 'disconnected' | 'codec' | 'busy'. */
export class UartError extends Error {
  constructor(kind, cause) {
    super(cause ? `${kind}: ${cause.message}` : kind);
    this.name = 'UartError';
    this.kind = kind;
    this.cause = cause;
  }
}

const SEEN_RESPONSE_LIMIT = 512;

export class UartClient extends Emitter {
  diagnostics = { framingErrors: 0, ignoredFrames: 0, duplicateResponses: 0, codecErrors: 0 };
  #framer;
  #pending = new Map();
  #started = false;
  #closed = false;
  #unsubscribe = null;
  #seen = new Set();
  #seenOrder = [];
  #writeChain = Promise.resolve();

  constructor(variant, connection, { clock = systemClock, requestIds = () => (Math.random() * 2 ** 32) >>> 0 } = {}) {
    super();
    this.variant = variant;
    this.connection = connection;
    this.clock = clock;
    this.requestIds = requestIds;
    this.#framer = new UartFramer(variant, 'response');
  }

  /** Subscribes to UART TX. Unsolicited (request-direction) frames are emitted as `frame`. */
  async start() {
    if (this.#closed) throw new UartError('disconnected');
    if (this.#started) return;
    this.#started = true;
    try {
      this.#unsubscribe = await this.connection.subscribe(GATT.uartTX, (bytes) => this.#handle(bytes));
    } catch (e) {
      this.#started = false;
      throw e;
    }
  }

  /** Fails every pending request with `disconnected`. Does not close the connection. */
  close() {
    if (this.#closed) return;
    this.#closed = true;
    this.#unsubscribe?.();
    for (const [key, p] of this.#pending) {
      this.clock.clearTimeout(p.timer);
      this.#pending.delete(key);
      p.onEvent({ error: new UartError('disconnected') });
    }
  }

  /**
   * Sends one request and resolves with its response. `timeoutMs` applies per attempt; on timeout the same bytes
   * are written again up to `retries` times. A response with success = 0 rejects with `failure`.
   */
  send(request, { probe = null, timeoutMs = 3000, retries = 1 } = {}) {
    return new Promise((resolve, reject) => {
      let key;
      let bytes;
      try {
        ({ key, bytes } = this.#prepare(request, probe));
      } catch (e) {
        reject(e);
        return;
      }
      let attempts = 0;
      const p = this.#register(key, requestMessageType(request), false, (ev) => {
        if (ev.timedOut) {
          if (attempts >= retries) return finish(new UartError('timeout'));
          attempts++;
          attempt();
          return;
        }
        if (ev.error) return finish(ev.error);
        if (!ev.response.success) return finish(new UartError('failure'));
        finish(null, ev.response);
      });
      if (!p) {
        reject(new UartError('busy'));
        return;
      }
      const finish = (error, response) => {
        this.#complete(key, p);
        if (error) reject(error);
        else resolve(response);
      };
      const attempt = () => {
        this.#arm(key, p, timeoutMs);
        this.#write(bytes).catch(() => finish(new UartError('disconnected')));
      };
      attempt();
    });
  }

  /**
   * Reads log records in [start, end]: one request, N responses. Calls `onRecord` per new sequence and resolves
   * with the records once the one with `sequence >= end` arrives, or after `idleMs` with no further record (a
   * partial range). Rejects with `timeout` if nothing arrived. Node variant: records for other probes are ignored.
   */
  readLogs({ probe = null, start, end, idleMs = 2000, onRecord = () => {} }) {
    return new Promise((resolve, reject) => {
      let key;
      let bytes;
      try {
        ({ key, bytes } = this.#prepare({ type: 'readLogs', start, end }, probe));
      } catch (e) {
        reject(e);
        return;
      }
      const seen = new Set();
      const records = [];
      const p = this.#register(key, MessageType.readLogs, true, (ev) => {
        if (ev.timedOut) return seen.size ? finish(null) : finish(new UartError('timeout'));
        if (ev.error) return finish(ev.error);
        const r = ev.response;
        if (!r.success) return finish(new UartError('failure'));
        if (r.body.type !== 'logRecord') return;
        if (probe && r.body.probe && r.body.probe !== probe) return;
        if (seen.has(r.body.sequence)) return;
        seen.add(r.body.sequence);
        this.#arm(key, p, idleMs);
        records.push(r.body);
        onRecord(r.body);
        if (r.body.sequence >= end) finish(null);
      });
      if (!p) {
        reject(new UartError('busy'));
        return;
      }
      const finish = (error) => {
        this.#complete(key, p);
        if (error) reject(error);
        else resolve(records);
      };
      this.#arm(key, p, idleMs);
      this.#write(bytes).catch(() => finish(new UartError('disconnected')));
    });
  }

  #prepare(request, probe) {
    if (!this.#started || this.#closed) throw new UartError('disconnected');
    let id = null;
    if (this.variant === 'node') {
      do id = this.requestIds() >>> 0; while (this.#pending.has(`id:${id}`));
    }
    let bytes;
    try {
      bytes = encodeRequest(this.variant, request, { probe, requestId: id });
    } catch (e) {
      throw e instanceof CodecError ? new UartError('codec', e) : e;
    }
    return { key: id != null ? `id:${id}` : `type:${requestMessageType(request)}`, bytes };
  }

  #register(key, messageType, multi, onEvent) {
    if (this.#pending.has(key)) return null;
    const p = { messageType, multi, onEvent, timer: null };
    this.#pending.set(key, p);
    return p;
  }

  #complete(key, p) {
    this.clock.clearTimeout(p.timer);
    if (this.#pending.get(key) === p) this.#pending.delete(key);
  }

  #arm(key, p, ms) {
    this.clock.clearTimeout(p.timer);
    p.timer = this.clock.setTimeout(() => {
      if (this.#pending.get(key) === p) p.onEvent({ timedOut: true });
    }, ms);
  }

  /** Writes are serialized; frames longer than the ATT payload go in chunks. */
  #write(bytes) {
    const run = async () => {
      const chunk = Math.max((this.connection.mtu ?? 23) - 3, 20);
      for (let offset = 0; offset < bytes.length; offset += chunk) {
        await this.connection.write(GATT.uartRX, bytes.slice(offset, offset + chunk));
      }
    };
    const next = this.#writeChain.then(run, run);
    this.#writeChain = next.catch(() => {});
    return next;
  }

  #handle(bytes) {
    for (const o of this.#framer.push(bytes)) {
      if (o.error) this.diagnostics.framingErrors++;
      else this.#route(o.frame);
    }
  }

  #route(frame) {
    if (frame.direction === 'request') {
      this.emit('frame', frame);
      return;
    }
    if (this.variant === 'node' && frame.responseId != null) {
      if (this.#seen.has(frame.responseId)) {
        this.diagnostics.duplicateResponses++;
        return;
      }
      this.#seen.add(frame.responseId);
      this.#seenOrder.push(frame.responseId);
      if (this.#seenOrder.length > SEEN_RESPONSE_LIMIT) this.#seen.delete(this.#seenOrder.shift());
    }
    const key = this.variant === 'node' ? `id:${frame.requestId}` : `type:${frame.messageType}`;
    const p = this.#pending.get(key);
    if (!p || p.messageType !== frame.messageType) {
      this.diagnostics.ignoredFrames++;
      return;
    }
    let response;
    try {
      response = decodeResponse(frame);
    } catch (e) {
      this.diagnostics.codecErrors++;
      this.#complete(key, p);
      p.onEvent({ error: new UartError('codec', e) });
      return;
    }
    if (!p.multi) this.#complete(key, p);
    p.onEvent({ response });
  }
}
