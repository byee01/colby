// Runs every golden vector in spec/fixtures against the JS codec (same files as the Swift and C# suites).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import {
  CodecError, hexToBytes, bytesToHex, decodeAdvertisement, encodeAdvertisement, decodeProbeStatus,
  encodeProbeStatus, decodeNodeProbeStatus, encodeNodeProbeStatus, encodeRequest, decodeRequest, decodeResponse,
  encodeResponse, encodeFrame, UartFramer, ALARM_CHANNELS, unsetAlarm, crc16Ccitt,
} from '../src/codec/index.js';

const FIXTURES = fileURLToPath(new URL('../../spec/fixtures/', import.meta.url));

function load(folder, kind) {
  const dir = join(FIXTURES, folder);
  return readdirSync(dir)
    .filter((f) => f.endsWith('.json'))
    .sort()
    .map((f) => ({ name: `${folder}/${f}`, root: JSON.parse(readFileSync(join(dir, f), 'utf8')) }))
    .filter((f) => !kind || f.root.kind === kind);
}

/** First structural difference, numbers within 1e-6. With `subset`, keys missing from `expected` are ignored. */
export function firstDifference(expected, actual, { path = '$', subset = false } = {}) {
  if (typeof expected === 'number' && typeof actual === 'number') {
    return Math.abs(expected - actual) <= 1e-6 ? null : `${path}: expected ${expected}, got ${actual}`;
  }
  if (Array.isArray(expected) && Array.isArray(actual)) {
    if (expected.length !== actual.length) return `${path}: expected ${expected.length} elements, got ${JSON.stringify(actual)}`;
    for (let i = 0; i < expected.length; i++) {
      const d = firstDifference(expected[i], actual[i], { path: `${path}[${i}]`, subset });
      if (d) return d;
    }
    return null;
  }
  if (expected && actual && typeof expected === 'object' && typeof actual === 'object' && !Array.isArray(expected) && !Array.isArray(actual)) {
    for (const key of Object.keys(expected).sort()) {
      if (!(key in actual)) return `${path}.${key}: missing in actual`;
      const d = firstDifference(expected[key], actual[key], { path: `${path}.${key}`, subset });
      if (d) return d;
    }
    if (!subset) {
      const extra = Object.keys(actual).find((k) => !(k in expected));
      if (extra) return `${path}.${extra}: not in expected`;
    }
    return null;
  }
  return expected === actual ? null : `${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`;
}

const renderError = (e) => ({ ...e, kind: e.kind });

function checkDecode(fixture, decode) {
  const { root } = fixture;
  let actual;
  try {
    actual = decode(hexToBytes(root.hex ?? ''));
  } catch (e) {
    if (!(e instanceof CodecError)) throw e;
    assert.ok(root.expectedError, `${fixture.name}: unexpected ${e.message}`);
    assert.equal(firstDifference(root.expectedError, renderError(e), { subset: true }), null, fixture.name);
    return null;
  }
  assert.ok(!root.expectedError, `${fixture.name}: expected an error, decoded ${JSON.stringify(actual)}`);
  if (root.expected) assert.equal(firstDifference(root.expected, actual), null, `${fixture.name}: ${root.description}`);
  return actual;
}

test('fixture folders are populated', () => {
  for (const [folder, minimum] of [['advertisement', 50], ['probe_status', 60], ['node_status', 30], ['uart_frames', 100]]) {
    assert.ok(load(folder).length >= minimum, folder);
  }
});

for (const f of load('advertisement')) {
  test(`advertisement ${f.name}`, () => {
    const decoded = checkDecode(f, decodeAdvertisement);
    if (decoded && (decoded.kind === 'probe' || decoded.kind === 'repeated')) {
      // Re-encoding gives a packet that decodes the same.
      assert.equal(firstDifference(decoded, decodeAdvertisement(encodeAdvertisement(decoded))), null, f.name);
    }
  });
}

/** Raw alarm values above 799 °C decode but are rejected on encode (as in Swift). */
const encodable = (s) => ['high', 'low'].every((k) => Object.values(s.alarms[k]).every((a) => a.temperature <= 799));

for (const f of load('probe_status')) {
  test(`probe status ${f.name}`, () => {
    const s = checkDecode(f, decodeProbeStatus);
    if (s && s.foodSafe && s.alarms && s.preferences && s.overheating && encodable(s)) {
      const again = decodeProbeStatus(encodeProbeStatus(s, s.session ? 'current' : 'legacy'));
      assert.equal(firstDifference(s, again), null, `${f.name}: round trip`);
    }
  });
}

for (const f of load('node_status')) {
  test(`node status ${f.name}`, () => {
    const n = checkDecode(f, decodeNodeProbeStatus);
    const s = n?.status;
    if (s && s.foodSafe && s.alarms && s.preferences && s.overheating && encodable(s)) {
      const again = decodeNodeProbeStatus(encodeNodeProbeStatus(n, s.session ? 'current' : 'legacy'));
      assert.equal(firstDifference(n, again), null, `${f.name}: round trip`);
    }
  });
}

/** What decoding a setAlarms request gives back: every channel present, read-only bits false unless sent. */
function normalized(request) {
  if (request.type !== 'setAlarms') return request;
  const fill = (side) => Object.fromEntries(ALARM_CHANNELS.map((ch) => {
    const a = side?.[ch];
    return [ch, a ? { set: a.set ?? false, tripped: a.tripped ?? false, alarming: a.alarming ?? false, temperature: a.temperature } : unsetAlarm()];
  }));
  return { type: 'setAlarms', high: fill(request.high), low: fill(request.low) };
}

for (const f of load('uart_frames', 'encodeRequest')) {
  test(`encodeRequest ${f.name}`, () => {
    const { root } = f;
    const opts = { probe: root.probe ?? null, requestId: root.requestId ?? null };
    if (root.expectedError) {
      assert.throws(() => encodeRequest(root.variant, root.request, opts), (e) =>
        e instanceof CodecError && firstDifference(root.expectedError, renderError(e), { subset: true }) === null);
      return;
    }
    const bytes = encodeRequest(root.variant, root.request, opts);
    assert.equal(bytesToHex(bytes), root.expectedHex, f.name);
    const out = new UartFramer(root.variant, 'request').push(bytes);
    assert.equal(out.length, 1, f.name);
    const decoded = decodeRequest(out[0].frame);
    assert.equal(firstDifference(normalized(root.request), decoded.request), null, f.name);
    assert.equal(decoded.probe, root.variant === 'node' ? root.probe : null);
    assert.equal(decoded.requestId, root.variant === 'node' ? root.requestId : null);
  });
}

for (const f of load('uart_frames', 'decodeResponse')) {
  test(`decodeResponse ${f.name}`, () => {
    const { root } = f;
    const out = new UartFramer(root.variant, 'response').push(hexToBytes(root.hex));
    assert.equal(out.length, 1, `${f.name}: framer output ${JSON.stringify(out)}`);
    let response;
    try {
      response = decodeResponse(out[0].frame);
    } catch (e) {
      if (!(e instanceof CodecError)) throw e;
      assert.ok(root.expectedError, `${f.name}: unexpected ${e.message}`);
      assert.equal(firstDifference(root.expectedError, renderError(e), { subset: true }), null, f.name);
      return;
    }
    assert.ok(!root.expectedError, `${f.name}: expected an error`);
    assert.equal(firstDifference(root.expected, response), null, f.name);
    const again = new UartFramer(root.variant, 'response').push(encodeResponse(response, root.variant));
    assert.equal(again.length, 1);
    assert.equal(firstDifference(response, decodeResponse(again[0].frame)), null, `${f.name}: round trip`);
  });
}

for (const f of load('uart_frames', 'stream')) {
  test(`framer stream ${f.name}`, () => {
    const { root } = f;
    const framer = new UartFramer(root.variant, root.direction === 'request' ? 'request' : 'response');
    const frames = [];
    const errors = [];
    for (const chunk of root.chunks ?? []) {
      for (const o of framer.push(hexToBytes(chunk))) {
        if (o.frame) {
          const { direction, messageType, requestId, responseId, success, payload } = o.frame;
          frames.push({ direction, messageType, requestId, responseId, success, payloadHex: bytesToHex(payload) });
          // Every emitted frame re-encodes to bytes the framer accepts again.
          const again = new UartFramer(root.variant, framer.direction).push(encodeFrame(o.frame));
          assert.equal(firstDifference({ frame: o.frame }, again[0]), null, `${f.name}: re-encode`);
        } else {
          errors.push(o.error.kind);
        }
      }
    }
    assert.equal(firstDifference(root.expectedFrames, frames), null, `${f.name} frames`);
    assert.equal(firstDifference(root.expectedErrors, errors), null, `${f.name} errors`);
  });
}

test('crc16 check value', () => {
  // CRC-16/CCITT-FALSE of "123456789".
  assert.equal(crc16Ccitt([...'123456789'].map((c) => c.charCodeAt(0))), 0x29b1);
});
