# Codec fixtures

Language-neutral golden vectors for the wire codec (docs/02 §10, docs/05 §2). Swift reads them in
`mac/Tests/CombustionCodecTests`; the C# codec reads the same files. A fixture change must pass in both.

Regenerate the `advertisement/`, `probe_status/`, `node_status/` and `uart_frames/` folders with
`python3 spec/tools/gen_codec_fixtures/gen_all.py`. The generator packs bytes straight from the upstream
specs and does not use the Swift codec. Do not hand-edit generated files.

Every file is `{ "description", "source", ...}`. `source` is `spec` (built from the upstream spec),
`android-test` (bytes or values ported from the Android SDK unit tests), `hand-built` or `hardware`
(bytes captured from a real device; the replay is named in the description or the generator).

Conventions: `hex` is uppercase, no separators. Temperatures are plain °C numbers; compare numbers with
an absolute tolerance of 1e-6. Enums are strings equal to the Swift case name (`instantRead`,
`timeToRemoval`, `t1`, `core`); a color without a name is `unknown(n)`, a reserved power mode is
`reserved(n)`. Serials are 8-character uppercase hex. Optional parts that the bytes do not carry are
`null`. Rounding when encoding is half away from zero (0.1 °C and 0.05 °C steps).

An error case has `expectedError` instead of `expected`: `{"kind": "tooShort", "expected": n, "actual": m}`,
`{"kind": "badSync"}`, `{"kind": "badCrc"}`, `{"kind": "unknownMessageType", "type": n}`,
`{"kind": "outOfRange"}` or `{"kind": "missingField"}`. Only `tooShort` carries numbers that must match;
for the others compare `kind` (and `type`).

## advertisement/

`hex`: manufacturer data as the OS delivers it, **starting with the vendor ID** `C7 09`.
`expected.kind` is one of:

- `probe` (product type 1) and `repeated` (type 2, adds `hopCount` 1...4): `serial`, `temperatures[8]`,
  `mode`, `color`, `probeNumber` 1...8, `batteryLow`, `virtualSensors {core, surface, ambient}`,
  `overheating` (sorted sensor names, `null` if the byte is absent), `preferences {powerMode, highRadioPower}`
  (`null` if absent).
- `node` (types 3 to 6): `productType` (number), `nodeProductType`, `serial` (string, NULs stripped),
  `preferences` (number, display and booster only, else `null`).
- `unknown`: `productType`.

## probe_status/

`hex`: the Probe Status characteristic value (94 bytes legacy, 100 current, shorter and longer variants).
`expected`: `logRange {min, max}`, `temperatures`, `mode`, `color`, `probeNumber`, `batteryLow`,
`virtualSensors`, `prediction {state, mode, type, setpoint, heatStart, rawSecondsRemaining, estimatedCore}`,
`foodSafe` (`mode, product, serving, thresholdTemp, zValue, referenceTemp, dValue, targetLogReduction, state,
logReduction, secondsAboveThreshold, logSequence`; the four temperature/value fields are `null` in simplified
mode; the whole object is `null` for reserved enum values or a payload under 48 bytes), `overheating`,
`preferences`, `alarms {high, low}` (each maps `t1`..`t8`, `core`, `surface`, `ambient` to
`{set, tripped, alarming, temperature}`), and `session {sessionId, samplePeriodMs}`.
`session` is `null` when the bytes are absent **or the session ID is 0**.

## node_status/

`hex`: the payload of node message `0x45` (header removed): probe serial u32, then the status with a Network
Information byte after Food Safe Status (99 bytes legacy, 105 current; a 35-byte form from the oldest nodes).
`expected`: `{probeSerial, hopCount (1...4), status}` where `status` has the shape above.

## uart_frames/

`kind` selects the shape.

- `encodeRequest`: `variant` (`probe` or `node`), `request`, and for `node` also `probe` (serial) and `requestId`;
  `expectedHex` is the exact frame. `request.type` is `readSessionInfo`, `readLogs {start, end}`,
  `setPrediction {setpoint, mode}` (`none`, `timeToRemoval`, `removalAndResting`, `reserved`),
  `setAlarms {high, low}` (sparse maps of channel to `{set, temperature, tripped?, alarming?}`; channels left
  out are sent as unset at -20 °C), `silenceAlarms`, `readProbeFirmware`, `readProbeHardware` or `readProbeModel`
  (the last three only on `node`). Decoding the frame again must give the request back.
- `decodeResponse`: `variant`, `hex` (one response frame), `expected {messageType, success, requestId,
  responseId, body}`. `body.type` is `sessionInfo {probe, sessionId, samplePeriodMs}`,
  `logRecord {probe, sequence, temperatures, prediction {virtualSensors, state, mode, type, setpoint,
  rawSecondsRemaining, estimatedCore}}`, `revision {probe, kind, text}` or `ack`. `probe` is `null` on the probe
  variant. A response with `success = false` is always `ack`.
- `stream`: `variant`, `direction` (`request` or `response`; only used by `probe`, a node frame says which it is),
  `chunks` (notifications in order, hex, may be empty), `expectedFrames` (each `{direction, messageType,
  requestId, responseId, success, payloadHex}`) and `expectedErrors` (kinds in order). The framer emits one
  `badSync` per run of skipped bytes and one `badCrc` per frame whose CRC fails (the bytes after the two
  sync bytes of a bad frame are then skipped, which adds a `badSync`). A frame cut off at the end of the stream
  stays buffered and produces nothing.
