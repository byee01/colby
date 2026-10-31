// Core behaviour with a fake clock: presenter rules, UART client, alert engine, history, and the whole app against the
// simulated probe and node (real codec on both sides).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeClock, settle, Emitter } from '../src/core/support.js';
import { PredictionSmoother } from '../src/core/presenter.js';
import { UartClient } from '../src/core/uartClient.js';
import { AlertEngine, defaultRules, evaluateRule } from '../src/core/alerts.js';
import { SessionTracker, planBackfill } from '../src/core/history.js';
import { InstantReadFilter, ProbeStore } from '../src/core/probeStore.js';
import { ColbyApp } from '../src/core/app.js';
import { SimProbe, SimProbeConnection, SimNodeConnection } from '../src/transport/simulated.js';
import { GATT } from '../src/transport/gatt.js';
import { encodeResponse, encodeFrame } from '../src/codec/index.js';

const HOUR = 3_600_000;
const prediction = (state, raw) => ({
  state, mode: 'timeToRemoval', type: 'removal', setpoint: 95, heatStart: 5, rawSecondsRemaining: raw, estimatedCore: 60,
});

test('smoother rounds to 15 s above 5 min and updates only on seq % 3 == 0', () => {
  const s = new PredictionSmoother();
  s.ingest(prediction('predicting', 1000), 1, 0);
  assert.equal(s.view('A', 0, 15000).secondsRemaining, 1005);
  s.ingest(prediction('predicting', 990), 2, 5000);
  assert.equal(s.view('A', 5000, 15000).secondsRemaining, 1005, 'held: seq 2');
  s.ingest(prediction('predicting', 980), 3, 10000);
  assert.equal(s.view('A', 10000, 15000).secondsRemaining, 975);
  assert.equal(s.view('A', 10000, 15000).readyAt, 10000 + 975_000);
});

test('smoother counts down linearly in the last five minutes and goes stale after 15 s', () => {
  const s = new PredictionSmoother();
  s.ingest(prediction('predicting', 200), 1, 0);
  assert.equal(s.view('A', 0, 15000).secondsRemaining, 200);
  s.tick(2000);
  assert.equal(s.view('A', 2000, 15000).secondsRemaining, 198);
  s.tick(5000);
  assert.equal(s.view('A', 5000, 15000).secondsRemaining, 195);
  assert.equal(s.view('A', 14000, 15000).isStale, false);
  assert.equal(s.view('A', 15000, 15000).isStale, true);
});

test('smoother marks ready time', () => {
  const s = new PredictionSmoother();
  s.ingest(prediction('removalPredictionDone', 0), 1, 7000);
  s.ingest(prediction('removalPredictionDone', 0), 2, 12000);
  assert.equal(s.view('A', 12000, 15000).readySince, 7000);
  assert.equal(s.view('A', 12000, 15000).secondsRemaining, null);
});

test('instant read filter holds within the deadband', () => {
  const f = new InstantReadFilter();
  f.addReading(50.2);
  assert.equal(f.celsius, 50);
  f.addReading(50.54);
  assert.equal(f.celsius, 50);
  f.addReading(50.56);
  assert.equal(f.celsius, 51);
  f.addReading(null);
  assert.equal(f.celsius, null);
});

test('session tracker and backfill planner', () => {
  const t = new SessionTracker();
  assert.equal(t.observe(7, { min: 0, max: 10 }, 0).decision, 'new');
  assert.equal(t.observe(7, { min: 0, max: 11 }, 5000).decision, 'continuing');
  assert.equal(t.observe(8, { min: 0, max: 1 }, 10000).reason, 'sessionIdChanged');
  assert.deepEqual(planBackfill([3, 4], { min: 0, max: 9 }, 4), [[6, 9], [5, 5], [0, 2]]);
  assert.deepEqual(planBackfill([], { min: 5, max: 4 }), []);
});

/** A fake GATT connection: writes go to `onWrite`, notifications are pushed with `notify`. */
class FakeConnection {
  mtu = 185;
  handlers = new Set();
  writes = [];
  async subscribe(_uuid, fn) {
    this.handlers.add(fn);
    return () => this.handlers.delete(fn);
  }
  async write(_uuid, bytes) {
    this.writes.push(bytes);
    this.onWrite?.(bytes);
  }
  notify(bytes) { for (const fn of this.handlers) fn(bytes); }
}

test('uart client: probe variant is one request per type, retries once, then times out', async () => {
  const clock = new FakeClock();
  const conn = new FakeConnection();
  const uart = new UartClient('probe', conn, { clock });
  await uart.start();
  const first = uart.send({ type: 'readSessionInfo' }, { timeoutMs: 1000 });
  await assert.rejects(uart.send({ type: 'readSessionInfo' }), (e) => e.kind === 'busy');
  const failed = assert.rejects(first, (e) => e.kind === 'timeout');
  await clock.advance(2100);
  await failed;
  assert.equal(conn.writes.length, 2, 'one retry with the same bytes');
});

test('uart client: node variant matches request IDs and drops duplicate responses', async () => {
  const clock = new FakeClock();
  const conn = new FakeConnection();
  let id = 41;
  const uart = new UartClient('node', conn, { clock, requestIds: () => ++id });
  await uart.start();
  const reply = encodeResponse({
    messageType: 0x03, success: true, requestId: 42, responseId: 9,
    body: { type: 'sessionInfo', probe: '10005A3F', sessionId: 77, samplePeriodMs: 5000 },
  }, 'node');
  conn.onWrite = () => clock.setTimeout(() => { conn.notify(reply); conn.notify(reply); }, 10);
  const p = uart.send({ type: 'readSessionInfo' }, { probe: '10005A3F' });
  await clock.advance(20);
  const r = await p;
  assert.equal(r.body.sessionId, 77);
  assert.equal(uart.diagnostics.duplicateResponses, 1);
  const frames = [];
  uart.on('frame', (f) => frames.push(f));
  conn.notify(encodeFrame({ variant: 'node', direction: 'request', messageType: 0x49, requestId: 1, payload: [] }));
  assert.equal(frames.length, 1);
});

function snapshot(overrides = {}) {
  return {
    serial: 'AAAA0001', mode: 'normal', temperatures: [60, 60, 60, 70, 80, 90, 100, 120], batteryLow: false,
    overheating: [], alarms: null, prediction: null, isOffline: false, receivedAt: 0,
    virtual: { core: 60, surface: 80, ambient: 120 }, ...overrides,
  };
}

test('rule evaluation: hysteresis and offline during a cook', () => {
  const k = { type: 'temperatureAbove', channel: 'core', celsius: 60, hysteresis: 1 };
  assert.equal(evaluateRule(k, { snapshot: snapshot({ virtual: { core: 59.5 } }), wasActive: false }).met, false);
  assert.equal(evaluateRule(k, { snapshot: snapshot({ virtual: { core: 59.5 } }), wasActive: true }).met, true);
  const off = { type: 'probeOffline', seconds: 60, onlyDuringCook: true };
  assert.equal(evaluateRule(off, { snapshot: snapshot({ isOffline: true }), cookActive: false }).met, false);
  assert.equal(evaluateRule(off, { snapshot: snapshot({ isOffline: true }), cookActive: true }).met, true);
});

test('alert engine: ready latches until acknowledged; offline fires after its sustain; keep-awake follows the cook', async () => {
  const clock = new FakeClock();
  const held = [];
  const events = [];
  const engine = new AlertEngine({ clock, keepAwake: { setHeld: (on) => held.push(on) } });
  engine.on('event', (e) => events.push(`${e.instance.id} ${e.from}->${e.to}`));
  await engine.setFollowed(['AAAA0001']);
  assert.equal((await engine.rules('AAAA0001')).length, defaultRules('AAAA0001').length);

  const s = snapshot({ prediction: { state: 'predicting' } });
  engine.ingestSnapshots(new Map([['AAAA0001', s]]));
  assert.deepEqual(held, [true]);
  engine.ingestPrediction({ serial: 'AAAA0001', state: 'removalPredictionDone', type: 'removal', isStale: false, secondsRemaining: null });
  engine.ingestPrediction({ serial: 'AAAA0001', state: 'predicting', type: 'removal', isStale: false, secondsRemaining: 900 });
  assert.equal(engine.activeAlerts()[0].id, 'AAAA0001.ready', 'still firing after the condition went away');
  await engine.acknowledge('AAAA0001.ready');
  assert.equal(engine.instances.get('AAAA0001.ready').state, 'acknowledged');
  engine.ingestPrediction({ serial: 'AAAA0001', state: 'predicting', type: 'removal', isStale: false, secondsRemaining: 885 });
  assert.equal(engine.activeAlerts().length, 0, 'cleared on the next evaluation: condition false and acknowledged');

  engine.ingestSnapshots(new Map([['AAAA0001', { ...s, isOffline: true, receivedAt: clock.now() }]]));
  await clock.advance(59_000);
  assert.ok(!engine.instances.has('AAAA0001.offline'));
  await clock.advance(1_000);
  assert.equal(engine.instances.get('AAAA0001.offline')?.state, 'firing');
  await clock.advance(600_000);
  assert.deepEqual(held, [true, false], 'a quiet cook stops counting after 10 min');
  assert.ok(events.includes('AAAA0001.ready idle->firing'));
});

/** Waits (in fake time) until `cond()` holds. */
async function until(clock, cond, stepMs = 100, maxMs = 120_000) {
  for (let t = 0; t <= maxMs; t += stepMs) {
    if (cond()) return;
    await clock.advance(stepMs);
  }
  assert.fail('condition not met in time');
}

test('app with a direct probe: live status, prediction, history backfill, commands', async () => {
  const clock = new FakeClock();
  const probe = new SimProbe({ serial: '10005A3F', clock, startedAt: clock.now() - 2 * HOUR, setpoint: 95, mode: 'timeToRemoval' });
  const app = new ColbyApp({ clock });
  await app.start();
  const device = app.addDevice({ id: 'p1', name: 'Probe', open: async () => new SimProbeConnection(probe), identify: async () => ({ serial: probe.serial }) });
  await until(clock, () => app.store.snapshot('10005A3F'));
  assert.equal(device.state, 'connected');
  const snap = app.store.snapshot('10005A3F');
  assert.equal(snap.link.primary.kind, 'directConnection');
  assert.equal(snap.virtual.coreSensor, 't2');
  const view = app.presenter.view('10005A3F');
  assert.equal(view.state, 'predicting');
  assert.ok(view.secondsRemaining > 3 * 3600 && view.secondsRemaining < 4 * 3600, `countdown ${view.secondsRemaining}`);

  const session = app.history.currentSession('10005A3F');
  await until(clock, () => app.history.sessions.size && session && true);
  const expected = probe.logRange().max + 1;
  await until(clock, () => app.history.samples(session.key).then((s) => (session.count = s.length)) && session.count >= expected - 1, 500);
  const samples = await app.history.samples(session.key);
  assert.ok(samples.length >= expected - 1, `backfilled ${samples.length}/${expected}`);
  assert.ok(Math.abs(samples[0].time - probe.startedAt) <= 5000, 'first sample time is the cook start');

  await Promise.all([clock.advance(1000), app.commands.setPrediction('10005A3F', 'removalAndResting', 90)]);
  assert.equal(app.store.snapshot('10005A3F').prediction.mode, 'removalAndResting');
  await Promise.all([clock.advance(1000), app.commands.setAlarm('10005A3F', 'core', 'high', 50)]);
  await until(clock, () => app.alerts.instances.has('10005A3F.alarm.high.core'));
  const ack = app.alerts.acknowledge('10005A3F.alarm.high.core');
  await clock.advance(1000);
  await ack;
  assert.equal(app.store.snapshot('10005A3F').alarms.high.core.alarming, false, 'acknowledge silenced the probe');
  app.stop();
});

test('app with a node relaying two probes; reconnects after link loss', async () => {
  const clock = new FakeClock();
  const a = new SimProbe({ serial: 'AAAA0001', clock, startedAt: clock.now() - HOUR, probeNumber: 1 });
  const b = new SimProbe({ serial: 'BBBB0002', clock, startedAt: clock.now() - HOUR / 2, probeNumber: 2, color: 'grey' });
  let current = null;
  let opens = 0;
  const app = new ColbyApp({ clock });
  await app.start();
  const device = app.addDevice({
    id: 'node', name: 'Display',
    open: async () => { opens++; current = new SimNodeConnection({ serial: 'DISP01', probes: [a, b], clock, hops: 2 }); return current; },
    identify: async () => ({ serial: 'DISP01', productType: 'display' }),
  });
  await until(clock, () => app.store.snapshot('AAAA0001') && app.store.snapshot('BBBB0002'));
  assert.equal(app.store.snapshot('BBBB0002').link.primary.kind, 'nodeConnection');
  assert.equal(app.store.snapshot('BBBB0002').link.primary.hopCount, 2);
  assert.equal(app.route('AAAA0001'), device.link);
  assert.equal(app.store.nodes.get('DISP01').isConnected, true);

  await Promise.all([clock.advance(1000), app.commands.setPrediction('BBBB0002', 'timeToRemoval', 70)]);
  assert.equal(app.store.snapshot('BBBB0002').prediction.setpoint, 70);

  const session = app.history.currentSession('AAAA0001');
  await until(clock, () => app.history.samples(session.key).then((s) => (session.count = s.length)) && session.count > 700, 500);

  current.drop();
  assert.equal(device.state, 'reconnecting');
  await until(clock, () => device.state === 'connected');
  assert.equal(opens, 2);
  app.stop();
});

test('emitter once resolves null on timeout', async () => {
  const clock = new FakeClock();
  const e = new Emitter();
  const p = e.once('x', { timeoutMs: 100, clock });
  await clock.advance(150);
  assert.equal(await p, null);
  await settle();
});

test('gatt constants are lowercase', () => {
  for (const v of Object.values(GATT)) assert.equal(v, v.toLowerCase());
});

test('legacy firmware (94 B status): the link reads Session Info once and history keys the cook by it', async () => {
  const clock = new FakeClock();
  const probe = new SimProbe({ serial: '10005A3F', clock, startedAt: clock.now() - HOUR / 4, sessionId: 7, legacy: true });
  const app = new ColbyApp({ clock });
  await app.start();
  app.addDevice({ id: 'p', name: 'Probe', open: async () => new SimProbeConnection(probe), identify: async () => ({ serial: probe.serial }) });
  await until(clock, () => app.store.snapshot('10005A3F')?.session?.info?.sessionId === 7);
  await clock.advance(30_000);
  assert.equal(probe.requests.filter((r) => r === 'readSessionInfo').length, 1, 'read once per link, not per status');
  assert.deepEqual(app.history.list().map((s) => s.sessionId), [7], 'the id is adopted by the same cook');
  app.stop();
});

test('snoozing a probe alarm silences the probe and fires again when the snooze ends', async () => {
  const clock = new FakeClock();
  const probe = new SimProbe({ serial: '10005A3F', clock, startedAt: clock.now() - HOUR });
  const app = new ColbyApp({ clock });
  await app.start();
  app.addDevice({ id: 'p', name: 'Probe', open: async () => new SimProbeConnection(probe), identify: async () => ({ serial: probe.serial }) });
  await until(clock, () => app.store.snapshot('10005A3F')?.alarms);
  await Promise.all([clock.advance(1000), app.commands.setAlarm('10005A3F', 'core', 'high', 30)]);
  const id = '10005A3F.alarm.high.core';
  await until(clock, () => app.alerts.instances.get(id)?.state === 'firing');
  const snoozed = app.alerts.snooze(id, 60_000);
  await clock.advance(1000);
  await snoozed;
  await clock.advance(10_000);
  assert.equal(app.store.snapshot('10005A3F').alarms.high.core.alarming, false, 'silenced on the probe');
  assert.equal(app.alerts.instances.get(id)?.state, 'snoozed', 'kept while still tripped');
  await clock.advance(55_000);
  assert.equal(app.alerts.instances.get(id)?.state, 'firing');
  app.stop();
});

test('interleaved Instant Read and Normal advertisements keep all sensors and the mode', () => {
  const store = new ProbeStore({ clock: new FakeClock() });
  const ad = (mode, t1) => ({
    serial: 'AAAA0001', temperatures: mode === 'instantRead' ? [t1, -20, -20, -20, -20, -20, -20, -20] : [t1, 30, 30, 40, 50, 60, 70, 80],
    mode, color: 'yellow', probeNumber: 1, batteryLow: false, virtualSensors: { core: 't1', surface: 't4', ambient: 't8' },
    overheating: [], preferences: null,
  });
  let t = 0;
  for (let i = 0; i < 40; i++) {
    const mode = i % 3 === 2 ? 'normal' : 'instantRead';
    store.ingest({ serial: 'AAAA0001', source: { kind: 'advertisement', lastSeen: t }, payload: { advertisement: ad(mode, 23.5) }, receivedAt: t });
    t += 250;
    if (i < 2) continue;
    const s = store.snapshot('AAAA0001');
    assert.equal(s.mode, 'instantRead');
    assert.equal(s.instantRead, 24);
    assert.ok(s.temperatures.every((x) => x != null));
  }
  store.stop();
});
