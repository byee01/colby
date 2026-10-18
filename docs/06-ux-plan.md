# 06. UX plan

Built on the facade in 02 §13. The UI only reads `ProbeSnapshot`, `PredictionView`, `TemperatureSeries`, `AlertInstance`, and calls `Commands` / `AlertEngine`.

## 1. Decisions

| Topic | Decision |
|---|---|
| Use context | Both: at the desk (normal window, menu bar/tray) and across the room (kitchen mode) |
| Main window | Graph-first |
| Visual style | Custom shared look, same on macOS and Windows |
| Cook target | Manual temperature + prediction mode only. No food presets. |
| Default graph | Core / surface / ambient per probe; all 8 sensors on demand |
| Menu bar / tray | Soonest finish + its core temp, e.g. `54° · 0:42`; click opens popover/flyout with all probes |
| Alarm | Looping sound + banner + window flash until acknowledged; kitchen mode goes full-screen color |
| Units | Follow OS region (°F for US locale, °C elsewhere); user override in Settings |
| Probe identity | Probe number + color (as on Display/phone); optional nickname per cook |
| Kitchen mode | Toggle (toolbar button + shortcut) → full screen; Esc exits |
| Theme | Dark only (light theme removed from tokens and boards) |
| Font | Bundled Barlow + Barlow Semi Condensed (SIL OFL 1.1), tabular figures for all numbers |
| Sounds | Built-in OS sounds only; nothing bundled (§17.3) |
| Live Activity equivalents | Menu bar item, popover, floating live window, desktop widgets (macOS); tray, flyout, alarm toast, widgets board, floating live window (Windows) (§17.2) |
| Design canvas | [Colby Desktop Design](https://claude.ai/artifact/SptGVDutqLHwzLb7hUJeGU) (U1 wireframes + first hi-fi pass) |

## 2. Principles

1. **Readable from 3 m in kitchen mode, dense at the desk.** Same data, two densities.
2. **The countdown is the headline.** Core temp second. Everything else on demand.
3. **An alarm is never missable while the app runs.** Sound loops, window flashes, kitchen mode floods the screen.
4. **Never show a stale number as live.** Stale and offline states are visible on every surface.
5. **Color is never the only signal.** Probe number labels on lines and tiles; line style per sensor.
6. **One look, two platforms.** Shared design tokens and component specs; platform-native only for window chrome, menus, notifications, and accessibility APIs.

## 3. Screens

| Screen | Purpose | Entry |
|---|---|---|
| Main window | Graph + probe strip + inspector | App launch, menu bar/tray click |
| Inspector (side panel) | Selected probe: 8 sensors, prediction, target, alarms, rules, battery, link | Click probe in strip or line in graph |
| Set target sheet | Manual setpoint + mode | Inspector "Set target" |
| Alarms & rules sheet | Probe high/low alarms, app rules | Inspector "Alarms" |
| Kitchen mode | Full-screen large tiles | Toolbar button, `⌘K` / `Ctrl+K` |
| Menu bar popover / tray flyout | All probes compact, active alerts, open window, kitchen mode, quit | Menu bar / tray icon |
| History | Past cooks list + read-only graph | Toolbar / menu |
| Settings | Units, sounds, notifications, login item, kitchen mode options | `⌘,` / Settings menu |
| Diagnostics | Links, RSSI, hop count, UART errors, Record session | Help menu |
| Onboarding | Bluetooth permission, first scan, follow probes | First launch |
| Demo mode | Replay recorded cook (also for Store reviewers) | Onboarding "Try demo", Help menu |

## 4. Main window (graph-first)

```
┌──────────────────────────────────────────────────────────────────────────┐
│ [Kitchen] [Live | 1h | 4h | All]  [Sensors: C/S/A | All 8]   ⏰2   ⚙     │ toolbar
├──────────────────────────────────────────────────────┬───────────────────┤
│ °F                                         now ┆     │ INSPECTOR         │
│ 203 ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄ target ┄┄ ①   │ ① Brisket  ●yellow│
│                                                ┆ ◆ ① │ 3:42 to removal   │
│ 250 ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ambient ①  │ core 165.2°F      │
│                                        ___/    ┆     │ ████████░░ 72%    │
│ 150                               ____/  core ①      │ target 203°F      │
│                         _________/             ┆     │ [Set target]      │
│  50 ___________________/                       ┆     │ [Alarms]          │
│     10:00        11:00        12:00        13:00     │ T1…T8 table       │
├──────────────────────────────────────────────────────┤ battery OK        │
│ ① Brisket 165°→203° 3:42 │ ② Ribs 180° 0:42 ⏰ │ ③ —  │ via Display, 2 hop│
└──────────────────────────────────────────────────────┴───────────────────┘
                     probe strip (one chip per followed probe)
```

- Graph ~70% of height. Probe strip below. Inspector on the right, collapsible.
- Toolbar range: `Live` follows now with a 30 min window; `1h`, `4h`, `All` fixed; drag/scroll to pan and zoom pauses Live until "Back to live".
- `◆` = predicted removal time on the time axis, per probe. Dashed horizontal = target.
- `⏰2` = active alert count; click opens the alerts list.

### 4.1 Graph spec

| Element | Rule |
|---|---|
| Series per probe | Core: solid, 2.5 px. Surface: dashed, 1.5 px. Ambient: dotted, 1.5 px. All 8 mode: thin solid T1–T8 with a lightness ramp |
| Probe color | App palette indexed by probe number 1–8 (physical colors are only yellow/grey). Physical color shown as a dot on the chip |
| Labels | Probe number badge at the right end of each core line |
| Focus | Hover or select a probe: its lines full opacity, others 25%. With > 3 probes, non-focused probes show core only |
| Target | Dashed horizontal at setpoint, probe color, labeled |
| Prediction | `◆` marker at predicted removal time; resting shown as a second marker |
| Now | Vertical line; future region shaded lightly |
| Gaps | Missing data drawn as a break, not interpolated; gap region hatched while backfill runs |
| Stale | Lines after last sample stop; chip shows "stale" |
| Hover | Crosshair; tooltip with time, core/surface/ambient for focused probe |
| Y axis | Auto range with 10% padding; includes target lines |
| Data | `TemperatureSeries.downsampled(maxPoints = pixel width × 2)` (02 §6.3) |
| Rendering | Custom renderer on both platforms for identical output: SwiftUI `Canvas` / Win2D `CanvasControl`. Not Swift Charts / third-party charts. |

### 4.2 Probe chip

`[number badge] [nickname or "Probe N"] [core°] [→ target°] [countdown] [state icon]`

| Prediction state | Chip text |
|---|---|
| notInserted | "Not inserted" |
| inserted (no target) | core temp only |
| warming | "Warming up" |
| predicting | countdown `H:MM` (from `PredictionView.secondsRemaining`) |
| removalPredictionDone | "Remove now" (accent) |
| resting | "Resting H:MM" |
| stale / offline | grey, "Stale" / "Offline 3m" |
| batteryLow | battery icon |
| overheating | red badge "Overheat" |

## 5. Set target sheet (manual)

```
Set target — ① Brisket
  Target core temp  [ 203 ] °F        range 32–216 °F (0–102.3 °C)
  Mode              (•) Time to removal   ( ) Removal + resting
  Current core 165.2 °F
                                     [Clear target]  [Cancel]  [Set]
```
- Entry in the user's unit; converted to °C, rounded to 0.1 °C, clamped to 0–102.3 °C with an inline error outside range (02 §8 `outOfRange`).
- "Set" shows a spinner until the next status confirms (02 §8); on `notConfirmed` show "Probe didn't confirm. Retry."
- "Clear target" → `cancelPrediction`.
- Optional nickname field at the top (stored per cook, see §11).

## 6. Alarms & rules sheet

Two sections, same sheet:

| Section | Content | Backed by |
|---|---|---|
| Probe alarms | Core high, Surface high/low, Ambient high/low as primary rows; T1–T8 under "Advanced". Toggle + temperature per row. Note: "Also alarms on your Display and phone app." | `setAlarm` (probe) |
| App alerts | Prediction within N min, Prediction done, Resting done, Ambient out of range for N min, Stall, Probe offline, Battery low | `AlertEngine` rules (02 §9) |

Defaults when a probe is first followed match the official app's alert set: Ready (`predictionDone`, repeats until acknowledged), 5-minute warning (`predictionWithin 300 s`), Overheat, Disconnected (`probeOffline 60 s`, only during an active cook), Low battery. Nothing written to the probe.

## 7. Alerts

| Surface | Behavior |
|---|---|
| Sound | Loops until acknowledged or snoozed. Settings: sound choice, volume, "play even when Do Not Disturb" (macOS time-sensitive). |
| OS notification | Banner with "Acknowledge" and "Snooze 5 min". macOS `.timeSensitive`; Windows toast `scenario="alarm"`. |
| Window flash | macOS: `NSApp.requestUserAttention(.criticalRequest)` (Dock bounce) + in-window red top band. Windows: `FlashWindowEx` taskbar flash + in-window red top band. |
| Main window | Red band: "② Ribs: Remove now  [Acknowledge] [Snooze]". Chip pulses. |
| Kitchen mode | Whole screen floods alert color with the probe tile enlarged; any key / click / space = acknowledge. |
| Menu bar / tray | Icon turns red; popover lists active alerts first. |
| Probe alarms | "Acknowledge" on a probe alarm sends `silenceAlarms` (silences the Display/phone too). Overheat: app sound can be muted, banner stays. |

Order when several fire: overheat > probe alarms > prediction done > other rules; newest first within a level.

## 8. Kitchen mode

```
┌────────────────────────────────────────────────────────────┐
│  ① BRISKET                      ② RIBS                     │
│     3:42                           REMOVE NOW              │
│     165°  → 203°                   181°                    │
│  ███████████░░░░ 72%                                       │
│                                                            │
│  ③ CHICKEN                       ④ —                       │
│     0:58                           Not inserted            │
│     152°  → 162°                                           │
└────────────────────────────────────────────────────────────┘
```
- 1 probe: single tile + mini graph. 2: side by side. 3–4: 2×2. 5–8: 2×4.
- Countdown ≥ 120 pt at 1 probe, ≥ 72 pt at 8 on a 13" laptop; core temp ~50% of countdown size.
- Keeps display awake while shown (`IOPMAssertion` display sleep / `SetThreadExecutionState(ES_DISPLAY_REQUIRED)`).
- High-contrast dark by default; follows light/dark setting optionally.
- Esc exits; mouse movement shows a minimal overlay (exit, probe focus).

## 9. Menu bar (macOS) / tray (Windows)

| | macOS | Windows |
|---|---|---|
| Resting text | `54° · 0:42` = soonest-finishing probe's core + countdown. No prediction: most recently active probe's core temp. Nothing followed: icon only. | Tray icons cannot show text. Icon reflects state (idle / cooking / alert); tooltip shows `54° · 0:42`. |
| Click | Popover: compact probe list, active alerts, buttons: Open, Kitchen mode, Quit | Flyout with same content (H.NotifyIcon / custom XAML flyout) |
| Alert | Text and icon red | Icon red + toast |

Platform difference noted: Windows gets less glanceable info; the toast carries the alert.

## 10. Onboarding and empty / error states

First launch:
1. Welcome: what the app does, "Works with Combustion thermometers" (not affiliated).
2. Bluetooth explainer → system permission prompt.
3. Scanning: probes appear live as found (number, color, core temp). "Follow" each (defaults: follow all found).
4. Notification permission asked when the first alert rule is enabled (or on finish, if defaults are on). Not at launch.
5. Optional: "Start Colby at login" (off by default). Hint that closing the window keeps it in the menu bar/tray.
6. "Try demo mode" link on every screen until a probe is found.

| State | UI |
|---|---|
| Bluetooth off | Full-window message + "Open Bluetooth settings" |
| Bluetooth unauthorized | Message + "Open Privacy settings" (macOS) / "Open Bluetooth & devices" (Windows) |
| Scanning, nothing found | "Take a probe out of its charger to wake it." + demo link |
| Probe offline | Chip grey "Offline 3m"; graph line ends; alert rule `probeOffline` |
| Prediction stale | Countdown greyed with "stale" |
| Backfilling history | Hatched gap + "Loading history…" in chip |
| Connection slots full | Inspector: "Probe is busy (3 connections). Showing live temps only." |
| Command failed | Inline in sheet, retry |

## 11. History

- List: date, nickname(s), duration, peak core, target; per row: probes in that cook.
- Detail: same graph component, read-only, with prediction markers and alert events on the timeline.
- Delete with confirm. No export in v1.
- API impact: add `nickname TEXT` to the `session` table (02 §11).

## 12. Settings

| Setting | Default |
|---|---|
| Prediction time | "Ready in" (countdown) primary, "Ready at" (clock) secondary; setting swaps them. No toggle in the main UI |
| Units | Follow region |
| Alarm sound / volume | Built-in per event (§17.3), 80% |
| Alert when Do Not Disturb is on | On (macOS time-sensitive; Windows alarm toast) |
| Start at login | Off |
| Kitchen mode theme | Dark |
| Keep computer awake during cook | On |
| Show in menu bar / tray | On (required for background alerts; warn if turned off) |

## 13. Custom shared design system

Tokens defined once, generated for both platforms.

```
design/
  tokens.json          # color, type scale, spacing, radius, motion, probe palette 1–8, alert colors
  components.md        # spec per component: anatomy, states, sizes, a11y labels
  build/               # generated: Swift (Color/Font extensions), XAML ResourceDictionary
```

| Token group | Notes |
|---|---|
| Color | Light + dark sets; probe palette 1–8 checked for ≥ 3:1 against both backgrounds and for color-blind separation; alert red/amber; stale grey |
| Type | One scale incl. kitchen sizes (72–160 pt); tabular numerals for temps and countdowns |
| Spacing / radius | 4 pt grid |
| Motion | Pulse for alerting chip; respects Reduce Motion / Windows animation setting |

Fonts: bundled Barlow (text) and Barlow Semi Condensed (numbers), SIL OFL 1.1, which allows embedding in apps. Tabular figures on for every number.

Components (each with Swift + WinUI implementation): `ProbeChip`, `ProbeTile` (kitchen), `TempGraph`, `Countdown`, `ProgressBar`, `AlertBand`, `TempField` (unit-aware input), `SensorTable`, `MenuBarSummary`.

Gallery screen in debug builds renders every component in every state on both platforms, for visual parity checks (screenshot diff in CI optional).

## 14. Accessibility

- VoiceOver / Narrator labels: "Probe 1, Brisket, core 165 degrees, 3 minutes 42 seconds to removal, target 203".
- Countdown announcements at most once per minute; alerts announced immediately.
- Full keyboard: Tab through chips, arrow keys between probes, `Space` acknowledge, `⌘K/Ctrl+K` kitchen, `⌘1–8/Ctrl+1–8` select probe.
- Text scales with system text size (macOS accessibility text size, Windows text scaling).
- Contrast: text ≥ 4.5:1, graph lines ≥ 3:1.
- Never color alone: number badges, line styles, state text.

## 15. UX phases

| # | Phase | Output | Est. (weeks) |
|---|---|---|---|
| U1 | IA + low-fi wireframes | All screens in §3, states in §10 | 1 |
| U2 | Design system | `tokens.json`, component specs, palette validation | 1.5 |
| U3 | Hi-fi mockups | macOS + Windows, light/dark, kitchen mode, 1/3/8 probes | 2 |
| U4 | Interactive prototype | Clickable flows: onboarding, set target, alarm fire + ack, kitchen mode | 1 |
| U5 | Usability test | 5 users, real cook or demo replay, desk + across-room distance check | 1 |
| U6 | Handoff | Final specs, redlines, asset export | 0.5 |
| | **Design total** | | **~7** |

Build impact (custom look vs. placeholder UI already in M7/W6): about +4 weeks macOS, +3 weeks Windows (custom graph renderer, kitchen mode, component library, gallery).

## 16. Open questions

| # | Question |
|---|---|
| 1 | Logo / app icon for "Colby" (canvas uses a placeholder thermometer glyph) |
| 2 | Confirm Barlow tabular figures render identically in SwiftUI and WinUI (U2 check); fallback: Archivo (OFL) |

## 17. Design pass 1 (canvas)

### 17.1 References from the official Combustion app

No screenshots could be fetched (combustion.inc and app stores are blocked from the planning environment). References are from text sources; visuals are Colby's own.

| Reference | Source | Type | Used as |
|---|---|---|---|
| "Target temp (cooking to) and predicted (ready-in) time are now visible on the graph" | [Product release notes](https://combustion.inc/pages/product-release-notes) | Primary | Labels "Cooking to" / "Ready in"; target line + ready marker on graph |
| Predictions in relative ("ready in") or absolute "clock" time | [App Store listing](https://apps.apple.com/us/app/combustion-inc/id1658858290) | Primary | Settings choice of primary format; the other shown at lower emphasis |
| Live Activities: "live cooking data for one of your probes" on Lock Screen, Watch, Dynamic Island | [Product release notes](https://combustion.inc/pages/product-release-notes) | Primary | One-probe floating live window, menu bar compact item |
| Live Activities gained "temperature trend lines" (v3.3.0) | [Update history](https://combustioninc.gorgias.help/en-US/combustion-app-update-history-1614818) | Primary (vendor help center) | Trend sparkline on every live surface and kitchen tile |
| Live Activities follow in-app device order; rounding fix between Live Activity and app | [App Store listing](https://apps.apple.com/us/app/combustion-inc/id1658858290) | Primary | Same order and same rounding on every surface (shared formatter) |
| Alerts: ready, 5-minute warning, overheat, disconnect (after 60 s in a cook), low battery; persistent ready alarm | [Product release notes](https://combustion.inc/pages/product-release-notes) | Primary | Default alert set (§6) |
| Graph scrubbing | [Product release notes](https://combustion.inc/pages/product-release-notes) | Primary | Hover crosshair + tooltip |

### 17.2 Live Activity equivalents

| iOS surface | macOS | Windows |
|---|---|---|
| Dynamic Island compact | Menu bar item: badge + core + countdown (`141° · 0:38`); accent when ready; red when alarming | Tray icon color (idle / cooking / alarm) + tooltip |
| Dynamic Island expanded | Menu bar popover: alert row, all probes with trend, actions | Tray flyout, same content |
| Lock Screen Live Activity | Floating live window (always on top, one probe or up to 3), ⌥⌘L | Same floating window component |
| Home/Lock widgets | WidgetKit desktop widgets, small (1 probe) and medium (3 probes) | Widgets board card (Windows App SDK widget provider) |
| Alert banner | Time-sensitive notification + in-app loop | Alarm-scenario toast with looping audio |

Widgets: countdown uses a self-updating timer text; temperatures refresh on ≥ 1° change within the OS refresh budget. The floating window and menu bar are the real-time surfaces.

API impact: WidgetKit extension + App Group shared container for a small snapshot file (macOS); Windows widget provider COM server declared in the MSIX manifest. Both read a `LiveSnapshot` (probe n, name, core, target, state, ready time, last 30 core samples) written by the core at most once per 5 s.

### 17.3 Sounds (built-in only)

| Event | macOS (in-app loop, `NSSound(named:)`) | Windows toast audio | Repeats |
|---|---|---|---|
| Ready | Glass | `ms-winsoundevent:Notification.Looping.Alarm` | Until acknowledged |
| Overheat | Sosumi | `Notification.Looping.Alarm2` | Until acknowledged |
| Probe high/low alarm | Hero | `Notification.Looping.Alarm3` | Until acknowledged |
| 5-minute warning | Ping | `Notification.Reminder` | Once |
| Disconnected, low battery | Basso | `Notification.Default` | Once |
| Custom rule | Submarine | `Notification.Reminder` | Once |

macOS notification banners use `UNNotificationSound.default` (system sound names are not addressable by the notification API); the looping sound plays in-app, which works because Colby stays resident. System sound files are played by name, never copied into the bundle.

### 17.4 Canvas contents

| Board | Shows |
|---|---|
| Main window · 1 probe | Most common case; same layout with one chip |
| Main window · 3 probes | Graph-first layout, hover crosshair, chip selection; tweaks: probes 1/3/8, alerting, time format (stands in for the setting) |
| Main window · alarm firing | Red alert band, alerting chip |
| Main window · 8 probes | Non-focused probes core-only, end-label de-collision |
| Kitchen mode · 1 probe | Dedicated full-window layout |
| Kitchen mode · 4 probes / alarm | 2×2 tiles with trend lines; full-screen red takeover |
| Live Activity equivalents · macOS | Menu bar states, popover, floating window, widgets |
| Live Activity equivalents · Windows | Tray states, tooltip, flyout, widgets board, alarm toast |
| Set target · Alarms & alerts | Unit-aware target entry with range validation, mode choice, probe alarms, desktop alerts, sound picker |
| Onboarding · 4 steps | Welcome (demo link, not-affiliated line), Bluetooth (with denied-state banner), find thermometers (follow checkboxes, Display listed as relay), background (menu bar, login opt-in; notification permission deferred to first alert) |
| History | Cook list (title, date, duration, peak); detail with stat tiles, read-only graph, alert events on the timeline and as a list; Rename, Delete |
| Settings | Sections: General (units, prediction time with preview, menu bar, login, keep awake), Alerts and sounds (volume, Do Not Disturb, sound per event, default alerts for new probes), Devices (followed probes, MeatNet nodes), History and data, Diagnostics (links, Record session), About |
| Design tokens | Colors, validated probe palette (dark + light), type scale, sound map, spacing |

Completion time: the chosen format is primary; the other is always shown beside or under it, muted and smaller. Applies to every surface:

| Surface | Primary | Secondary |
|---|---|---|
| Main inspector, kitchen tiles | `3:42` | `at 5:02 PM` (or `5:02` + `PM · in 3:42`) |
| Probe chips | `3:42` | none (no room) |
| Menu bar item | `165° · 3:42` | `5:02` (muted, no AM/PM) |
| Popover / tray flyout rows | `3:42` | `at 5:02 PM` under it; ready rows show `since 1:18 PM` |
| Floating live window, widgets, Widgets board | `3:42` | `at 5:02 PM` |
| Tray tooltip | `ready in 3:42` | `(5:02 PM)` |
| Alarm toast | n/a | time reached in body |
| Graph markers | clock time | n/a |

Single probe is the most common case. Every surface has a 1-probe version, listed first. Kitchen mode with 1 probe uses a dedicated full-window layout: name and core temperature in the header, 400 px countdown with 72 px secondary time, progress bar and wide trend line.

Screenshots: `docs/design/screenshots/`, regenerated together from the current canvas every time (`render-all.sh` in the scratchpad). Set: Main1, Main1-hover, Main1At, Main, MainAlert, Main8, Kitchen1, Kitchen1At, Kitchen, KitchenAlert, LiveActivity, WindowsSurfaces, Sheets, Tokens, Onboarding, History, History-hover, Settings, SettingsAlerts, SettingsDevices.

### 17.5 Alignment with the official app (design pass 2)

From user-supplied screenshots of the official Combustion app (primary).

| Rule | Value |
|---|---|
| Line color = sensor | Core `#4ea1f7` blue, Surface `#ffb81c` yellow, Ambient `#f5701f` orange; 3 px solid |
| Readout row | Colored pill label (black text) over a large condensed number; three columns split by vertical rules |
| Graph | Rounded card, light grid, axis labels `250°` / `13:00`, target as a light horizontal line labeled at the right (`203°`) |
| Scrub / hover | Vertical line with a white-ringed dot on each series; readouts switch to the scrubbed values; label above graph shows state + time (`Predicting / 11:24`); leaving the graph returns to live (`Now · 13:20`) |
| One probe per graph | Graph shows the selected probe's 3 sensors; probe chips switch the selection (replaces the per-probe palette) |
| Probe identity | Neutral badge with the probe number; ring = physical probe color (yellow / grey) |
| Background | Pure black window, `#161616` cards, radius 28 for cards |
| Type | Barlow (text) + Barlow Condensed (numbers) |
| Time | Follows OS 12/24 h; mocks use 24 h as in the references |
| History list | Probe icon, title (nickname, else "Predictive Cook" / "Manual Cook"), duration with stacked unit (`hrs/min`, `min/sec`), target with gauge icon, `7d ago • 11 Oct 06:10`, 3-line thumbnail |
| History detail | Readouts + scrubbable graph + Start · date / End / Duration card |
| Status | Ready `#5fd17a`, critical `#e5484d`; primary button white on black |

Palette check: contrast ≥ 3:1 on `#161616` and color-blind separation pass; the lightness-band check fails because the official colors are brighter than the reference band. Accepted: every line is also labeled by its pill.


Next: empty and error states board; then U2 (tokens.json + component specs).
