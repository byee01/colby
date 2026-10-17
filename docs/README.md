# Colby: Combustion desktop app (planning)

Desktop app for Combustion Inc. Predictive Thermometers. macOS first, Windows second.
Planning and documentation only. No code yet.

| Doc | Contents |
|---|---|
| [01-protocol-notes.md](01-protocol-notes.md) | BLE facts the app depends on, pulled from the upstream spec |
| [02-api-design.md](02-api-design.md) | Internal API: layers, domain model, codec, transport, commands, history, alerts |
| [03-roadmap.md](03-roadmap.md) | Milestones, estimates, risks, open questions |

## Decisions so far

| Topic | Decision |
|---|---|
| Stack | Native per OS. macOS: Swift + SwiftUI + CoreBluetooth. Windows: C# (.NET 8+) + WinUI 3 + WinRT `Windows.Devices.Bluetooth`. |
| Devices v1 | Predictive Probe direct, plus probes relayed by MeatNet nodes (Display/Timer, Booster/Charger). |
| Control v1 | Read everything. Write: set prediction, set high/low alarms, silence alarms. |
| Alerts v1 | Desktop notification + sound. App-side custom rules in addition to probe alarms. No phone push/webhooks. |
| UX | Deferred. |

## Upstream sources (primary)

| Source | Commit | Date | License |
|---|---|---|---|
| [combustion-documentation](https://github.com/combustion-inc/combustion-documentation) (BLE specs) | `eabc77d` | 2026-09-28 | n/a |
| [combustion-android-ble](https://github.com/combustion-inc/combustion-android-ble) (Kotlin SDK) | `4139a3e` | 2026-10-12 | MIT |
| [combustion-ios-ble](https://github.com/combustion-inc/combustion-ios-ble) (Swift SDK) | `797416a` | 2023-08-02 | MIT |

`combustion.inc/pages/developer` could not be fetched from the planning environment. The GitHub repos above are what it links to.
