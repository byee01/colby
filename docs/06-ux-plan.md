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

Defaults when a probe is first followed: `predictionDone`, `probeOffline (60 s)`, `batteryLow` on; nothing written to the probe.

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
| Units | Follow region |
| Alarm sound / volume | Built-in "Chime", 80% |
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

Fonts: system UI font for text (SF Pro / Segoe UI Variable) to keep Store-native feel; one bundled numeric display font for countdown/temps is optional (licensing must allow app embedding).

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
| 1 | Who designs: you, a hired designer, or Claude-produced wireframes/prototypes (HTML) as a starting point? |
| 2 | Brand direction for the custom look: name/logo/colors for "Colby"? |
| 3 | Bundled numeric display font, or system font only? |
| 4 | Sound set: license stock sounds or commission? |
