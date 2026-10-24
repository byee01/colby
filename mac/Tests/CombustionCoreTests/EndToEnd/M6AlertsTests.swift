import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// M6 exit: each rule type fires and clears (see Alerts/), an alarm loops until acknowledged, and the Mac stays
/// awake during a cook. Here the whole path: simulated probe -> link -> store -> presenter -> engine -> sinks.
struct M6AlertsTests {
    final class Doubles: @unchecked Sendable {
        let events = RecordingAlertSink()
        let sound = FakeSoundPlayer()
        let notifications = FakeNotificationPresenter()
        let keepAwake = FakeKeepAwake()

        var sinks: [any AlertSink] { [events, SoundAlertSink(sound), NotificationAlertSink(notifications)] }
    }

    private func rig(_ d: Doubles) throws -> E2ERig {
        try E2ERig(alertSinks: d.sinks, keepAwake: d.keepAwake)
    }

    private func connect(_ rig: E2ERig, preload: Int = 20) async throws -> SimulatedProbe {
        let probe = rig.probe(serialA, preload: preload)
        await rig.app.start()
        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(20)))
        await rig.run(.seconds(10))
        return probe
    }

    // MARK: Probe alarm: loops until acknowledged, ack silences the probe

    @Test func probeAlarmLoopsUntilAcknowledgedAndAckSilencesTheProbe() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        try await rig.app.commands.setAlarm(serialA, channel: .ambient, kind: .high, temperature: 30)

        let id = "\(serialA.hex).alarm.high.ambient"
        let fired = await rig.run(until: { d.sound.playing[id] != nil }, limit: .seconds(300), step: .seconds(5))
        #expect(fired, "the trip reaches the sound sink")
        #expect(d.sound.playing[id] == .probeAlarm)
        #expect(d.notifications.visible[id] != nil)
        #expect(await rig.app.alerts.activeAlerts().first?.state == .firing)

        // Two minutes later it is still going: nothing but the user stops it.
        await rig.run(.seconds(120))
        #expect(d.sound.playing[id] == .probeAlarm)
        #expect(d.sound.history.filter { $0 == "start \(id)" }.count == 1)

        await rig.app.alerts.acknowledge(id)
        #expect(d.sound.playing.isEmpty, "muted at once")
        // Silence Alarms reached the probe and its status shows the alarm quiet.
        let silenced = await rig.eventually { probe.requests.contains(.silenceAlarms) }
        #expect(silenced)
        #expect(await rig.run(until: { await rig.app.alerts.activeAlerts().isEmpty }, limit: .seconds(30), step: .seconds(1)),
                "cleared once the probe reports alarming = false")
        #expect(probe.currentAlarms.high[.ambient]?.alarming == false)
        #expect(d.events.transitions.contains("\(id) firing->acknowledged"))
        #expect(d.events.transitions.last == "\(id) acknowledged->idle")
        await rig.app.stop()
    }

    @Test func silencingOnTheDisplayClearsTheAlertHere() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        try await rig.app.commands.setAlarm(serialA, channel: .ambient, kind: .high, temperature: 30)
        let id = "\(serialA.hex).alarm.high.ambient"
        #expect(await rig.run(until: { d.sound.playing[id] != nil }, limit: .seconds(300), step: .seconds(5)))

        // Silenced from elsewhere (the Display, the phone): the probe's status stops alarming and the alert follows.
        try await rig.app.commands.silenceAlarms(serialA)
        #expect(await rig.run(until: { d.sound.playing.isEmpty }, limit: .seconds(30), step: .seconds(1)))
        #expect(await rig.app.alerts.activeAlerts().isEmpty)
        _ = probe
        await rig.app.stop()
    }

    // MARK: Prediction rules (the default set)

    @Test func defaultAlertsFireTheFiveMinuteWarningThenReadyAndReadyRepeatsUntilAcknowledged() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        probe.predictionLeadSeconds = 420
        let five = "\(serialA.hex).fiveMinutes", ready = "\(serialA.hex).ready"

        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        await rig.run(.seconds(60))
        #expect(await rig.app.alerts.activeAlerts().isEmpty, "6 minutes to go: nothing yet")

        #expect(await rig.run(until: { d.events.transitions.contains("\(five) idle->firing") }, limit: .seconds(200), step: .seconds(1)))
        let firedAt = await rig.app.alerts.activeAlerts().first { $0.id == five }?.value
        #expect((firedAt ?? 999) <= 300)

        // Ready: fires when the probe says so, then stays, with a sound, until acknowledged.
        #expect(await rig.run(until: { d.sound.playing[ready] != nil }, limit: .seconds(400), step: .seconds(1)))
        #expect(d.sound.playing[ready] == .ready)
        #expect(d.events.transitions.contains("\(five) firing->idle"), "the countdown alert goes away with the countdown")
        await rig.run(.seconds(300))
        #expect(d.sound.playing[ready] == .ready, "repeats until acknowledged")

        await rig.app.alerts.acknowledge(ready)
        #expect(d.sound.playing.isEmpty)
        await rig.run(.seconds(60))
        #expect(await rig.app.alerts.activeAlerts().first?.state == .acknowledged)
        await rig.app.stop()
    }

    // MARK: Offline

    @Test func disconnectedAlertFiresAfterAMinuteDuringACookAndClearsOnReturn() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        await rig.run(.seconds(20))
        let offline = "\(serialA.hex).offline"

        probe.setInRange(false)
        await rig.run(.seconds(30))
        #expect(await rig.app.alerts.activeAlerts().isEmpty, "not a minute yet")
        #expect(await rig.run(until: { d.events.transitions.contains("\(offline) idle->firing") }, limit: .seconds(90), step: .seconds(1)))

        probe.setInRange(true)
        #expect(await rig.run(until: { d.events.transitions.contains("\(offline) firing->idle") }, limit: .seconds(120), step: .seconds(1)))
        await rig.app.stop()
    }

    @Test func acknowledgingOrSnoozingTheDisconnectedAlertTakesItOutOfFiring() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        await rig.run(.seconds(20))
        let offline = "\(serialA.hex).offline"
        // What the UI sees: the `active` stream, not the engine's own list.
        let published = Latest<[AlertInstance]>()
        let watcher = Task { for await list in rig.app.alerts.active { published.value = list } }
        defer { watcher.cancel() }
        func state() async -> AlertState? { published.value?.first { $0.id == offline }?.state }

        probe.setInRange(false)
        #expect(await rig.run(until: { await state() == .firing }, limit: .seconds(120), step: .seconds(1)))
        await rig.app.alerts.acknowledge(offline)
        #expect(await rig.eventually { await state() == .acknowledged })
        await rig.run(.seconds(120))
        #expect(await state() == .acknowledged, "stays acknowledged while the probe is gone")
        #expect(d.events.transitions.filter { $0 == "\(offline) idle->firing" }.count == 1)

        probe.setInRange(true)
        #expect(await rig.run(until: { await state() == nil }, limit: .seconds(120), step: .seconds(1)))
        probe.setInRange(false)
        #expect(await rig.run(until: { await state() == .firing }, limit: .seconds(120), step: .seconds(1)))
        await rig.app.alerts.snooze(offline, duration: .seconds(300))
        #expect(await rig.eventually { await state() == .snoozed })
        await rig.run(.seconds(120))
        #expect(await state() == .snoozed, "stays snoozed until the snooze runs out")
        await rig.app.stop()
    }

    @Test func noDisconnectedAlertForAProbeThatWasNotCooking() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)           // never given a prediction, core still near room temperature
        probe.setInRange(false)
        await rig.run(.seconds(180))
        #expect(!d.events.transitions.contains { $0.contains("offline") })
        await rig.app.stop()
    }

    // MARK: Low battery, overheat

    @Test func batteryAndOverheatReachTheSinksThroughTheWholePath() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        probe.batteryLow = true
        probe.overheating = [.t1]
        #expect(await rig.run(until: { d.sound.playing["\(serialA.hex).overheat.t1"] != nil }, limit: .seconds(30), step: .seconds(1)))
        #expect(d.events.transitions.contains("\(serialA.hex).battery idle->firing"))
        // Overheat sorts first.
        #expect(await rig.app.alerts.activeAlerts().first?.id == "\(serialA.hex).overheat.t1")
        probe.overheating = []
        #expect(await rig.run(until: { d.sound.playing["\(serialA.hex).overheat.t1"] == nil }, limit: .seconds(30), step: .seconds(1)))
        #expect(await rig.app.alerts.activeAlerts().map(\.id) == ["\(serialA.hex).battery"], "low battery goes on")
        #expect(d.sound.history.filter { $0 == "once problem" }.count == 1, "its sound played once")
        await rig.app.stop()
    }

    // MARK: Keep awake

    @Test func theMacStaysAwakeDuringACookAndReleasesAfterUnfollowAndStop() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        #expect(!d.keepAwake.isHeld, "a probe at room temperature is not a cook")

        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        #expect(await rig.run(until: { d.keepAwake.isHeld }, limit: .seconds(30), step: .seconds(1)))
        await rig.run(.seconds(600))
        #expect(d.keepAwake.history == [true], "held through the cook without flapping")

        await rig.app.unfollow(serialA)
        #expect(await rig.eventually { !d.keepAwake.isHeld })

        await rig.app.follow(serialA)
        #expect(await rig.run(until: { d.keepAwake.isHeld }, limit: .seconds(120), step: .seconds(1)))
        await rig.app.stop()
        #expect(!d.keepAwake.isHeld, "quitting releases the assertion")
        withExtendedLifetime(probe) {}
    }

    // MARK: Trace

    @Test func alertsCommandsAndPredictionAppearInTheParityTrace() async throws {
        let d = Doubles()
        let rig = try rig(d)
        let probe = try await connect(rig)
        probe.batteryLow = true
        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        await rig.run(.seconds(30))
        let lines = rig.trace.lines
        #expect(lines.contains { $0.contains("\"kind\":\"command\"") && $0.contains("\"op\":\"setPrediction\"") && $0.contains("\"result\":\"confirmed\"") })
        #expect(lines.contains { $0.contains("\"kind\":\"alert\"") && $0.contains("\"transition\":\"idle->firing\"") })
        await rig.app.stop()
    }
}

/// The latest value a stream delivered.
final class Latest<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
