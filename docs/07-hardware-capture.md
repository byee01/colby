# 07. Hardware capture (M0)

How to connect a Mac to real Combustion devices and record replays into `spec/replays/`. Tool status: **`colby-capture` is planned, not built.** Section 2 is its spec.

## 1. Connecting a Mac to a probe ("pairing")

There is no OS pairing. Probes and MeatNet nodes use plain BLE GATT without bonding. They never appear in System Settings → Bluetooth, and nothing should be paired there. The app scans for manufacturer ID `0x09C7` (01 §4) and connects directly.

### 1.1 Mac setup (once)

| Step | Detail |
|---|---|
| Toolchain | Xcode 16+ selected (`xcode-select -p`). `cd mac && swift build` must pass; it builds `CombustionCoreBluetooth` and `CombustionMacPlatform`. |
| Bluetooth on | Control Center → Bluetooth. |
| Permission | A command-line tool uses the Bluetooth permission of the app that launched it (Terminal, iTerm, VS Code). The first scan shows a system prompt for that app: Allow. |
| Denied or no prompt | System Settings → Privacy & Security → Bluetooth: turn on the terminal app, then quit and reopen it. |
| Reset the permission | `tccutil reset BluetoothAlways <bundle id>`, e.g. `com.apple.Terminal`, `com.googlecode.iterm2`, `com.microsoft.VSCode`. |
| Usage-string crash | If the tool is killed for accessing privacy-sensitive data without a usage description, embed an Info.plist with `NSBluetoothAlwaysUsageDescription` via linker flags `-sectcreate __TEXT __info_plist <path>`. |

The sandboxed app (M7) needs the entitlement `com.apple.security.device.bluetooth` and `NSBluetoothAlwaysUsageDescription` (04 §2). The CLI is not sandboxed and needs neither.

### 1.2 Each session

1. Lift the probe out of its charger to wake it.
2. Close the Combustion phone app, or turn off the phone's Bluetooth. The probe has a limited number of connection slots (05 §5, coexistence). Leave the phone on only when capturing the coexistence case.
3. For MeatNet captures, power on the Display or Booster and keep it within range of the probe.
4. Keep the Mac awake and on power for long cooks (lid open).
5. Run `swift run colby-capture --name <replay>` (§2).

### 1.3 Troubleshooting

| Symptom | Check |
|---|---|
| Bluetooth state `unauthorized` | Permission (§1.1). |
| Bluetooth state `poweredOff` | Bluetooth is off. |
| No adverts | Probe still in the charger or asleep; out of range; filter `--serial` wrong. |
| Adverts but connect times out | Phone app holding the slots; probe at the edge of range. |
| Connects, no status notifications | Report it: notify subscription in `CoreBluetoothGattConnection` is untested on hardware. |

## 2. `colby-capture` (spec)

Executable target `colby-capture` in `mac/Sources/ColbyCapture`, built like `colby-sim`; depends on `CombustionCore`, `CombustionCoreBluetooth`, `CombustionSim`.

### 2.1 What it does

1. Builds `CoreBluetoothTransport` with a real clock and wraps it in `RecordingTransport` (02 §16) writing to `spec/replays/<name>/`.
2. Runs `CombustionApp` on top, so the normal policy drives scanning, direct links, node links, history backfill and UART traffic. Everything that crosses the transport lands in `events.jsonl` (05 §4) before the core sees it.
3. Prints a live table like `colby-sim`: serial, probe ID/colour, source (direct / node / adv), RSSI, core / surface / ambient, prediction state and time left, battery, connection state, event count.
4. Logs Bluetooth state changes and connect / disconnect lines to stderr.
5. On Ctrl-C or `--minutes` elapsed: stops `RecordingTransport`, closes the writer, writes `meta.json` (devices seen, macOS version, adapter, `--notes`), prints the path and event counts.

It sends no commands unless asked (§2.3), so a plain capture never changes probe state.

### 2.2 Options

| Option | Default | Meaning |
|---|---|---|
| `--name <replay>` | required | Directory under `spec/replays/`. Use the names in 05 §4. Refuses to overwrite an existing directory. |
| `--serial <hex>` | all | Follow only this probe or node; repeatable. Adverts from others are still recorded. |
| `--minutes <n>` | until Ctrl-C | Stop after n minutes. |
| `--adv-only` | off | Scan only, no connections (advert fixtures, Instant Read rate). |
| `--direct-only` | off | Skip node links (forces the direct path). |
| `--notes <text>` | none | Stored in `meta.json`: firmware versions, setup, what was done when. |
| `--out <dir>` | `spec/replays` | Root directory for replays. |

### 2.3 Scripted actions (later)

Keystrokes while running, recorded as normal writes: `p` set prediction (prompts for °C), `a` set high/low alarm, `s` silence alarms. Needed for `alarm-trip-silence`.

### 2.4 Output

```
spec/replays/<name>/
  meta.json      # written on exit
  events.jsonl   # appended live; survives a crash up to the last line
```

`trace.golden.jsonl` is not written by the capture. Generate it by replaying `events.jsonl` through `SimulatedTransport` once the replay is reviewed.

`peripheral` values are CoreBluetooth UUIDs, stable per Mac only. Domain data keys on serial (02 §2), so replays stay valid on other machines.

## 3. Capture process

| Order | Replay (05 §4) | Setup |
|---|---|---|
| 1 | `adv-smoke` (throwaway) | `--adv-only --minutes 2`, probe out of charger. Proves permission, scan and decoding. |
| 2 | `instant-read` | `--adv-only`, probe in and out of hot water. |
| 3 | `out-of-range-return` | Direct; carry the probe out of range for 5+ minutes, then back. |
| 4 | `charger-new-session` | Direct; put the probe in the charger and take it out mid-capture. |
| 5 | `display-relay-2hop` | Display + Booster, probe out of the Mac's range. |
| 6 | `alarm-trip-silence` | Needs §2.3. |
| 7 | `direct-12h-brisket` | A real cook or sous-vide bath, 12 h. |
| 8 | `old-firmware-no-session` | Only if a probe on old firmware is available. |

After each capture:

1. Check the spec discrepancies in HANDOFF (hop count bits, overheat bit order, status size 94 / 100 B, node Silence payload, node 0x48) against the recorded bytes; fix the codec and `spec/tools/gen_codec_fixtures` where the hardware disagrees.
2. Add fixtures for any message or size variant not yet covered (03 M0 exit criterion: ≥ 1 per variant in 01 §4–5).
3. Commit the replay with the firmware versions in `meta.json`.
