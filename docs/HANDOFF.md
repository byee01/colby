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
| Hardware capture: connecting to devices, `colby-capture`, capture order | `07-hardware-capture.md` |
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
| M0 captures | In progress: steps 1-4 of 07 §3 captured (4 replays in `spec/replays/`); 3 bugs found and fixed on simulator, not yet re-checked on hardware. Next: verify, then step 5. Fixtures hand-built from spec @ `eabc77d` + Android SDK tests; regenerate with `python3 spec/tools/gen_codec_fixtures/gen_all.py` | `spec/fixtures/` (330) |
| M1 codec | Done, 100% region coverage | `Sources/CombustionCodec` |
| M2 transport + adverts | Done on simulator. CoreBluetooth transport written, **never compiled** (Linux only so far) | `Sources/CombustionCoreBluetooth`, `Links/AdvertisementSource`, `Stores/ProbeStore` |
| M3 direct link + history | Done on simulator: UartClient, DirectProbeLink, SessionTracker, HistoryStore (SQLite), BackfillPlanner, DirectConnectionPolicy, CombustionApp facade, e2e tests for exit criteria | `Sources/CombustionCore`, `Tests/CombustionCoreTests/EndToEnd` |
| M4 MeatNet | Done on simulator: NodeLink, NodeSnapshot/DeviceInfo (`ProbeStore.nodes`, `CombustionApp.nodes`), node-first step in `DirectConnectionPolicy` (`ProbeConnectionState.viaNode`), node-routed backfill in `LinkRouter`/`LinkCoordinator`, e2e `M4MeatNetTests` | `Links/NodeLink.swift`, `Policy/ConnectionPolicy.swift`, `Sources/CombustionSim/SimulatedNode.swift` |
| M5 prediction + commands | Done on simulator: `PredictionPresenter` (iOS `PredictionManager` smoothing, `readyAt`, `readySince`, stale), `Commands` (set prediction, set/replace alarms read-modify-write, silence; confirmed by next status; `CommandRouting` so a node route plugs in), e2e vs `SimulatedProbe` | `Sources/CombustionCore/Presenter`, `Commands` |
| M6 alerts | Done on simulator: `AlertEngine` (all §9 rules, probe alarms, overheat, hysteresis, sustain, ack, snooze, silence, latching Ready), sink adapters, default alert set; `SQLiteAlertStore` (rules with order, configured-set marker, alert log via `consume(alerts.events)`, `events(for:in:)` for history), schema v2; `LiveSnapshotWriter` (02 §18; immediate on state change, else every 5 s; 30-point trend); macOS adapters `UserNotificationPresenter`, `SystemSoundPlayer`, `PowerAssertionKeepAwake`, `LiveSnapshotLocation` (**never compiled**, Apple-only) | `Sources/CombustionCore/Alerts`, `Widgets`, `Sources/CombustionMacPlatform` |
| Sim | SimulatedTransport, RecordingTransport, replay format, SimulatedProbe; `swift run colby-sim` | `Sources/CombustionSim`, `Sources/ColbySim` |

Tests: `cd mac && swift test` (449; Swift 6.1.3 Linux, 6.2.4 macOS). In a cloud container, Swift is not preinstalled and swift.org is blocked: pull the `library/swift:6.1-noble` image layers from Docker Hub's registry API and untar the toolchain layer into `/opt/swift`; apt-install the deps listed in the image's Dockerfile.

## CI status (blocked)

Workflows: `.github/workflows/mac.yml` (macOS 15 + Linux `swift:6.1-noble`), `windows.yml` (windows-latest + Linux, .NET 8).

Symptom: every run on `claude/combustion-desktop-plan` ends `startup_failure` with 0 jobs (13+ runs, latest after `6e29041`). The API lists **0 registered workflows**; runs show an empty name and path `BuildFailed`. Both YAML files parse. Billing exhaustion normally fails jobs with a billing message instead, so settings or a run-page error are the likelier cause.

Billing facts (private repo), from [GitHub docs](https://docs.github.com/en/billing/concepts/product-billing/github-actions):
- Each plan includes monthly free minutes for private repos; GitHub Free ≈ 2,000 min/month (secondary copy of the docs; confirm on the current page).
- macOS runners consume minutes at 10×, Windows at 2×, Linux 1× (≈ 200 macOS minutes on Free).
- Monthly-billed accounts default to a **$0 spending limit**: no usage past the included minutes.
- Public repos: standard GitHub-hosted runners are free.

Owner checklist, in order:
1. Open a failed run (e.g. https://github.com/byee01/colby/actions/runs/39106182658) and read the error banner; it is the only place the real reason appears.
2. Settings → Actions → General: Actions enabled; allowed actions include `actions/checkout`, `actions/setup-dotnet` (or allow all).
3. Settings → Billing → Actions: minutes used; set a small spending limit if exhausted.
4. Still failing: merge the workflow files to `main` (workflows register from the default branch), or make the repo public.
5. Workaround without CI: `cd mac && swift test` on a Mac with Xcode 16.

On a Mac (Xcode, Swift 6.2.4, macOS 26, 2026-10-20): `swift build` passes, so `CombustionCoreBluetooth` and `CombustionMacPlatform` compile, and `swift test` passes all 446. `colby-capture` reaches `poweredOn`; no device heard yet.

Local toolchain in this kind of container: `/opt/swift/usr/bin` (add to `PATH`); `swift test` takes ~35 s.

## Implementation notes

Spec discrepancies found while writing the codec (verify on hardware): hop count bits (followed SDKs: top 2 bits), overheat bit order (followed Android), GATT status 94 B legacy / 100 B current, node Silence Alarms has a 16 B payload, node 0x48 request is serial only.

Hardware findings (probe `1000D027`, fw v2.3.3, hw v11.0-A1, macOS 26; replays in `spec/replays/`):
- GATT status is 94 B on fw v2.3.3 (617 of 617 in `out-of-range-return`). 100 B not seen yet.
- **Fixed (Mac):** an idle or Instant-Read probe interleaves Instant Read (mode 1, ~70 %) and Normal (mode 0) adverts several times a second; Normal packets can be 6 s apart at idle and 18 s apart in Instant Read (`idle-interleaved-modes`, `instant-read`). `ProbeMerger` took the mode of the latest packet, so surface/ambient blanked and `mode` flipped ~70 times in 2 min. Now as in the iOS SDK (`Probe.swift`): Normal packets set T1-T8 and keep them, Instant Read packets set only `instantRead`, and `mode = instantRead` until 5 s pass without one. Pinned by `ProbeStoreTests.capturedInterleavedAdvertsGiveAStableSnapshot` (feeds the real replay).
- Backfill works on hardware: 318 records (0-317), none missing, across a 6-minute gap and 6 edge-of-range drops. One record every 5.0 s.
- **Fixed (Mac):** while connected, the app sent a Read Logs for each new record (94 writes in 15 min, some repeated). Now a Normal status is stored as the record at `logRange.max` (iOS SDK `addDataToLog`), and the live fetch asks only for seqs below it that are missing. Trade-off: that one record holds the status's values, not the probe's logged ones (same as the SDK).
- macOS delivers ~3.9 adverts/s from one probe (spec: 4-10/s).
- New session after a charger cycle (`charger-new-session`): link dropped ~50 s after the probe went in the charger, adverts stopped, and on removal the log range restarted at 0 (max 351 -> 1). `SessionTracker` caught it by log-range regression and backfill restarted at record 0.
- **Fixed (Mac):** the 94 B status carries no session ID and nothing read it, so every session had id 0. `DirectProbeLink` now reads Session Info (UART 0x03) on the first status without one and fills it into later statuses; it re-reads if the log range goes backwards. Simulator: `SimulatedProbe.statusWithoutSession` models this firmware; e2e `sessionIdIsReadOverUartWhenTheStatusHasNone`. Not done: node path (`NodeLink.readSessionInfo(probe:)` exists, nothing calls it) and the SDK's 3-minute re-read. Open: fw v2.3.3 is current, so the "94 B = legacy" label in the spec digest may be wrong.
- Windows has the same three bugs (ported from the same design); port the fixes and tests for parity.

Deviations from 02: `SessionKey` = (serial, sessionId, startedAt) since id 0 repeats; `ProbeSnapshot.instantReadFahrenheit` (Android filters °F separately); probe UART readLogs queued per link instead of `busy`.

M5/M6 decisions where the docs are silent:
- Presenter countdown error: rounding to 15 s plus holding for three statuses means the shown number is up to 22.5 s from the probe's own number (the Display uses the same rule, so they agree); the last five minutes are within ~6 s. The "±15 s over a full cook" criterion is read as "same number as the Display", pinned in `PredictionPresenterTests` and `M5PredictionAndCommandsTests`.
- Stale is detected by a 1 s timer, so `isStale` flips within 1 s of the 15 s mark.
- Resting: `restingDone` fires on `type = resting` with `state = removalPredictionDone`, or `predicting` with 0 s left. `predictionDone` ignores `type = resting`. Both latch until acknowledged. The simulator's removal-and-resting sequence (done, one sample later resting countdown, done again) is a guess; check against a real capture.
- "Active cook" (keep-awake, `probeOffline(onlyDuringCook:)`): normal mode and either prediction state inserted/warming/predicting/done, or core at least 40 °C. A quiet cook counts for 10 min.
- A probe with no source clears its probe-alarm and overheat alerts (the stale bits say nothing current); `probeOffline` covers it.
- Acknowledging a probe alarm mutes locally at once, then sends Silence Alarms; on failure it returns to firing with `AlertEvent.failure`.
- Alert log rows: one per firing (a return from snooze reuses the open row); `session` column is left NULL, history joins by serial and time range.
- macOS notifications use the default sound (system sound names are not addressable by UserNotifications); the loop plays in-app via `NSSound`. Needs the time-sensitive notification entitlement and an App Group for the widget snapshot.
- Not done: alert-rule editing UI and sound per rule kind (`AlertSound` has 4 cases; 06 §17.3 lists 6 events: 5-minute warning, disconnected and low battery should play once, not loop).

Known weak spots: `TestClock` wake ordering under a multi-threaded executor relies on yields plus an opt-in `wakeGrace` real-time pause (e2e tests); session change during an in-flight backfill on a link that stays connected is untested; node heartbeat (0x49) payload is not decoded (layout not in our spec digest); `ProbeSnapshot` has no per-probe `DeviceInfo` yet (node 0x46-0x48 reads exist in the codec but nothing calls them).

## Windows status

| Milestone | State | Where |
|---|---|---|
| W1 codec (C#) | Done: `Combustion.Codec` port, tests against the shared `spec/fixtures`, framer fuzz, round trips | `windows/` |
| W2 base + transport | Done: clock, deterministic context, streams, models, SQLite, ProbeStore; WinRT BLE transport (**compiles on Linux, never run on Windows or hardware**) | `src/Combustion.Core`, `src/Combustion.Transport.WinRT` |
| W3/W4 links + MeatNet | Done: UartClient, AdvertisementSource, DirectProbeLink, NodeLink, ConnectionPolicy, Commands, LinkRouter, LinkCoordinator, CombustionApp facade | `src/Combustion.Core` |
| History | Done: SessionTracker, BackfillPlanner, HistoryStore | `src/Combustion.Core/Stores` |
| W5 prediction + alerts | Done: PredictionPresenter, AlertEngine, SQLite alert store, LiveSnapshot; platform adapters (alarm toasts, looping system sounds, power-request keep-awake, app data paths; **compiled on Linux only**) | `src/Combustion.Core`, `src/Combustion.Windows.Platform` |
| Sim | Done: SimulatedTransport, SimulatedProbe, SimulatedNode, RecordingTransport, replay format | `src/Combustion.Sim` |
| W6 app | Not started (WinUI 3, tray, MSIX) | |

Tests: `cd windows && dotnet test Colby.sln -c Release` (.NET 8, Linux OK): 1,242 passing (codec 966, core 231, sim 45). Gaps vs Swift: no end-to-end `CombustionApp` tests (Swift has M3–M6 e2e suites); `AlertSound` has the same 4-case gap. Conventions for the port: `windows/PORTING.md`.

## Next

1. Get CI running (or `swift test` on a Mac, `dotnet test` on Windows); fix compile errors in the Apple-only and Windows-only modules (CoreBluetooth, MacPlatform, Transport.WinRT, Windows.Platform).
2. M0 on hardware, verify the three fixes first (probe next to the Mac, `cd mac && swift build`):
   - `swift run colby-capture --name verify-fixes --direct-only --minutes 3`. In the table, surface/ambient never show `-` after the first Normal packet, and `prediction` shows the probe's state without flicker.
   - In `events.jsonl`: one Read Session Info write (message type byte 4 = `03`) answered by a type-03 response; Read Logs writes only at connect (the history before it), not one per status.
   - Session id: after the run, the snapshot/meta shows a non-zero id; repeat the charger cycle (07 §3 step 4) and expect a second session with a different id.
   - Then delete `spec/replays/verify-fixes` or keep it as the first post-fix replay.
3. Continue 07 §3 at step 5 (`display-relay-2hop`, needs a Display and a Booster; with only a Display, capture a 1-hop `display-relay-1hop`), then step 6 (12 h cook). Scripted commands (07 §2.3) are needed for `alarm-trip-silence`. Check the node path for the same session-ID gap.
4. Split `AlertSound` per 06 §17.3 (looping vs once).
5. Windows: port the three hardware fixes above, then the Swift end-to-end suites (M3–M6) to C#.
6. M7: SwiftUI app target from `docs/design/` (tokens, components, canvas), menu bar extra, widgets extension; then W6 (WinUI 3).
