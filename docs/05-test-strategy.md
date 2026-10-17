# 05. Test strategy

Test the pure layers hard without hardware, prove the two platforms match by diffing their outputs, and use real hardware only where the OS Bluetooth stack is involved.

Depends on two API features (02 §15, §16): an injectable `Clock` and a recording `BleTransport`.

## 1. Layers

| # | Layer | Scope | Method | Gate |
|---|---|---|---|---|
| 1 | Codec | Every message and field; payload sizes 94/99/105 B; session ID 0; edges: −20/369 °C, setpoint 102.3 °C, alarm −20/799 °C, 17-bit seconds max | Shared fixtures (`spec/fixtures`); encode↔decode round-trip properties; framer fuzz: random split/merge, bad CRC, garbage, resync on `CA FE` | PR |
| 2 | Core logic | ProbeStore merge rules, session detection, backfill gaps, log time derivation, PredictionPresenter, AlertEngine states (hysteresis, snooze, re-arm), Commands (read-modify-write, confirm, routing) | `SimulatedTransport` + `TestClock` | PR |
| 3 | Fault injection | Disconnect mid-log download, dropped/duplicated notifications, duplicate node responses, timeouts, BT powered off, probe connection slots full, old node FW | Fault hooks in `SimulatedTransport`; one scripted scenario per fault | PR |
| 4 | Cross-platform parity | Swift and C# produce identical behavior | Both run the same replay and emit a normalized event trace (§3); CI diffs traces | PR |
| 5 | Recorded-cook replay | Real captures: 12 h cooks, Instant Read, probe + Display, out-of-range episodes | Replay files (§4) at 100× via `TestClock` | Nightly |
| 6 | Soak / performance | 8 probes × 12 h | Synthetic 8-probe replay; assert memory ceiling, CPU, DB size, UI update rate ≤ 10 Hz | Nightly |
| 7 | Real BLE | CoreBluetooth and WinRT adapters | Hardware matrix (§5); optional emulator rig (§6) | Pre-beta |
| 8 | App host | Launch, demo mode, menu bar / tray, login item, keep-awake, notifications | XCUITest / WinAppDriver smoke on demo mode; `pmset -g assertions` and `powercfg /requests` checks; notifications manual | Pre-beta |
| 9 | Beta | Real cooks by external testers | TestFlight / package flights; checklist in 04 §6 | Release |

## 2. Fixtures

Defined in 02 §10. Rules:
- One fixture per message type × payload size variant × edge value.
- Seeds: captures from M0, Android SDK unit tests (`HighLowAlarmStatusTest.kt`, `GaugeAdvertisingDataTest.kt`, …), hand-built edge cases.
- Fixture changes must pass in both implementations in the same PR.

## 3. Event trace (parity format)

Both implementations expose a test-only trace sink that writes one JSON line per observable output:

```json
{"t": 12.500, "kind": "probe", "serial": "10005A3F", "core": 54.35, "state": "predicting"}
{"t": 12.500, "kind": "prediction", "serial": "10005A3F", "secondsRemaining": 1815, "stale": false}
{"t": 61.000, "kind": "alert", "rule": "r1", "transition": "idle->firing", "value": 57.1}
{"t": 70.200, "kind": "command", "op": "silenceAlarms", "result": "confirmed"}
```

- `t` is `TestClock` seconds since replay start, so it is the same on both platforms.
- Floats rounded to 2 decimals; keys sorted; serials uppercase hex.
- CI: run every replay in `spec/replays/` on `mac-test` and `win-test`, upload traces, diff in a final job. Any difference fails the build.
- Golden traces are committed next to the replays; changing one needs a reviewer to approve the behavior change.

## 4. Replay format

Produced by `RecordingTransport` (02 §16) from real devices or by the synthetic generator.

```
spec/replays/<name>/
  meta.json        # device list, FW versions, OS, adapter, notes
  events.jsonl     # {"t": 0.083, "type": "adv"|"notify"|"write"|"connect"|"disconnect"|"state", "peripheral": "...", "char": "...", "hex": "..."}
  trace.golden.jsonl
```

`SimulatedTransport` replays `events.jsonl`. Writes from the app are matched against recorded writes (by message type, not request ID) and answered with the recorded responses.

Minimum replay set before M7:

| Replay | Purpose |
|---|---|
| `direct-12h-brisket` | Long cook, prediction lifecycle, time derivation drift |
| `display-relay-2hop` | MeatNet path, hop count, duplicate responses |
| `instant-read` | High-rate advertisements, filter, coalescing |
| `out-of-range-return` | Gap + backfill |
| `charger-new-session` | Session change mid-capture |
| `old-firmware-no-session` | Session ID 0 fallback |
| `alarm-trip-silence` | Probe alarm tripped, silenced from app and from Display |
| `synthetic-8-probe-12h` | Soak |

## 5. Hardware matrix (manual, before each beta)

| Axis | Values |
|---|---|
| Probe radio | V1 (+0 dBm), V2+ (+8 dBm) |
| Probe FW | Oldest supported (no session ID), current |
| Path | Direct; via Display; via Booster; 2+ hops |
| macOS | 14, 15, 26 |
| Windows 11 | 23H2, 24H2 |
| Windows adapter | Intel AX2xx built-in; one common USB BT 5 dongle |
| Coexistence | Combustion phone app connected at the same time (connection slots, alarm write race) |
| Power | On battery; lid closed (expect keep-awake warning) |

Controlled temperatures: sous-vide bath for stable readings and step changes to trip alarms and drive predictions.

Results go in a table per beta build (pass/fail + notes) attached to the release.

## 6. Optional emulator rig (≈ 2 weeks)

- nRF52840 dongle running Zephyr firmware that advertises and serves GATT per 01: acts as probe or node.
- Scriptable from the host over USB serial: set temps, change session, drop connection, delay/duplicate responses.
- Self-hosted CI runners (Mac mini, Windows 11 PC) run the real `CoreBluetoothTransport` / `WinRtTransport` against it nightly.
- Covers the BLE adapters without a physical probe and produces failures real hardware cannot reproduce on demand.

## 7. Coverage targets

| Area | Target |
|---|---|
| Codec | 100% branch |
| Core | Every merge rule, state transition, rule type, command error has a scenario |
| Transport adapters | Thin; covered by layer 7 only |

## 8. Out of scope

Prediction accuracy. The probe firmware computes it. Tests only check that the app decodes and presents it the same way as the Display and phone app (02 §7).

## 9. Milestone mapping

| Milestone | Test work |
|---|---|
| M0 | Capture replays §4; seed fixtures |
| M1 / W1 | Layer 1 |
| M2–M6 / W2–W5 | Layers 2–3 per feature; trace sink; parity job once W1 lands |
| M5 | `TestClock` presenter scenarios vs Display timing |
| M6 / W5 | Alert scenarios; keep-awake checks |
| M7 / W6 | Layers 5–6 nightly; layer 8 smoke; first hardware matrix run |
