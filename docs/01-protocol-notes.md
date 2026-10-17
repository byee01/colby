# 01. Protocol notes

What the app depends on. Source of truth: [combustion-documentation](https://github.com/combustion-inc/combustion-documentation) @ `eabc77d`. Spec is marked `:status: DRAFT`; re-check on each upstream change.

Bit numbering in the spec is 1-based from the LSB. Multi-byte fields are little-endian (confirmed in Android SDK `SensorTemperature.kt`).

## 1. Data paths

| Path | What it carries | Needs connection | Rate |
|---|---|---|---|
| Probe advertisement (mfr data, vendor `0x09C7`, product type `1`) | Serial, 8 raw temps, mode/ID/color, battery, virtual sensors, overheat mask, prefs | No | 250 ms normal; 100/100/50 ms Instant Read |
| Node advertisement (product type `2`, "repeated probe data") | Same as above per probe on the network + hop count | No | 250 ms, 100 ms if any probe in Instant Read |
| Probe GATT Probe Status notify (`00000101-CAAB-3792-3D44-97AE51C1407A`) | Above + log range, prediction status, food safe, high/low alarm arrays, session ID, sample period | Yes (direct) | Each measurement |
| Node UART `0x45` Probe Status | Same as GATT status + network info, per probe serial | Yes (to node) | Each measurement |
| UART Read Logs `0x04` (probe or node) | History records by sequence number | Yes | On demand |

Connection limits: probe "supports up to 3 simultaneous BLE connections"; node "up to 4 simultaneous incoming". The phone app and a Display may already hold some. Default to advertisements + one connection only when needed.

## 2. GATT

| Service | UUID | Chars |
|---|---|---|
| Device Information | `0x180A` (probe); node doc says `0x181A`, verify | Mfr, Model, Serial, HW rev, FW rev (Read) |
| Probe Status (probe only) | `00000100-CAAB-3792-3D44-97AE51C1407A` | `…0101…` Read/Notify |
| Nordic UART | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` | RX `…0002…` Write, TX `…0003…` Read/Notify |
| DFU | Nordic | Out of scope |

## 3. UART framing

| | Probe direct | MeatNet node |
|---|---|---|
| Request header | Sync `CA FE`, CRC16, type, len (6 B) | Sync, CRC16, type (MSB 0), **Request ID u32**, len (10 B) |
| Response header | Sync, CRC16, type, success, len (7 B) | Sync, CRC16, type (MSB 1), Request ID, **Response ID u32**, success, len (15 B) |
| CRC | CRC-16-CCITT, poly `0x1021`, init `0xFFFF`, over everything after CRC | same |
| Probe-addressed payloads | no serial | prefixed with Probe Serial u32 |

Notifications can split or merge frames. Parser must buffer and resync on `CA FE`.

## 4. Messages used in v1

| Type | Name | Direction | Payload (probe / node adds serial) |
|---|---|---|---|
| `0x03` | Read Session Information | req→resp | resp: session ID u32, sample period u16 ms |
| `0x04` | Read Logs | req→N resp | req: start seq u32, end seq u32. resp: seq u32, raw temps 13 B, prediction log 7 B |
| `0x05` | Set Prediction | req→resp | u16: setpoint 10 bit (×0.1 °C), mode 2 bit |
| `0x0B` | Set Probe High Low Alarm | req→resp | 22 B high array + 22 B low array (T1–T8, Core, Surface, Ambient) |
| `0x0C` | Silence Alarms | req→resp | none. Overheat alarms are not silenced |
| `0x45` | Probe Status (node) | notify | see §1 |
| `0x46`–`0x48` | Probe FW/HW rev, model (node) | req→resp | for probes seen only via node |
| `0x49` | Heartbeat (node) | notify | node topology; use for diagnostics only |

Not used in v1: `0x01` set ID, `0x02` set color, `0x06` over-temp, `0x07`/`0x08` food safe, `0x09` power mode, `0x0A` reset, `0x40`–`0x44`, `0x4A`+, `0x73`–`0x7B` linking, `0x80` display status.

## 5. Field decodes

| Field | Encoding |
|---|---|
| Raw temp (×8, 13 bit each, 13 B) | `°C = raw × 0.05 − 20`, range −20…369 °C. In Instant Read mode only T1 is valid (= instant read temp), others 0 |
| Mode/ID (1 B) | bits 1–2 mode (0 Normal, 1 Instant Read, 3 Error); 3–5 color; 6–8 probe ID (0 → ID 1) |
| Battery + virtual sensors (1 B) | bit 1 low battery; bits 2–8 virtual sensors |
| Virtual sensors (7 bit) | core 3 bit (0→T1 … 5→T6); surface 2 bit (0→T4 … 3→T7); ambient 2 bit (0→T5 … 3→T8) |
| Overheat (1 B) | one bit per sensor |
| Prediction status (7 B) | state 4 b; mode 2 b; type 2 b; setpoint 10 b ×0.1 °C; heat start 10 b ×0.1 °C; seconds 17 b; est. core 11 b `×0.1 − 20` °C |
| Prediction log (7 B, in log records) | virtual sensors 7 b; state 4 b; mode 2 b; type 2 b; setpoint 10 b; seconds 17 b; est. core 11 b |
| Prediction state | 0 Not Inserted, 1 Inserted, 2 Warming, 3 Predicting, 4 Removal Prediction Done, 15 Unknown |
| Prediction mode | 0 None, 1 Time to Removal, 2 Removal and Resting |
| Prediction type | 0 None, 1 Removal, 2 Resting |
| Percent to removal | `(estCore − heatStart) / (setpoint − heatStart)` |
| Alarm status (u16 each) | bit 1 Set, bit 2 Tripped (read-only), bit 3 Alarming, bits 4–16 temp: `°C = raw × 0.1 − 20` (−20…799 °C) |
| Session ID u32 | new on removal from charger; log sequence restarts. `0` = not supplied (old FW, advertising, old node). "Treat the value, not the length, as the signal." |
| Status payload length | Probe GATT: 94 B on old FW (no session/period). Node `0x45`: 99 B old node, 105 B new |

Prediction setpoint is 10 bits × 0.1 °C, so the max settable target is **102.3 °C**.

## 6. Reference behaviour in SDKs

- iOS SDK `PredictionManager.swift`: caps the prediction at 4 h; above 5 min it rounds to 15 s and updates only when `seq % 3 == 0` ("for syncing time remaining across apps, Displays"); below 5 min it counts down linearly at 200 ms ticks between 5 s status updates; marks the prediction stale after 15 s. Copy this so desktop matches the Display and phone.
- The iOS SDK (last commit 2023-08-02) has no high/low alarms and no food safe. The Android SDK (2026-10-12) does. **Use the Android SDK as the reference implementation**, not the iOS SDK.
- Instant Read filtering: iOS `InstantReadFilter.swift`, Android equivalent. Port it.
