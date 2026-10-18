# Handoff

State of the Colby planning work, for a new session. Branch: `claude/combustion-desktop-plan`.

## Done

| Area | Where |
|---|---|
| Protocol notes (BLE spec digest) | `01-protocol-notes.md` |
| API design (core, links, stores, commands, alerts, clock, recording, UI-facing additions §18) | `02-api-design.md` |
| Roadmap, decisions log, risks | `03-roadmap.md` |
| Release, TestFlight / package flights, crash reporting | `04-release-and-beta.md` |
| Test strategy | `05-test-strategy.md` |
| UX plan (current design rules: §4, §8, §13, §17.5, §18) | `06-ux-plan.md` |
| Design tokens + component specs | `design/tokens.json`, `design/components.md` |
| Design canvas (23 boards) | https://claude.ai/artifact/SptGVDutqLHwzLb7hUJeGU (private); source in `design/canvas/` |
| Screenshots (always regenerated together) | `design/screenshots/` |

## Key decisions (full list: README, 03 decisions log, 06 §1 / §17.5)

- Native per OS: Swift/SwiftUI/CoreBluetooth (macOS first), C#/WinUI 3/WinRT (Windows). Mac App Store + Microsoft Store only. Free.
- Probe direct + MeatNet nodes. Commands: set prediction, set high/low alarms, silence.
- Dark only. Official-app look: sensor colors Core `#4ea1f7`, Surface `#ffb81c`, Ambient `#f5701f`; pill readouts; scrubbable graph with dots.
- Single probe is the main case; every surface has a 1-probe version. Completion time shown next to every countdown.
- Built-in sounds only; bundled Barlow + Barlow Condensed.

## Continue the design

1. Edit boards in `design/canvas/*.dc.html` (Design Component format; see the canvas artifact's `artifact-type/reference/format.md`).
2. Publish: Artifact publish with `url` = canvas link, `root` = a folder whose `project/` holds the files (copy `design/canvas/*` into `<root>/project/`), `file_path` = changed file. Read the artifact first in a new session.
3. Get the runtime once: Artifact read, `url` = canvas link, `path` = `artifact-type/dc-runtime.js`.
4. Render: `docs/design/tools/render-all.sh <dc-runtime.js>`. Uses Playwright from `/opt/node-tools` (cloud container); change the import in `tools/shoot.mjs` elsewhere.
5. Look at every screenshot before reporting; copy any canvas change back into `design/canvas/`.

Format gotchas: SVG `<text>` with `{{holes}}` does not render, so chart labels are absolutely positioned HTML; use `defaultValue`/`defaultChecked` on static inputs; full-page screenshots cancel hover, so the hover mode resizes the viewport first.

## Open items

| # | Item |
|---|---|
| 1 | App icon / logo |
| 2 | Barlow Condensed tabular figures check in SwiftUI and WinUI (M2 spike) |
| 3 | Usability test (06 §15 U5) |
| 4 | Optional interactive prototype (U4) |

## Implementation status (macOS core, `mac/`)

| Milestone | State | Where |
|---|---|---|
| M0 captures | Blocked: no hardware. Fixtures hand-built from spec @ `eabc77d` + Android SDK tests; regenerate with `python3 spec/tools/gen_codec_fixtures/gen_all.py` | `spec/fixtures/` (330) |
| M1 codec | Done, 100% region coverage | `Sources/CombustionCodec` |
| M2 transport + adverts | Done on simulator. CoreBluetooth transport written, **never compiled** (Linux only so far) | `Sources/CombustionCoreBluetooth`, `Links/AdvertisementSource`, `Stores/ProbeStore` |
| M3 direct link + history | Done on simulator: UartClient, DirectProbeLink, SessionTracker, HistoryStore (SQLite), BackfillPlanner, DirectConnectionPolicy, CombustionApp facade, e2e tests for exit criteria | `Sources/CombustionCore`, `Tests/CombustionCoreTests/EndToEnd` |
| M5 prediction + commands | Done on simulator: `PredictionPresenter` (iOS `PredictionManager` smoothing, `readyAt`, `readySince`, stale), `Commands` (set prediction, set/replace alarms read-modify-write, silence; confirmed by next status; `CommandRouting` so a node route plugs in), e2e vs `SimulatedProbe` | `Sources/CombustionCore/Presenter`, `Commands` |
| M6 alerts | Done on simulator: `AlertEngine` (all §9 rules, probe alarms, overheat, hysteresis, sustain, ack, snooze, silence, latching Ready), `AlertSink`/`KeepAwake` protocols with notification/sound sink adapters and test doubles, default alert set | `Sources/CombustionCore/Alerts` |
| Sim | SimulatedTransport, RecordingTransport, replay format, SimulatedProbe; `swift run colby-sim` | `Sources/CombustionSim`, `Sources/ColbySim` |

Tests: `cd mac && swift test` (398, Swift 6.1.3). In a cloud container, Swift is not preinstalled and swift.org is blocked: pull the `library/swift:6.1-noble` image layers from Docker Hub's registry API and untar the toolchain layer into `/opt/swift`; apt-install the deps listed in the image's Dockerfile.

CI (`.github/workflows/mac.yml`, macOS 15 + Linux): every run ends in `startup_failure` with 0 jobs. Check repo Actions settings / spending limit. Until it runs, the CoreBluetooth module is unverified.

Spec discrepancies found while writing the codec (verify on hardware): hop count bits (followed SDKs: top 2 bits), overheat bit order (followed Android), GATT status 94 B legacy / 100 B current, node Silence Alarms has a 16 B payload, node 0x48 request is serial only.

Deviations from 02: `SessionKey` = (serial, sessionId, startedAt) since id 0 repeats; `ProbeSnapshot.instantReadFahrenheit` (Android filters °F separately); probe UART readLogs queued per link instead of `busy`.

M5/M6 decisions where the docs are silent:
- Presenter countdown error: rounding to 15 s plus holding for three statuses means the shown number is up to 22.5 s from the probe's own number (the Display uses the same rule, so they agree); the last five minutes are within ~6 s. The "±15 s over a full cook" criterion is read as "same number as the Display", pinned in `PredictionPresenterTests` and `M5PredictionAndCommandsTests`.
- Stale is detected by a 1 s timer, so `isStale` flips within 1 s of the 15 s mark.
- Resting: `restingDone` fires on `type = resting` with `state = removalPredictionDone`, or `predicting` with 0 s left. `predictionDone` ignores `type = resting`. Both latch until acknowledged. The simulator's removal-and-resting sequence (done, one sample later resting countdown, done again) is a guess; check against a real capture.
- "Active cook" (keep-awake, `probeOffline(onlyDuringCook:)`): normal mode and either prediction state inserted/warming/predicting/done, or core at least 40 °C. A quiet cook counts for 10 min.
- A probe with no source clears its probe-alarm and overheat alerts (the stale bits say nothing current); `probeOffline` covers it.
- Acknowledging a probe alarm mutes locally at once, then sends Silence Alarms; on failure it returns to firing with `AlertEvent.failure`.
- Not done: SQLite persistence of alert rules (`AlertRuleStore` protocol and in-memory store exist; `alert_rule`/`alert_event` tables unused), `LiveSnapshot` writer (02 §18), real macOS sink/keep-awake implementations (UNUserNotificationCenter, AVAudioPlayer, IOPMAssertion), NodeLink command route.

Known weak spots: `TestClock` wake ordering under a multi-threaded executor relies on yields plus an opt-in `wakeGrace` real-time pause (e2e tests); session change during an in-flight backfill on a link that stays connected is untested; `NodeSnapshot`, `DeviceInfo` not implemented.

## Next

1. Get CI running; fix CoreBluetooth compile errors on macOS 15.
2. M0 on hardware: `RecordingTransport` captures into `spec/replays/`; check the discrepancies above.
3. M4 MeatNet: `NodeLink` (UartClient node variant exists; route 0x45 from `unsolicited`), node step in ConnectionPolicy, `NodeSnapshot`.
4. M5 PredictionPresenter + Commands; M6 AlertEngine; M7 app target.
