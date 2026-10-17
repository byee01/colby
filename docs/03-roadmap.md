# 03. Roadmap

Estimates are for one experienced developer, in weeks. They assume the hardware is on hand.

## Hardware and accounts

| Item | Why |
|---|---|
| ≥ 2 Predictive Probes (ideally one V1 and one V2+) | Multi-probe, radio power variants, old vs new firmware fields |
| Display (Timer) and Booster (Charger) | MeatNet paths, hop count > 1 |
| Mac with BT 5 (Apple silicon) | Primary target |
| Windows 11 PC + one known-good BT 5 adapter (Intel AX2xx) | WinRT BLE quality varies by adapter/driver |
| Apple Developer Program | Notarization, time-sensitive notifications |
| Windows code-signing cert | MSIX / SmartScreen |

## Milestones: macOS

| # | Milestone | Scope | Exit criteria | Est. |
|---|---|---|---|---|
| M0 | Captures + fixtures | Record advertisements, GATT status, UART traffic from real devices; write `spec/fixtures` | ≥ 1 fixture per message/size variant in 01 §4–5 | 1 |
| M1 | Codec (Swift) | §4 of API doc | All fixtures pass; fuzz the framer with random split/merge | 1.5 |
| M2 | Transport + advertisements | CoreBluetooth transport, AdvertisementSource, ProbeStore (adv only) | Live 8-sensor temps for all nearby probes in a debug CLI/SwiftUI list | 1 |
| M3 | Direct link + history | DirectProbeLink, UartClient, session detection, HistoryStore + SQLite, backfill | Connect mid-cook, full graph backfilled; reconnect after out-of-range without gaps | 2 |
| M4 | MeatNet | NodeLink, merge rules, ConnectionPolicy | Probe out of Mac range but in Display range still updates + backfills via node | 2 |
| M5 | Prediction + commands | PredictionPresenter, Commands | Countdown matches Display within ±15 s over a full cook; set prediction/alarms/silence confirmed via status | 1.5 |
| M6 | Alerts | AlertEngine, rules, sinks, keep-awake | Each rule type fires/clears per fixture tests; alarm loops until ack; Mac stays awake during cook | 1.5 |
| M7 | Minimal UI + packaging | Placeholder UI over the facade (real UX later), signing, notarization, demo mode | Signed, notarized build installs and runs a cook end to end | 1.5 |
| | **macOS total** | | | **~12** |

## Milestones: Windows

The codec, stores, presenter and alert engine are re-implemented in C# against the same fixtures and the same API doc. Most design work is already done.

| # | Milestone | Est. |
|---|---|---|
| W1 | Codec (C#) against shared fixtures | 1 |
| W2 | WinRT transport + advertisements | 1.5 |
| W3 | Direct link, history, SQLite | 1.5 |
| W4 | MeatNet | 1 |
| W5 | Prediction, commands, alerts, keep-awake, toasts | 1.5 |
| W6 | Minimal UI + MSIX packaging/signing | 1.5 |
| | **Windows total** | **~8** |

Real UX design and build is not included. Budget it separately once the UX phase starts.

## Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Spec is `DRAFT` and changing (session ID added 2026-09) | Decode breaks on new FW | Length-tolerant decoders; watch upstream repo; fixture per FW version |
| iOS SDK is stale (2023) | Porting it misses alarms/food safe/session ID | Use Android SDK as reference; write the Swift codec fresh from the spec |
| Probe connection slots (3) taken by phone app + Display | Desktop can't connect | Prefer node connection; advertisement-only fallback still gives live temps |
| Instant Read wants 7.5–75 ms connection interval; neither macOS nor WinRT lets the app set it reliably | Laggy instant read over connection | Use advertisements (~83 ms) for Instant Read |
| Windows BLE adapter/driver variance | Drops, missing scan results | Supported-adapter list; diagnostics panel; reconnect policy |
| Computer sleeps mid-cook | No data, no alarms | Keep-awake assertion; warn if on battery power; `probeOffline` rule |
| Phone app and desktop both write alarms | Last writer wins | Read-modify-write + confirm via status (API §8) |
| Two native codebases drift | Different numbers on Mac vs Windows | Shared fixtures are the contract; CI runs both |
| Log time derivation drift | Graph x-axis off on long cooks | Re-anchor on every status; test against a 12 h capture |

## Open questions (not blocking API work)

| # | Question |
|---|---|
| 1 | Distribution: Mac App Store (sandbox) or Developer ID (notarized DMG)? Windows: Microsoft Store or direct MSIX? |
| 2 | Minimum OS: macOS 14+ (enables `@Observable`)? Windows 10 22H2 or Windows 11 only? |
| 3 | Food safe: show status read-only in v1, or hide? |
| 4 | History retention and export formats beyond CSV? |
| 5 | Max probes per session to design the graph for (8 per network)? |
| 6 | Menu bar / tray presence while main window is closed? (affects alert delivery) |
| 7 | Combustion trademark/name use if distributed publicly; contact `hello@combustion.inc`. |
