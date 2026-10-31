# Colby: Combustion desktop app (planning)

Desktop app for Combustion Inc. Predictive Thermometers. macOS first, Windows second.
Planning and documentation only. No code yet.

| Doc | Contents |
|---|---|
| [01-protocol-notes.md](01-protocol-notes.md) | BLE facts the app depends on, pulled from the upstream spec |
| [02-api-design.md](02-api-design.md) | Internal API: layers, domain model, codec, transport, commands, history, alerts |
| [03-roadmap.md](03-roadmap.md) | Milestones, estimates, risks, decisions log |
| [04-release-and-beta.md](04-release-and-beta.md) | TestFlight / package flight path, CI, crash reporting, release checklist |
| [05-test-strategy.md](05-test-strategy.md) | Test layers, parity traces, replays, hardware matrix, emulator rig |
| [06-ux-plan.md](06-ux-plan.md) | UX decisions, screens, graph spec, alerts, kitchen mode, design system, accessibility |
| [design/](design/) | `tokens.json`, `components.md`, canvas source (`canvas/`), render tools (`tools/`), screenshots |
| [HANDOFF.md](HANDOFF.md) | Current state and how to continue in a new session |
| [../web/README.md](../web/README.md) | Web version: static files, Web Bluetooth, feature support table |

## Decisions so far

| Topic | Decision |
|---|---|
| Stack | Native per OS. macOS: Swift + SwiftUI + CoreBluetooth. Windows: C# (.NET 8+) + WinUI 3 + WinRT `Windows.Devices.Bluetooth`. |
| Devices v1 | Predictive Probe direct, plus probes relayed by MeatNet nodes (Display/Timer, Booster/Charger). |
| Control v1 | Read everything. Write: set prediction, set high/low alarms, silence alarms. |
| Alerts v1 | Desktop notification + sound. App-side custom rules in addition to probe alarms. No phone push/webhooks. |
| Food safe v1 | Read-only display. Configuration stays in the Combustion phone app. |
| Min OS | macOS 14+, Windows 11. |
| Distribution | Mac App Store only (sandboxed). Microsoft Store only (MSIX). |
| Pricing | Free. No in-app purchase code. |
| Name | "Colby - Desktop monitor for Combustion thermometers". Own name, no Combustion logo, no claim of official status. |
| Probes | Design for up to 8 at once (probe ID range 1–8). |
| Background | Lives in menu bar (macOS) / system tray (Windows) when the window is closed; alerts keep firing. Start at login is opt-in, off by default. |
| History | Keep everything until the user deletes it. Export deferred. |
| Beta | macOS TestFlight (internal → external). Windows Microsoft Store package flights. See 04. |
| Crash reporting | Store-provided only: Xcode Organizer / TestFlight, Partner Center Health. No third-party SDK. |
| UX | Graph-first window, custom shared look, dark only, kitchen mode, manual target only. See 06. |

## Upstream sources (primary)

| Source | Commit | Date | License |
|---|---|---|---|
| [combustion-documentation](https://github.com/combustion-inc/combustion-documentation) (BLE specs) | `eabc77d` | 2026-09-28 | n/a |
| [combustion-android-ble](https://github.com/combustion-inc/combustion-android-ble) (Kotlin SDK) | `4139a3e` | 2026-10-12 | MIT |
| [combustion-ios-ble](https://github.com/combustion-inc/combustion-ios-ble) (Swift SDK) | `797416a` | 2023-08-02 | MIT |

`combustion.inc/pages/developer` could not be fetched from the planning environment. The GitHub repos above are what it links to.
