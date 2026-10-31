// The web core against real hardware captures in spec/replays (probe fw v2.3.3, Display fw v2.6.0).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { FakeClock } from '../src/core/support.js';
import { ColbyApp } from '../src/core/app.js';
import { loadReplay, play } from './replay.js';

const PROBE = '1000D027';

/** Plays a capture; returns the app and the worst link diagnostics seen while links were up. */
async function run(name, { onEvent } = {}) {
  const { meta, events } = loadReplay(name);
  const devices = {};
  for (const d of meta.devices ?? []) {
    const [kind, serial] = d.name.split(' ');
    devices[d.peripheral] = kind === 'probe' ? { serial } : { serial, productType: kind };
  }
  const clock = new FakeClock();
  const app = new ColbyApp({ clock });
  await app.start();
  const worst = { decode: 0, framingErrors: 0, codecErrors: 0, links: 0 };
  const sources = new Set();
  await play({
    app, clock, events, devices,
    onEvent: (e) => {
      for (const d of app.devices.values()) {
        if (!d.link) continue;
        worst.links++;
        worst.decode = Math.max(worst.decode, d.link.statusDecodeErrors);
        worst.framingErrors = Math.max(worst.framingErrors, d.link.uart.diagnostics.framingErrors);
        worst.codecErrors = Math.max(worst.codecErrors, d.link.uart.diagnostics.codecErrors);
      }
      for (const s of app.store.snapshots().values()) for (const src of s.link.sources) sources.add(`${src.kind}${src.hopCount ?? ''}`);
      onEvent?.(e, app);
    },
  });
  app.stop();
  return { app, worst, sources, events };
}

const sessionsWithCounts = (app) =>
  Promise.all(app.history.list().reverse().map(async (s) => ({
    id: s.sessionId, stored: (await app.history.samples(s.key)).length, range: s.logRange,
  })));

test('idle-interleaved-modes: Instant Read and Normal packets give a stable snapshot', async () => {
  let checked = 0;
  let changes = 0;
  let last = null;
  await run('idle-interleaved-modes', {
    onEvent: (e, app) => {
      const s = app.store.snapshot(PROBE);
      if (e.type !== 'adv' || e.t <= 16 || !s) return; // the capture starts with 15 s of Instant Read only
      assert.ok(s.virtual.core != null && s.virtual.surface != null && s.virtual.ambient != null, `blank sensors at ${e.t}`);
      assert.equal(s.mode === 'instantRead', s.instantRead != null);
      if (last && last !== s.mode) changes++;
      last = s.mode;
      checked++;
    },
  });
  assert.ok(checked > 250, `checked ${checked}`);
  assert.ok(changes <= 1, `${changes} mode changes`);
});

test('instant-read: the filtered Instant Read value is whole degrees', async () => {
  const { app } = await run('instant-read');
  const s = app.store.snapshot(PROBE);
  assert.equal(s.mode, 'instantRead');
  assert.ok(Number.isInteger(s.instantRead) && s.instantRead > 20 && s.instantRead < 100, `${s.instantRead}`);
});

test('display-relay-1hop: node statuses decode, empty slots are dropped, history starts from statuses', async () => {
  const nodeTypes = new Set();
  const { app, worst, sources } = await run('display-relay-1hop', {
    onEvent: (_e, a) => { for (const n of a.store.nodes.values()) nodeTypes.add(`${n.serial}:${n.productType}`); },
  });
  assert.ok(worst.links > 0);
  assert.deepEqual([worst.decode, worst.framingErrors, worst.codecErrors], [0, 0, 0]);
  assert.ok(sources.has('nodeConnection1'), [...sources].join());
  assert.deepEqual([...app.store.mergers.keys()], [PROBE], 'no probe 00000000 from empty node slots');
  assert.deepEqual([...nodeTypes], ['T100000LG5:display']);
  const [cook] = await sessionsWithCounts(app);
  assert.ok(cook.stored >= 50, `stored ${cook.stored} records from statuses`);
});

test('charger-new-session (direct, 94 B statuses): two cooks, both fully backfilled', async () => {
  const { app, worst } = await run('charger-new-session');
  assert.deepEqual([worst.decode, worst.framingErrors, worst.codecErrors], [0, 0, 0]);
  const cooks = await sessionsWithCounts(app);
  assert.equal(cooks.length, 2);
  for (const c of cooks) assert.equal(c.stored, c.range.max - c.range.min + 1);
});

test('verify-session-charger: session ids are read over UART and split the cooks', async () => {
  const { app, worst } = await run('verify-session-charger');
  assert.deepEqual([worst.decode, worst.framingErrors, worst.codecErrors], [0, 0, 0]);
  const cooks = await sessionsWithCounts(app);
  assert.equal(cooks.length, 2);
  assert.ok(cooks.every((c) => c.id !== 0), JSON.stringify(cooks));
  assert.notEqual(cooks[0].id, cooks[1].id);
  for (const c of cooks) assert.equal(c.stored, c.range.max - c.range.min + 1);
});

for (const name of ['out-of-range-return', 'verify-fixes', 'verify-node-fixes', 'win-adv-only', 'win-direct-first']) {
  test(`${name}: decodes without errors`, async () => {
    const { app, worst, events } = await run(name);
    assert.ok(events.length > 50);
    assert.deepEqual([worst.decode, worst.framingErrors, worst.codecErrors], [0, 0, 0]);
    assert.ok(app.store.snapshot(PROBE), 'probe seen');
  });
}
