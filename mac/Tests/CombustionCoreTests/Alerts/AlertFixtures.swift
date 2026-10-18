import CombustionCodec
import CombustionCore
import Foundation

/// Snapshots, prediction views and an engine wired to test doubles.
enum AF {
    static let serial = ProbeSerial(0x1000_5A3F)
    static let other = ProbeSerial(0x1000_0002)

    /// T1 core, T4 surface, T5 ambient (the default virtual sensors); the other sensors follow the core.
    static func snapshot(
        _ serial: ProbeSerial = AF.serial, at: Date, core: Double? = 25, surface: Double? = 30, ambient: Double? = 40,
        t3: Double? = nil, battery: Bool = false, offline: Bool = false, mode: ProbeMode = .normal,
        prediction: PredictionStatus? = nil, alarms: AlarmConfig? = AlarmConfig(), overheating: Set<SensorIndex> = []
    ) -> ProbeSnapshot {
        var temps: [Double?] = [core, core, t3 ?? core, surface, ambient, core, core, core]
        if mode == .instantRead { temps = [core] + [Double?](repeating: nil, count: 7) }
        let virtual = VirtualTemps(
            coreSensor: .t1, surfaceSensor: .t4, ambientSensor: .t5,
            core: temps[0], surface: temps[3], ambient: temps[4])
        let source = LinkSource(kind: .directConnection, lastSeen: at)
        return ProbeSnapshot(
            serial: serial, probeNumber: 1, color: .yellow, mode: mode, temperatures: temps, virtual: virtual,
            batteryLow: battery, overheating: overheating, prediction: prediction, alarms: alarms,
            link: offline ? LinkInfo() : LinkInfo(sources: [source], primary: source), receivedAt: at)
    }

    static func view(
        _ serial: ProbeSerial = AF.serial, state: PredictionState = .predicting, type: PredictionType = .removal,
        seconds: UInt32? = nil, stale: Bool = false
    ) -> PredictionView {
        PredictionView(
            serial: serial, state: state, mode: type == .resting ? .removalAndResting : .timeToRemoval, type: type,
            setpoint: 60, estimatedCore: 40, secondsRemaining: seconds, isStale: stale)
    }

    static func prediction(_ state: PredictionState, type: PredictionType = .removal) -> PredictionStatus {
        PredictionStatus(
            state: state, mode: .timeToRemoval, type: type, setpoint: 60, heatStart: 20, rawSecondsRemaining: 0,
            estimatedCore: 40)
    }

    static func alarming(_ kind: AlarmKind, _ channel: AlarmChannel, temperature: Double = 80, _ on: Bool = true) -> AlarmConfig {
        let alarm = Alarm(isSet: true, temperature: temperature, tripped: on, alarming: on)
        return kind == .high ? AlarmConfig(high: [channel: alarm]) : AlarmConfig(low: [channel: alarm])
    }
}

/// An engine with every test double attached.
final class AlertRig: @unchecked Sendable {
    let clock = TestClock()
    let sink = RecordingAlertSink()
    let sound = FakeSoundPlayer()
    let notifications = FakeNotificationPresenter()
    let keepAwake = FakeKeepAwake()
    let silencer = FakeSilencer()
    let store = InMemoryAlertRuleStore()
    let engine: AlertEngine

    /// - Parameter defaults: seed the default alert set on follow (off by default so tests add their own rules).
    init(defaults: Bool = false, cookIdle: Duration = .seconds(600), trace: (any TraceSink)? = nil) {
        let sinks: [any AlertSink] = [sink, LoopingSoundAlertSink(sound), NotificationAlertSink(notifications)]
        let seed: (@Sendable (ProbeSerial) -> [AlertRule])? = defaults ? { @Sendable (serial: ProbeSerial) in AlertRule.defaults(for: serial) } : nil
        engine = AlertEngine(
            clock: clock, ruleStore: store, sinks: sinks, keepAwake: keepAwake, silencer: silencer, trace: trace,
            defaultRules: seed, cookIdleTimeout: cookIdle)
    }

    /// Follows the probe and adds rules.
    func follow(_ rules: [AlertRule], serial: ProbeSerial = AF.serial) async {
        await engine.setFollowed([serial])
        for r in rules { await engine.addRule(serial, r) }
    }

    func snapshot(_ serial: ProbeSerial = AF.serial, core: Double? = 25, surface: Double? = 30, ambient: Double? = 40,
                  t3: Double? = nil, battery: Bool = false, offline: Bool = false, mode: ProbeMode = .normal,
                  prediction: PredictionStatus? = nil, alarms: AlarmConfig? = AlarmConfig(),
                  overheating: Set<SensorIndex> = []) async {
        await engine.ingest(snapshot: AF.snapshot(
            serial, at: clock.now(), core: core, surface: surface, ambient: ambient, t3: t3, battery: battery,
            offline: offline, mode: mode, prediction: prediction, alarms: alarms, overheating: overheating))
    }

    func view(_ v: PredictionView) async { await engine.ingest(prediction: v) }

    var transitions: [String] { sink.transitions }
    func active() async -> [AlertInstance] { await engine.activeAlerts() }
    func state(_ id: String) async -> AlertState? {
        let all = await active()
        return all.first(where: { $0.id == id })?.state
    }
}
