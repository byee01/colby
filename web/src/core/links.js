// Connected devices. Port of DirectProbeLink.swift and NodeLink.swift (docs/02 §5.3, §5.4).
//
// Both emit `observation` (for ProbeStore) and `disconnected` (reason, once). NodeLink also emits `node` snapshots.

import { Emitter, systemClock } from './support.js';
import { UartClient, UartError } from './uartClient.js';
import { decodeProbeStatus, decodeNodeProbeStatus, MessageType, cString } from '../codec/index.js';
import { GATT } from '../transport/gatt.js';

async function requireCharacteristics(connection, needed) {
  const known = await connection.discover();
  for (const uuid of needed) {
    if (!known.has(uuid)) throw new Error(`characteristic not found: ${uuid}`);
  }
}

async function readText(connection, uuid) {
  try {
    const s = cString(Array.from(await connection.read(uuid)));
    return s || null;
  } catch {
    return null;
  }
}

/** Reads firmware, hardware and model strings; missing characteristics are skipped. */
export async function readDeviceInfo(connection) {
  const info = {
    firmware: await readText(connection, GATT.firmwareRevision),
    hardware: await readText(connection, GATT.hardwareRevision),
    model: await readText(connection, GATT.modelNumber),
  };
  return info.firmware || info.hardware || info.model ? info : null;
}

/**
 * Fills in the session of statuses that carry none. The 94 B status of fw v2.3.3 and older has no session fields
 * (spec/replays/charger-new-session), so on the first such status the link reads Session Info over UART and adds it to
 * every later status; history can then tell cooks apart. Statuses before the answer go out without it (the session
 * tracker adopts the id). A log range that goes backwards drops the cached info and reads it again. Firmware that
 * refuses the read keeps sending none. Port of the session handling in DirectProbeLink.swift / NodeLink.swift.
 */
class SessionFiller {
  info = null;
  reading = false;
  refused = false;
  lastLogMax = null;

  /** Returns the status with `session` filled in when known; starts a read with `read()` when needed. */
  fill(status, read) {
    if (status.session) {
      this.lastLogMax = status.logRange.max;
      return status;
    }
    if (this.lastLogMax != null && status.logRange.max < this.lastLogMax) {
      this.info = null;
      this.refused = false;
    }
    this.lastLogMax = status.logRange.max;
    if (!this.info && !this.reading && !this.refused) {
      this.reading = true;
      read().then(
        (r) => {
          if (r.body.type === 'sessionInfo' && r.body.sessionId !== 0) {
            this.info = { sessionId: r.body.sessionId, samplePeriodMs: r.body.samplePeriodMs };
          } else this.refused = true;
        },
        () => (this.refused = true),
      ).finally(() => (this.reading = false));
    }
    return this.info ? { ...status, session: this.info } : status;
  }
}

class Link extends Emitter {
  finished = false;
  statusDecodeErrors = 0;

  constructor(connection, clock) {
    super();
    this.connection = connection;
    this.clock = clock;
  }

  async close() {
    await this.connection.close();
    this.finish('requested');
  }

  finish(reason) {
    if (this.finished) return;
    this.finished = true;
    this.uart.close();
    this.onFinish?.();
    this.emit('disconnected', reason);
  }

  async setUp(needed, afterUart) {
    this.connection.onDisconnect((reason) => this.finish(reason));
    try {
      await requireCharacteristics(this.connection, needed);
      await this.uart.start();
      await afterUart?.();
    } catch (e) {
      // A half-started link must not hold a connection slot.
      await this.connection.close().catch(() => {});
      this.finish('requested');
      throw e;
    }
  }
}

/**
 * One probe connected over GATT. The status payload carries no serial, so the caller supplies it.
 * Read Logs requests are serialized: the probe UART allows one in flight.
 */
export class DirectProbeLink extends Link {
  kind = 'probe';
  #readChain = Promise.resolve();
  #session = new SessionFiller();

  constructor(serial, connection, { clock = systemClock } = {}) {
    super(connection, clock);
    this.serial = serial;
    this.uart = new UartClient('probe', connection, { clock });
  }

  async start() {
    await this.setUp([GATT.probeStatus, GATT.uartRX, GATT.uartTX], async () => {
      const off = await this.connection.subscribe(GATT.probeStatus, (bytes) => this.#handleStatus(bytes));
      this.onFinish = off;
    });
  }

  #handleStatus(bytes) {
    if (this.finished) return;
    let status;
    try {
      status = decodeProbeStatus(bytes);
    } catch {
      this.statusDecodeErrors++;
      return;
    }
    status = this.#session.fill(status, () => this.uart.send({ type: 'readSessionInfo' }));
    const now = this.clock.now();
    this.emit('observation', {
      serial: this.serial,
      source: { kind: 'directConnection', highRadioPower: status.preferences?.highRadioPower ?? null, lastSeen: now },
      payload: { status },
      receivedAt: now,
    });
  }

  covers(probe) { return probe === this.serial && !this.finished; }

  send(request, probe, timeoutMs = 3000) {
    if (probe !== this.serial) return Promise.reject(new UartError('failure'));
    return this.uart.send(request, { timeoutMs });
  }

  readLogs(probe, start, end, onRecord) {
    if (probe !== this.serial) return Promise.reject(new UartError('failure'));
    const run = () => this.uart.readLogs({ start, end, onRecord });
    const next = this.#readChain.then(run, run);
    this.#readChain = next.catch(() => {});
    return next;
  }
}

/** A probe counts as relayed by a node for this long after its last 0x45. */
export const NODE_COVERAGE_TTL_MS = 10_000;

/**
 * One MeatNet node (Display, Booster, ...). Every 0x45 becomes an observation with source `nodeConnection`; requests
 * for a probe are addressed by serial, so one connection serves every probe the node relays.
 */
export class NodeLink extends Link {
  kind = 'node';
  #coverage = new Map();
  #sessions = new Map();

  constructor(serial, productType, connection, { clock = systemClock, requestIds } = {}) {
    super(connection, clock);
    this.serial = serial;
    this.productType = productType;
    this.uart = new UartClient('node', connection, { clock, requestIds });
    this.snapshot = {
      serial, productType, probes: [], hopCounts: {}, isConnected: false, firmware: null,
      heartbeatCount: 0, lastHeartbeat: null, link: { kind: 'nodeAdvertisement', lastSeen: clock.now() },
    };
  }

  async start() {
    const off = this.uart.on('frame', (frame) => this.#handle(frame));
    this.onFinish = () => {
      off();
      this.#coverage.clear();
      this.snapshot = {
        ...this.snapshot, isConnected: false, probes: [], hopCounts: {},
        link: { kind: 'nodeAdvertisement', lastSeen: this.clock.now() },
      };
      this.emit('node', this.snapshot);
    };
    await this.setUp([GATT.uartRX, GATT.uartTX]);
    this.snapshot = { ...this.snapshot, isConnected: true, link: { kind: 'directConnection', lastSeen: this.clock.now() } };
    this.emit('node', this.snapshot);
    readDeviceInfo(this.connection).then((firmware) => {
      if (firmware && !this.finished) {
        this.snapshot = { ...this.snapshot, firmware };
        this.emit('node', this.snapshot);
      }
    });
  }

  #handle(frame) {
    if (this.finished) return;
    if (frame.messageType === MessageType.probeStatus) this.#handleProbeStatus(frame.payload);
    else if (frame.messageType === MessageType.heartbeat) this.#handleHeartbeat();
  }

  #handleProbeStatus(payload) {
    let node;
    try {
      node = decodeNodeProbeStatus(payload);
    } catch {
      this.statusDecodeErrors++;
      return;
    }
    const serial = node.probeSerial;
    if (!this.#sessions.has(serial)) this.#sessions.set(serial, new SessionFiller());
    node.status = this.#sessions.get(serial).fill(node.status, () => this.uart.send({ type: 'readSessionInfo' }, { probe: serial }));
    const now = this.clock.now();
    this.emit('observation', {
      serial: node.probeSerial,
      source: {
        kind: 'nodeConnection', via: this.serial, hopCount: node.hopCount,
        highRadioPower: node.status.preferences?.highRadioPower ?? null, lastSeen: now,
      },
      payload: { status: node.status },
      receivedAt: now,
    });
    const prev = this.#coverage.get(node.probeSerial);
    this.#coverage.set(node.probeSerial, { at: now, hops: node.hopCount });
    if (prev?.hops !== node.hopCount) this.#refreshProbes(now);
  }

  #handleHeartbeat() {
    const now = this.clock.now();
    this.snapshot = {
      ...this.snapshot, heartbeatCount: this.snapshot.heartbeatCount + 1, lastHeartbeat: now,
      link: { ...this.snapshot.link, lastSeen: now },
    };
    // Heartbeats are the only periodic event, so they also retire probes that stopped being relayed.
    this.#refreshProbes(now);
  }

  #live(now) {
    const out = {};
    for (const [serial, c] of this.#coverage) if (now - c.at < NODE_COVERAGE_TTL_MS) out[serial] = c.hops;
    return out;
  }

  #refreshProbes(now) {
    const live = this.#live(now);
    this.snapshot = { ...this.snapshot, probes: Object.keys(live).sort(), hopCounts: live };
    this.emit('node', this.snapshot);
  }

  covers(probe) { return !this.finished && probe in this.#live(this.clock.now()); }

  send(request, probe, timeoutMs = 3000) {
    return this.uart.send(request, { probe, timeoutMs });
  }

  /** Node requests carry IDs, so concurrent reads need no serialization. */
  readLogs(probe, start, end, onRecord) {
    return this.uart.readLogs({ probe, start, end, onRecord });
  }
}
