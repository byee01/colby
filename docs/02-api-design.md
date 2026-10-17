# 02. API design

Internal API for the app core. The UI is a consumer of this API and is designed later.
Two native implementations: Swift (macOS) and C# (Windows). Both follow this document.
Shared golden test vectors keep the two in sync (§10).

## 1. Layers

```
┌──────────────────────────────────────────────────────────┐
│ UI (SwiftUI / WinUI 3)                    — later        │
├──────────────────────────────────────────────────────────┤
│ CombustionApp facade                                     │
│   ProbeStore · HistoryStore · Commands · AlertEngine     │
├──────────────────────────────────────────────────────────┤
│ Links                                                    │
│   AdvertisementSource · DirectProbeLink · NodeLink       │
│   UartClient (framing, correlation, timeouts)            │
├──────────────────────────────────────────────────────────┤
│ Codec (pure, no I/O, no clock)                           │
├──────────────────────────────────────────────────────────┤
│ BleTransport (platform)                                  │
│   macOS: CoreBluetooth    Windows: WinRT Bluetooth.LE    │
│   + SimulatedTransport for tests                         │
└──────────────────────────────────────────────────────────┘
```

Rules:
- The Codec has no dependencies. It is 100% unit-tested from shared fixtures.
- Only `BleTransport` touches OS Bluetooth APIs. Everything above it runs against `SimulatedTransport` in tests and in a demo mode.
- The UI never sees transport, links, or raw bytes. It sees `ProbeSnapshot`, `TemperatureSeries`, `PredictionView`, `AlertEvent`.
- One-way data flow: transport → codec → links → stores → UI. Commands go down through `Commands` only.

## 2. Identifiers and units

| Concept | Type | Notes |
|---|---|---|
| `ProbeSerial` | u32 | From mfr data / status. Display as 8-char uppercase hex. Primary key for a probe. |
| `NodeSerial` | string (10 chars) | MeatNet node serial. |
| `PeripheralId` | opaque string | macOS CoreBluetooth UUID / Windows BLE address. Never a key for domain data (macOS hides MACs). |
| `SessionKey` | (ProbeSerial, sessionId u32) | `sessionId = 0` means unknown; see §6.2. |
| `Seq` | u32 | Log sequence number within a session. |
| Temperature | `double` °C | Core is Celsius-only. °F is a UI concern. |
| Duration | seconds (`TimeInterval` / `TimeSpan`) | |
| Time | wall clock UTC (`Date` / `DateTimeOffset`) | Assigned by the app on receipt, plus derived times for log records (§6.3). |

## 3. Domain model

Language-neutral definition. Swift uses `struct` + `enum`; C# uses `record` + `enum`. All value types, immutable.

```
ProbeSnapshot
  serial: ProbeSerial
  probeNumber: 1..8              # from Mode/ID
  color: ProbeColor              # yellow, grey, unknown(n)
  mode: normal | instantRead | error
  temperatures: [8] °C?          # T1..T8; nil in Instant Read except T1
  instantRead: °C?               # filtered, only in instantRead mode
  virtual: VirtualTemps          # coreSensor, surfaceSensor, ambientSensor indices + their °C
  batteryLow: bool
  overheating: Set<SensorIndex>
  prediction: PredictionStatus?  # nil if only advertisement data has been seen
  alarms: AlarmConfig?           # nil until a full status has been received
  session: SessionInfo?          # sessionId, samplePeriod, logRange(min,max)
  link: LinkInfo                 # see below
  receivedAt: time
  firmware: DeviceInfo?          # fw/hw rev, model; loaded lazily

PredictionStatus
  state: notInserted | inserted | warming | predicting | removalPredictionDone | unknown
  mode: none | timeToRemoval | removalAndResting
  type: none | removal | resting
  setpoint: °C
  heatStart: °C
  rawSecondsRemaining: u32       # as sent by probe
  estimatedCore: °C
  percentToRemoval: 0..100?

PredictionView                   # what the UI shows; output of PredictionPresenter (§7)
  state, mode, type, setpoint, estimatedCore, percentToRemoval
  secondsRemaining: u32?         # smoothed/rounded; nil if not predicting or > 4 h
  isStale: bool                  # no status for 15 s

AlarmConfig
  high: [AlarmChannel: Alarm]    # AlarmChannel = t1..t8, core, surface, ambient (11)
  low:  [AlarmChannel: Alarm]
Alarm
  isSet: bool
  temperature: °C
  tripped: bool                  # read-only
  alarming: bool                 # read-only; false after silence

SessionInfo
  sessionId: u32                 # 0 = unknown
  samplePeriod: seconds
  logRange: (min: Seq, max: Seq)

LinkInfo
  sources: [LinkSource]          # all paths currently delivering data
  primary: LinkSource            # the one being used (§5)
LinkSource
  kind: advertisement | directConnection | nodeConnection | nodeAdvertisement
  via: NodeSerial?               # for node kinds
  hopCount: 1..4?
  rssi: dBm?
  highRadioPower: bool?          # +8 dBm devices; adjust RSSI thresholds
  lastSeen: time

TemperatureSample
  seq: Seq
  time: time                     # derived (§6.3)
  temperatures: [8] °C
  virtualSensors: VirtualSensorIndices
  prediction: PredictionLog      # state, mode, type, setpoint, seconds, estCore

NodeSnapshot
  serial: NodeSerial
  productType: display | booster | repeater | gauge | engine | unknown
  probes: [ProbeSerial]
  link: LinkSource
  firmware: DeviceInfo?
```

Gauge and Engine are decoded into `NodeSnapshot` only (they relay probes). Their own sensors are out of v1 scope; leave a `productType` extension point.

## 4. Codec

Pure functions. Input bytes, output domain values or a typed error. No allocation of platform objects.

```
decodeAdvertisement(mfrData: bytes) -> AdvertisementPacket | CodecError
  AdvertisementPacket = probe(ProbeAdvertisement) | repeated(ProbeAdvertisement, hopCount) | node(NodeAdvertisement) | unknown(productType)

decodeProbeStatus(bytes) -> ProbeStatusPayload | CodecError          # GATT, 94 B or newer
decodeNodeProbeStatus(bytes) -> (ProbeSerial, ProbeStatusPayload, hopCount) | CodecError   # 0x45, 99/105 B

UartFramer (stateful, but no I/O)
  push(bytes) -> [UartFrame | FramingError]                          # handles split/merged notifications, resyncs on CA FE
  variant: probe | node

encodeRequest(variant, message: UartRequest, requestId: u32?) -> bytes
decodeResponse(frame) -> UartResponse | CodecError

UartRequest  = readSessionInfo | readLogs(start, end) | setPrediction(setpoint, mode)
             | setAlarms(AlarmConfig) | silenceAlarms | readProbeFirmware | readProbeHardware | readProbeModel
             (node variant: each carries ProbeSerial)
UartResponse = sessionInfo(...) | logRecord(...) | ack(type, success) | revision(...) | ...

crc16Ccitt(bytes) -> u16
```

`CodecError`: `tooShort(expected, actual)`, `badSync`, `badCrc(expected, actual)`, `unknownMessageType(u8)`, `outOfRange(field, value)`.

Forward compatibility: unknown trailing bytes are ignored; known short payloads decode with optional fields set to nil (e.g. 94-byte status → `session = nil`).

## 5. Transport and links

### 5.1 BleTransport (platform boundary)

```
protocol/interface BleTransport
  state: stream<poweredOn | poweredOff | unauthorized | unsupported>
  startScan(filter: vendorId 0x09C7) / stopScan()
  advertisements: stream<(PeripheralId, mfrData bytes, rssi, time)>
  connect(PeripheralId, timeout) async -> GattConnection
GattConnection
  services/characteristics discovery (by UUID constants in §01)
  read(char) async -> bytes
  write(char, bytes, withResponse) async
  subscribe(char) -> stream<bytes>
  mtu: int
  disconnected: stream<reason>
  close()
```

| | macOS | Windows |
|---|---|---|
| Scan | `CBCentralManager.scanForPeripherals(withServices: nil, options: [AllowDuplicates: true])`; filter on mfr data in code | `BluetoothLEAdvertisementWatcher`, `ScanningMode = Active`, manufacturer data filter `0x09C7` |
| Connect | `CBPeripheral` | `BluetoothLEDevice.FromBluetoothAddressAsync` + `GattSession.MaintainConnection = true` |
| Permissions | `NSBluetoothAlwaysUsageDescription`; sandbox entitlement `com.apple.security.device.bluetooth` | Capability `bluetooth` in MSIX manifest (or unpackaged desktop) |
| Threading | dedicated serial `DispatchQueue`, bridged into actors | WinRT callbacks on thread pool, bridged into `Channel<T>` |

### 5.2 AdvertisementSource
Decodes every advertisement and publishes `ProbeAdvertisement` with `LinkSource.kind = advertisement | nodeAdvertisement`. Always on while the app runs. Gives live temps without using a probe connection slot.

### 5.3 DirectProbeLink
One per probe that is connected directly.
- Subscribe to Probe Status → `ProbeStatusPayload`.
- `UartClient(variant: probe)` over the UART RX/TX chars.
- Probe UART has no request ID: allow **one in-flight request per message type**; match responses by type. `readLogs` is the exception: N responses, finished when seq reaches `end` or a 2 s idle timeout.

### 5.4 NodeLink
One per connected MeatNet node.
- Subscribe UART TX; route `0x45` to the `ProbeStore` for each probe serial; `0x49` heartbeat to diagnostics.
- `UartClient(variant: node)`: random u32 request ID per request; match on Request ID; drop duplicate Response IDs (the repeater network can deliver copies).

### 5.5 UartClient
```
send(request, timeout = 3 s, retries = 1) async -> response | UartError
stream(request: readLogs, idleTimeout = 2 s) -> stream<logRecord>
```
`UartError`: `timeout`, `failure(success = 0)`, `disconnected`, `codec(CodecError)`, `busy`.

### 5.6 ConnectionPolicy
Decides what to connect to. Default policy:
1. Always scan.
2. If a MeatNet node is in range, connect to it (one connection gets all probes on the network; probe slots stay free for the phone app).
3. Else connect directly to each probe the user has selected ("followed").
4. Reconnect with backoff 1, 2, 4 … 30 s. Give up after the probe is absent from advertisements for 5 min; resume when it reappears.
5. Never hold more than 1 connection per probe.

Policy is a replaceable object so it can be tuned without touching links.

## 6. Stores

### 6.1 ProbeStore
```
probes: observable<[ProbeSerial: ProbeSnapshot]>
probe(serial) -> observable<ProbeSnapshot?>
nodes: observable<[NodeSerial: NodeSnapshot]>
follow(serial) / unfollow(serial)       # followed probes get connections, history, and alerts
followed: observable<Set<ProbeSerial>>
```
Merge rules (one probe, many sources):
- Fields only in the full status (prediction, alarms, session) come from the freshest `directConnection` or `nodeConnection`. Advertisements never clear them.
- Temperatures come from the freshest source of any kind.
- `primary` source order: directConnection > nodeConnection (lowest hop count) > advertisement > nodeAdvertisement.
- A source is dropped from `sources` after 10 s without data. A probe whose last source is dropped is shown with `link.sources = []` (offline), not removed.
- Updates are coalesced to at most 10 Hz toward the UI (Instant Read advertises every ~83 ms).

### 6.2 Session detection
- New session when `sessionId` changes (non-zero to a different non-zero).
- When `sessionId = 0` (old firmware or advertisement-only), fall back to: `logRange.max` decreases, or probe went missing for > 10 min and came back with `logRange.min` reset.
- Each session is a separate cook in `HistoryStore`.

### 6.3 HistoryStore
```
series(session: SessionKey) -> observable<TemperatureSeries>
sessions(serial?) -> [SessionSummary]          # start, end, peak core, setpoint, sample count
backfill(session) async                        # fills gaps via Read Logs
export(session, format: csv) -> file
delete(session)
```
- Records keyed by `(serial, sessionId, seq)`. Insert is idempotent.
- On connect: read `logRange`, request missing ranges in chunks of 128 records (tune on device), newest first so the graph fills from the right.
- Live records: each status carries `logRange.max`; when it advances, fetch the new seqs (direct or via node).
- **Time derivation**: logs have no timestamps. On each status, record anchor `(seq = logRange.max, time = receivedAt)`. `time(seq) = anchorTime − (anchorSeq − seq) × samplePeriod`. Keep the latest anchor per session; recompute on read, not on write.
- `TemperatureSeries` exposes `samples` plus downsampled views for long cooks: `downsampled(maxPoints)` using min/max per bucket so spikes stay visible.
- Storage: SQLite. macOS: GRDB or SQLite via `SQLite3`. Windows: `Microsoft.Data.Sqlite`. Same schema on both (§9).

## 7. PredictionPresenter
Input: `PredictionStatus` + status `seq` per probe. Output: `observable<PredictionView>`.
Port of iOS `PredictionManager` so numbers match the Display and phone app:
- `secondsRemaining = nil` unless `state = predicting` and `raw ≤ 4 h`.
- `raw > 300 s`: round to nearest 15 s; update only when `seq % 3 == 0` (or no previous value).
- `raw ≤ 300 s`: linear countdown at 200 ms ticks, aiming at `raw − 5 s` by the next 5 s status.
- `isStale = true` after 15 s with no status.
- `removalPredictionDone` and `type = resting` exposed as distinct states so alerts and UI can react.

## 8. Commands
```
setPrediction(serial, mode: timeToRemoval | removalAndResting, setpoint: °C) async throws
cancelPrediction(serial) async throws                       # mode = none
setAlarm(serial, channel: AlarmChannel, kind: high | low, temperature: °C?) async throws   # nil = unset
setAlarms(serial, AlarmConfig) async throws                 # full replace
silenceAlarms(serial) async throws
```
- Route: direct link if connected, else node link (adds serial), else throw `notReachable`.
- Validation before send: setpoint 0…102.3 °C (10 bit × 0.1); alarm −20…799 °C; throws `outOfRange`.
- `setAlarm` is read-modify-write: take the latest `AlarmConfig` from the full status, change one entry, send all 22 entries. Throw `alarmStateUnknown` if no full status yet. Race with the phone app is possible (last writer wins); after sending, wait for a status with the new value (5 s) and throw `notConfirmed` if it doesn't appear.
- All commands confirm by observing the next status, not just the UART ack.

`CommandError`: `notReachable`, `outOfRange(field)`, `alarmStateUnknown`, `notConfirmed`, `uart(UartError)`.

## 9. AlertEngine

Two alert sources, one pipeline.

| Source | Trigger | Silence/ack |
|---|---|---|
| Probe alarm | `Alarm.alarming` false→true on any channel; overheat bit set | "Silence" sends `0x0C` to the probe (silences the Display and phone too). Overheat cannot be silenced on the probe; app may mute its own sound. |
| App rule | Rule evaluated on each `ProbeSnapshot` / `PredictionView` | Local only |

App rule types for v1:

| Rule | Params | Fires when |
|---|---|---|
| `temperatureAbove` / `temperatureBelow` | channel (core/surface/ambient/Tn), °C, hysteresis (default 1 °C) | crosses threshold |
| `predictionWithin` | seconds | `secondsRemaining ≤ N` |
| `predictionDone` | — | state → removalPredictionDone |
| `restingDone` | — | resting prediction reaches 0 |
| `ambientOutOfRange` | min °C, max °C, sustain s | out of range for `sustain` |
| `stall` | window (default 30 min), min rise °C | core rose less than X over the window while predicting |
| `probeOffline` | seconds (default 60) | no source for N s while followed |
| `batteryLow` | — | battery bit set |

```
rules(serial) -> [AlertRule]
addRule(serial, AlertRule) / updateRule / removeRule
events: stream<AlertEvent>
active: observable<[AlertInstance]>
acknowledge(instanceId)           # stop sound, keep record
snooze(instanceId, duration)
silenceAll(serial)                # local + probe 0x0C if any probe alarm active
```

Alert instance state machine:
```
idle ──condition true──▶ firing ──ack──▶ acknowledged ──condition false──▶ idle
                           │ └─snooze──▶ snoozed ──timer──▶ firing (if still true)
                           └─condition false (auto-clear)──▶ idle
```
- Hysteresis on clear stops a reading that hovers at the threshold from flapping.
- Each rule fires once per crossing; re-arm only after it clears.
- Rules persist per probe and per "cook template" (later).

Output sinks (interface `AlertSink`):

| Sink | macOS | Windows |
|---|---|---|
| Notification | `UNUserNotificationCenter`, interruption level `.timeSensitive` | `AppNotificationManager` (Windows App SDK) toast, `scenario="alarm"` (stays on screen, loops sound) |
| Sound | `AVAudioPlayer`, looping until ack | `MediaPlayer` looping until ack |
| In-app | `active` list for the UI | same |

Keep-awake while any followed probe has an active session: macOS `IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep)` + `ProcessInfo.beginActivity` (no App Nap). Windows `PowerCreateRequest`/`PowerSetRequest(SystemRequired)`. If the computer sleeps, BLE stops and alerts stop. That's why keep-awake is part of the alert engine, not the UI.

## 10. Shared test vectors

```
spec/fixtures/
  advertisement/*.json      { "hex": "...", "expected": { decoded fields } }
  probe_status/*.json       incl. 94 B legacy and current sizes
  node_status/*.json        99 B and 105 B, sessionId 0 cases
  uart_frames/*.json        requests (encode) and responses (decode), split/merged notification streams
  prediction_presenter/*.json  input status sequence + timestamps → expected secondsRemaining sequence
  alert_engine/*.json       snapshot sequence + rules → expected events
```
- Swift: Swift Testing reads the folder. C#: xUnit `[MemberData]` reads the same folder.
- Seed fixtures from real captures (macOS PacketLogger, Windows `btvs`/Wireshark) and from Android SDK unit tests (`HighLowAlarmStatusTest.kt`, `GaugeAdvertisingDataTest.kt`, etc.).
- A fixture change must pass in both implementations before merge.

## 11. Persistence schema (SQLite, both platforms)

```sql
probe(serial INTEGER PRIMARY KEY, nickname TEXT, followed INTEGER, last_seen INTEGER)
session(id INTEGER PRIMARY KEY, serial INTEGER, session_id INTEGER, sample_period_ms INTEGER,
        started_at INTEGER, ended_at INTEGER, anchor_seq INTEGER, anchor_time INTEGER,
        UNIQUE(serial, session_id, started_at))
sample(session INTEGER, seq INTEGER, t1..t8 REAL, vs INTEGER, pred_state INTEGER, pred_mode INTEGER,
       pred_type INTEGER, setpoint REAL, pred_seconds INTEGER, est_core REAL,
       PRIMARY KEY(session, seq)) WITHOUT ROWID
alert_rule(id TEXT PRIMARY KEY, serial INTEGER, kind TEXT, params_json TEXT, enabled INTEGER)
alert_event(id TEXT PRIMARY KEY, rule_id TEXT, serial INTEGER, session INTEGER, fired_at INTEGER,
            cleared_at INTEGER, acked_at INTEGER, value REAL)
```
Volume: 8 temps every ~5 s × 12 h = ~8.6 k rows per cook. No issue for SQLite.

`started_at` is in the unique key because `session_id = 0` repeats across cooks on old firmware.

## 12. Concurrency model

| | Swift | C# |
|---|---|---|
| Transport callbacks | serial `DispatchQueue` | WinRT thread pool |
| Core | `actor` per link + one `actor ProbeStore` | `Channel<T>` pipelines; single-reader loop per store |
| Streams | `AsyncStream` | `IAsyncEnumerable<T>` + `IObservable<T>` (System.Reactive) |
| UI binding | `@Observable` view models on `@MainActor` | `ObservableObject` (CommunityToolkit.Mvvm) marshaled to `DispatcherQueue` |
| Cancellation | structured concurrency `Task` | `CancellationToken` everywhere |

## 13. Facade

```
CombustionApp
  start() / stop()
  bluetoothState: observable
  probes: ProbeStore
  history: HistoryStore
  predictions(serial) -> observable<PredictionView>
  commands: Commands
  alerts: AlertEngine
  diagnostics: observable<DiagnosticsSnapshot>   # links, RSSI, hop counts, UART error counts, node heartbeat topology
  demoMode: bool                                 # SimulatedTransport replaying a recorded cook
```

## 14. Swift and C# shape (sketch)

```swift
public struct ProbeSerial: Hashable, Sendable { public let raw: UInt32 }
public enum AlarmChannel: Int, CaseIterable, Sendable { case t1, t2, t3, t4, t5, t6, t7, t8, core, surface, ambient }

public protocol BleTransport: Sendable {
    var state: AsyncStream<BluetoothState> { get }
    var advertisements: AsyncStream<RawAdvertisement> { get }
    func startScan() async
    func connect(_ id: PeripheralId, timeout: Duration) async throws -> any GattConnection
}

public actor Commands {
    public func setPrediction(_ s: ProbeSerial, mode: PredictionMode, setpoint: Celsius) async throws
    public func setAlarm(_ s: ProbeSerial, _ ch: AlarmChannel, _ kind: AlarmKind, _ t: Celsius?) async throws
    public func silenceAlarms(_ s: ProbeSerial) async throws
}
```

```csharp
public readonly record struct ProbeSerial(uint Raw);
public enum AlarmChannel { T1, T2, T3, T4, T5, T6, T7, T8, Core, Surface, Ambient }

public interface IBleTransport
{
    IObservable<BluetoothState> State { get; }
    IAsyncEnumerable<RawAdvertisement> Advertisements(CancellationToken ct);
    Task StartScanAsync();
    Task<IGattConnection> ConnectAsync(PeripheralId id, TimeSpan timeout, CancellationToken ct);
}

public interface ICommands
{
    Task SetPredictionAsync(ProbeSerial s, PredictionMode mode, double setpointC, CancellationToken ct);
    Task SetAlarmAsync(ProbeSerial s, AlarmChannel ch, AlarmKind kind, double? tempC, CancellationToken ct);
    Task SilenceAlarmsAsync(ProbeSerial s, CancellationToken ct);
}
```

## 15. Code layout

```
colby/
  docs/
  spec/fixtures/
  mac/
    Package.swift
    Sources/CombustionCodec/        # no deps
    Sources/CombustionCore/         # links, stores, presenter, alert engine; depends on Codec
    Sources/CombustionCoreBluetooth/# BleTransport impl
    Sources/CombustionSim/          # SimulatedTransport, recorded cooks
    App/                            # Xcode app target (later)
  windows/
    Colby.sln
    src/Combustion.Codec/
    src/Combustion.Core/
    src/Combustion.Transport.WinRT/
    src/Combustion.Sim/
    src/Colby.App/                  # WinUI 3 (later)
    tests/
```
