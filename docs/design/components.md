# Components

Specs for the shared UI components. Values reference `tokens.json` by path (`color.sensor.core`, `type.readout`, …). Each component is implemented twice (SwiftUI, WinUI) and shown in every state in the debug gallery. Boards in parentheses are on the [design canvas](https://claude.ai/artifact/SptGVDutqLHwzLb7hUJeGU); screenshots are in `screenshots/`.

Formatting rules for every component:
- Temperatures: user unit, whole degrees except Instant Read (one decimal). Degree sign, no unit letter except in sentences ("203°F").
- Times: OS 12/24 h. Durations `H:MM`; under 1 h `M:SS` only where the unit label says `min/sec`.
- Numbers use `font.numeric` with tabular figures.

## ProbeBadge
- Anatomy: circle 26 px (`badge.fill`), probe number (`type.chipValue` scaled to 15), 2 px ring in physical color (`badge.ringYellow` / `badge.ringGrey`).
- Sizes: 20 (menu bar, rows), 26 (chips, headers), 64 (kitchen single).
- A11y: part of the parent label ("Probe 1").

## ReadoutRow (Main, History)
- Anatomy: 3 equal columns; each = sensor pill (`radius.pill`, bg `color.sensor.*`, text `sensor.pillText`, `type.label`) over value (`type.readout`). Columns split by 3 px `color.line` rules.
- States: live; scrubbing (values at pointer); not inserted (`—`); offline (40% opacity, last values).
- A11y: "Core 165 degrees, surface 178, ambient 249"; announced on scrub at most every 500 ms.

## TempGraph (Main, History)
- Anatomy: card (`color.card`, `radius.card`); state/time label above plot; plot with grid, y and x labels (`type.axis`), target line + right-edge label, 3 series (`stroke.series`).
- Interaction: pointer move = scrub (vertical line, ringed dot per series, ReadoutRow + label update); leave = live/end. Keyboard: focusable; ←/→ step 1 sample, Shift = 10. Drag/scroll = pan/zoom (pauses Live).
- States: live; scrubbing; All 8 sensors (others `sensor.other`, 1.5 px, end labels T1–T8); gap (break); backfilling (hatched region + progress); stale (lines stop).
- Data: downsampled to 2× pixel width, min/max per bucket.
- Rendering: SwiftUI `Canvas` / Win2D `CanvasControl`.

## ReadyBlock (Main header, popover, live window, widgets)
- Anatomy: caption ("Ready in" / "Ready at" / "Remove now" / "Warming"), primary time (`type.countdown`), secondary time (`type.secondaryTime`, "at 17:02" or "in 3:42").
- States: predicting; ready (`status.ready`, "since 13:18"); warming; no target (hidden); stale (greyed + warning line).
- Primary format comes from Settings → Prediction time.

## ProbeChip (Main, > 1 probe)
- Anatomy: card (`color.card`, `radius.chip`, min width 220); row 1 badge + name; row 2 core (`color.sensor.core`, `type.chipValue`) → target (muted) and status (right).
- States: default, selected (border `text2`, bg `raised`), alerting (border `status.critical`), offline (grey), overheat (red pill), low battery (amber icon + label).
- Click selects the probe for the graph. A11y: "Probe 2, Ribs, Ready".

## KitchenTile (Kitchen, Kitchen1)
- Multi: badge, name, caption, countdown (`type.kitchenCountdown`) + secondary, core (blue) → target, progress bar, core trend line.
- Single: dedicated layout; Core pill + core 104 px in header; countdown `type.kitchenCountdownSingle`, secondary `type.kitchenSecondarySingle`; bar 16 px; trend 110 px.
- Ready: border + caption + value in `status.ready`. Alarm: full-screen `kitchenAlarmBg`, "READY", Snooze/Acknowledge; any key acknowledges.

## InstantReadView (InstantRead, KitchenInstant)
- Shown while `ProbeSnapshot.mode = instantRead`. Integer part `type.instantRead`, decimal + degree at 40% size in `text2`. "Instant Read" outline pill. Last 30 s sparkline (main window only). No readouts, prediction or history.

## AlertBand (MainAlert)
- Full-width bar under the toolbar: `status.criticalBg`, 2 px bottom border `status.critical`; bell icon, title, detail, Snooze (secondary), Acknowledge (primary).
- Order: overheat > probe alarm > ready > other. One band; count in toolbar bell.

## StatusPanel (States)
- Centered empty state in the graph area: icon, title (`type.title`), one-line instruction, one primary action. Used for Bluetooth off, not allowed, nothing found.

## InlineNotice (States)
- Rounded box in context: warning (`status.warning*`) for stale/low battery, critical for command failures and overheat, neutral (`raised`) for "probe busy". Always icon + text.

## MenuBarItem / TrayIcon (LiveActivity, WindowsSurfaces)
- macOS: pill with badge, core, countdown, completion time (muted). Ready: green pill. Alarm: red pill with bell.
- Windows: icon only; color grey (idle) / brand (cooking) / critical (alarm); tooltip text per 06 §9.

## PopoverList / TrayFlyout
- Alert row (if any) on top; one row per probe: badge, name, core → target, core sparkline, primary time with secondary under it; actions Open / Kitchen mode / Live window / Quit.
- 1 probe: single large row with ReadyBlock.

## LiveWindow (floating)
- Always on top. 1 probe: name, target, ReadyBlock, core, %, sparkline, progress. 3 probes: 3 columns.

## Widgets
- macOS small (1 probe), medium (1 probe with trend, or 3 rows); Windows Widgets board card (1 probe, or rows). Countdown/completion use self-updating timer text; temperatures from `LiveSnapshot`.

## HistoryRow / HistoryDetail (History)
- Row: probe icon, title, duration + stacked unit, target gauge (predictive), relative date + date/time, 3-line thumbnail (150×84, `radius.chip`).
- Detail: header, ReadoutRow, TempGraph (end-of-cook default), Start · date / End / Duration card, alert list, Rename, Delete.

## Sheets (Sheets)
- SetTarget: name field, target field with unit and range help, mode radio cards, Clear / Cancel / Set. Pending spinner until confirmed; failure = InlineNotice with Retry.
- Alarms & alerts: probe alarms (toggle + temperature), desktop alerts (toggle + description), sound picker with Preview.

## Toggle, Segmented control, Buttons
- Toggle 44×26, on `toggleOn`, off `toggleOff`. Segmented: `radius.control`, selected `raised`. Buttons: primary white, secondary raised, danger red text. All ≥ 44 px hit target in kitchen and sheets, ≥ 36 px in toolbars.
