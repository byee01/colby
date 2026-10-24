import CombustionCodec
import CombustionCore
import Foundation
import Testing

/// The instance state machine, sinks, rule management and keep-awake (docs/02 §9).
struct AlertEngineTests {
    private let hot = AlertRule(id: "hot", kind: .temperatureAbove(channel: .core, celsius: 60))

    // MARK: Ack, snooze

    @Test func acknowledgeStopsSoundKeepsRecordAndStaysQuietUntilTheConditionClears() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        #expect(rig.sound.history == ["once custom"])
        #expect(rig.notifications.visible["hot"] != nil)

        await rig.engine.acknowledge("hot")
        #expect(await rig.state("hot") == .acknowledged)
        #expect(await rig.active().first?.acknowledgedAt == rig.clock.now())
        #expect(rig.sound.playing.isEmpty)
        #expect(rig.notifications.visible.isEmpty)

        // Still hot: no new alert for the same crossing.
        await rig.snapshot(core: 65)
        #expect(await rig.state("hot") == .acknowledged)
        #expect(rig.transitions == ["hot idle->firing", "hot firing->acknowledged"])

        await rig.snapshot(core: 50)
        #expect(await rig.active().isEmpty)
        #expect(rig.transitions.last == "hot acknowledged->idle")
        // And the next crossing is a new alert.
        await rig.snapshot(core: 62)
        #expect(await rig.state("hot") == .firing)
    }

    @Test func alarmSoundLoopsUntilAcknowledged() async {
        let rig = AlertRig()
        await rig.follow([])
        let id = "\(AF.serial.hex).alarm.high.core"
        await rig.snapshot(alarms: AF.alarming(.high, .core))
        for _ in 0..<10 {
            await rig.clock.advance(by: .seconds(30))
            await rig.snapshot(alarms: AF.alarming(.high, .core))
        }
        #expect(rig.sound.playing[id] == .probeAlarm, "five minutes later it is still going")
        #expect(rig.sound.history == ["start \(id)"], "one loop, started once")
        await rig.engine.acknowledge(id)
        #expect(rig.sound.history == ["start \(id)", "stop \(id)"])
    }

    @Test func ruleSoundPlaysOncePerFiring() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        for _ in 0..<10 {
            await rig.clock.advance(by: .seconds(30))
            await rig.snapshot(core: 62)
        }
        #expect(await rig.state("hot") == .firing)
        #expect(rig.sound.playing.isEmpty)
        #expect(rig.sound.history == ["once custom"], "played when it fired, not again while it stays true")
        await rig.engine.acknowledge("hot")
        #expect(rig.sound.history == ["once custom"], "nothing to stop")
    }

    @Test func soundPerAlertFollowsTheUxPlan() {
        func sound(_ kind: AlertRuleKind) -> AlertSound { AlertSound(for: .rule(kind)) }
        #expect(sound(.predictionDone) == .ready && sound(.restingDone) == .ready)
        #expect(sound(.predictionWithin(seconds: 300)) == .countdown)
        #expect(sound(.probeOffline()) == .problem && sound(.batteryLow) == .problem)
        #expect(sound(.temperatureAbove(channel: .core, celsius: 60)) == .custom)
        #expect(sound(.stall(minRise: 1)) == .custom)
        #expect(AlertSound.allCases.filter(\.loops) == [.ready, .overheat, .probeAlarm])
    }

    @Test func snoozeMutesThenFiresAgainIfStillTrue() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        await rig.engine.snooze("hot", duration: .seconds(300))
        #expect(await rig.state("hot") == .snoozed)
        #expect(await rig.active().first?.snoozedUntil == rig.clock.now().addingTimeInterval(300))
        #expect(rig.sound.playing.isEmpty && rig.notifications.visible.isEmpty)

        await rig.snapshot(core: 62)
        await rig.clock.advance(by: .seconds(299))
        #expect(await rig.state("hot") == .snoozed)
        await rig.clock.advance(by: .seconds(2))
        #expect(await rig.state("hot") == .firing, "the timer alone brings it back, no new reading needed")
        #expect(rig.sound.history == ["once custom", "once custom"])
        #expect(rig.transitions == ["hot idle->firing", "hot firing->snoozed", "hot snoozed->firing"])
        #expect(await rig.active().first?.snoozedUntil == nil)
    }

    @Test func snoozedAlertThatClearsDuringTheSnoozeJustGoesIdle() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        await rig.engine.snooze("hot", duration: .seconds(300))
        await rig.snapshot(core: 40)
        #expect(await rig.active().isEmpty)
        await rig.clock.advance(by: .seconds(400))
        #expect(rig.transitions == ["hot idle->firing", "hot firing->snoozed", "hot snoozed->idle"])
    }

    @Test func acknowledgingASnoozedAlertWorks() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        await rig.engine.snooze("hot", duration: .seconds(300))
        await rig.engine.acknowledge("hot")
        #expect(await rig.state("hot") == .acknowledged)
        await rig.clock.advance(by: .seconds(400))
        #expect(await rig.state("hot") == .acknowledged, "the snooze timer is gone")
    }

    @Test func acknowledgeAndSnoozeOfUnknownOrWrongStateAreIgnored() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.engine.acknowledge("nothing")
        await rig.engine.snooze("nothing", duration: .seconds(5))
        await rig.snapshot(core: 61)
        await rig.engine.acknowledge("hot")
        await rig.engine.snooze("hot", duration: .seconds(5))     // already acknowledged
        #expect(await rig.state("hot") == .acknowledged)
        #expect(rig.transitions.count == 2)
    }

    // MARK: Probe alarms: silence

    @Test func acknowledgingAProbeAlarmSilencesTheProbe() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(alarms: AF.alarming(.high, .core))
        let id = "\(AF.serial.hex).alarm.high.core"
        #expect(rig.sound.playing[id] == .probeAlarm)
        await rig.engine.acknowledge(id)
        #expect(rig.silencer.silenced == [AF.serial])
        #expect(await rig.state(id) == .acknowledged)
        #expect(rig.sound.playing.isEmpty)
        // The probe confirms with alarming = false in its next status: the alert is over.
        await rig.snapshot(alarms: AF.alarming(.high, .core, false))
        #expect(await rig.active().isEmpty)
    }

    /// Asked for on hardware: Snooze left the phone ringing with no way to stop it from Colby.
    @Test func snoozingAProbeAlarmSilencesTheProbeAndFiresAgainWhileTripped() async {
        let rig = AlertRig()
        await rig.follow([])
        let id = "\(AF.serial.hex).alarm.high.core"
        await rig.snapshot(alarms: AF.alarming(.high, .core))
        await rig.engine.snooze(id, duration: .seconds(300))
        #expect(rig.silencer.silenced == [AF.serial], "the Display and phone stop too")
        #expect(rig.sound.playing.isEmpty)
        // The probe confirms: still past the limit (tripped), no longer alarming. The snooze holds.
        let silenced = AlarmConfig(high: [.core: Alarm(isSet: true, temperature: 80, tripped: true, alarming: false)])
        await rig.snapshot(alarms: silenced)
        #expect(await rig.state(id) == .snoozed)
        await rig.clock.advance(by: .seconds(301))
        await rig.snapshot(alarms: silenced)
        #expect(await rig.state(id) == .firing, "Colby fires again; the probe has no snooze")
        #expect(rig.sound.playing[id] == .probeAlarm)
        await rig.engine.acknowledge(id)
        await rig.snapshot(alarms: silenced)
        #expect(await rig.active().isEmpty)
    }

    @Test func snoozedProbeAlarmEndsWhenTheTemperatureComesBack() async {
        let rig = AlertRig()
        await rig.follow([])
        let id = "\(AF.serial.hex).alarm.high.core"
        await rig.snapshot(alarms: AF.alarming(.high, .core))
        await rig.engine.snooze(id, duration: .seconds(300))
        await rig.snapshot(alarms: AF.alarming(.high, .core, false))   // not tripped any more
        #expect(await rig.active().isEmpty)
        await rig.clock.advance(by: .seconds(301))
        #expect(rig.sound.playing.isEmpty)
    }

    @Test func failedSilenceGoesBackToFiringWithTheReason() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(alarms: AF.alarming(.high, .core))
        let id = "\(AF.serial.hex).alarm.high.core"
        rig.silencer.failNext(with: CommandError.notConfirmed)
        await rig.engine.acknowledge(id)
        #expect(await rig.state(id) == .firing)
        #expect(rig.sound.playing[id] == .probeAlarm, "the app does not stay quiet about a probe that still alarms")
        let last = rig.sink.events.last
        #expect(last?.failure?.contains("notConfirmed") == true)
        #expect(last?.transition == "acknowledged->firing")
    }

    @Test func overheatCannotBeSilencedOnTheProbeSoAckOnlyMutesTheApp() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(overheating: [.t3])
        let id = "\(AF.serial.hex).overheat.t3"
        #expect(rig.sound.playing[id] == .overheat)
        #expect(rig.notifications.visible[id] != nil)
        await rig.engine.acknowledge(id)
        #expect(rig.silencer.silenced.isEmpty)
        #expect(rig.sound.playing.isEmpty)
        #expect(rig.notifications.visible[id] != nil, "the banner stays while the probe is overheating (06 §7)")
        await rig.snapshot(overheating: [])
        #expect(rig.notifications.visible.isEmpty)
        #expect(await rig.active().isEmpty)
    }

    @Test func silenceAllAcknowledgesEverythingAndSendsOneSilence() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61, alarms: AF.alarming(.high, .core), overheating: [.t2])
        #expect(await rig.active().count == 3)
        await rig.engine.silenceAll(AF.serial)
        #expect(await rig.active().allSatisfy { $0.state == .acknowledged })
        #expect(rig.silencer.silenced == [AF.serial], "one Silence Alarms covers every probe alarm")
        #expect(rig.sound.playing.isEmpty)
    }

    @Test func silenceAllWithoutAProbeAlarmSendsNothing() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        await rig.engine.silenceAll(AF.serial)
        #expect(rig.silencer.silenced.isEmpty)
        #expect(await rig.state("hot") == .acknowledged)
    }

    // MARK: Ordering of the active list

    @Test func activeListIsOrderedOverheatThenProbeAlarmThenReadyThenOthersNewestFirst() async {
        let rig = AlertRig()
        await rig.follow([
            AlertRule(id: "bat", kind: .batteryLow),
            AlertRule(id: "ready", kind: .predictionDone),
            AlertRule(id: "hot", kind: .temperatureAbove(channel: .core, celsius: 60)),
        ])
        await rig.snapshot(core: 20, battery: true)
        await rig.clock.advance(by: .seconds(5))
        await rig.snapshot(core: 70, battery: true, alarms: AF.alarming(.high, .ambient), overheating: [.t1])
        await rig.view(AF.view(state: .removalPredictionDone, seconds: nil))
        let ids = await rig.active().map(\.id)
        #expect(ids == [
            "\(AF.serial.hex).overheat.t1", "\(AF.serial.hex).alarm.high.ambient", "ready", "hot", "bat",
        ])
    }

    // MARK: Streams

    @Test func eventsAndActiveStreamsCarryEveryChange() async {
        let rig = AlertRig()
        let events = StoreLog<AlertEvent>()
        let lists = StoreLog<[String]>()
        let e = rig.engine.events, a = rig.engine.active
        Task { for await ev in e { events.add(ev) } }
        Task { for await list in a { lists.add(list.map(\.id)) } }
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        await rig.engine.acknowledge("hot")
        await rig.snapshot(core: 40)
        await settle(rig.clock) { events.count >= 3 && lists.count >= 4 }
        #expect(events.items.map(\.transition) == ["idle->firing", "firing->acknowledged", "acknowledged->idle"])
        #expect(lists.items.first == [], "the current (empty) list first")
        #expect(lists.items.contains(["hot"]) && lists.last == [])
    }

    @Test func eventsAreTracedForTheParityFormat() async throws {
        let rig0 = TestClock()
        let trace = try JSONLTraceSink(clock: rig0)
        let engine = AlertEngine(clock: rig0, trace: trace, defaultRules: nil)
        await engine.setFollowed([AF.serial])
        await engine.addRule(AF.serial, hot)
        await engine.ingest(snapshot: AF.snapshot(at: rig0.now(), core: 61))
        #expect(trace.lines.count == 1)
        let line = trace.lines[0]
        #expect(line.contains("\"kind\":\"alert\"") && line.contains("\"rule\":\"hot\""))
        #expect(line.contains("\"transition\":\"idle->firing\"") && line.contains("\"value\":61"))
        #expect(line.contains("\"serial\":\"\(AF.serial.hex)\""))
    }

    // MARK: Rule management

    @Test func removingOrDisablingARuleClearsItsAlert() async {
        let rig = AlertRig()
        await rig.follow([hot, AlertRule(id: "bat", kind: .batteryLow)])
        await rig.snapshot(core: 61, battery: true)
        #expect(await rig.active().count == 2)
        await rig.engine.removeRule(AF.serial, id: "hot")
        #expect(await rig.active().map(\.id) == ["bat"])
        var bat = AlertRule(id: "bat", kind: .batteryLow)
        bat.enabled = false
        await rig.engine.updateRule(AF.serial, bat)
        #expect(await rig.active().isEmpty)
        bat.enabled = true
        await rig.engine.updateRule(AF.serial, bat)
        #expect(await rig.state("bat") == .firing, "enabled again and the condition holds")
    }

    @Test func updatingARuleThresholdReevaluatesAtOnce() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 55)
        #expect(await rig.active().isEmpty)
        await rig.engine.updateRule(AF.serial, AlertRule(id: "hot", kind: .temperatureAbove(channel: .core, celsius: 50)))
        #expect(await rig.state("hot") == .firing)
        // Changing the kind drops the old alert instead of morphing it.
        await rig.engine.updateRule(AF.serial, AlertRule(id: "hot", kind: .temperatureBelow(channel: .core, celsius: 60)))
        #expect(rig.transitions == ["hot idle->firing", "hot firing->idle", "hot idle->firing"])
    }

    @Test func rulesArePerProbeAndPersist() async {
        let rig = AlertRig()
        await rig.engine.setFollowed([AF.serial, AF.other])
        await rig.engine.addRule(AF.serial, hot)
        #expect(await rig.engine.rules(AF.serial).map(\.id) == ["hot"])
        #expect(await rig.engine.rules(AF.other).isEmpty)
        #expect(await rig.store.loadRules(for: AF.serial)?.map(\.id) == ["hot"])

        // A second engine on the same store sees the rules after follow.
        let again = AlertEngine(clock: rig.clock, ruleStore: rig.store, defaultRules: nil)
        await again.setFollowed([AF.serial])
        #expect(await again.rules(AF.serial).map(\.id) == ["hot"])
        await again.ingest(snapshot: AF.snapshot(at: rig.clock.now(), core: 70))
        #expect(await again.activeAlerts().map(\.id) == ["hot"])
    }

    @Test func otherProbesDoNotInterfere() async {
        let rig = AlertRig()
        await rig.engine.setFollowed([AF.serial, AF.other])
        await rig.engine.addRule(AF.serial, hot)
        await rig.engine.ingest(snapshot: AF.snapshot(AF.other, at: rig.clock.now(), core: 99))
        #expect(await rig.active().isEmpty)
        await rig.engine.ingest(snapshot: AF.snapshot(AF.serial, at: rig.clock.now(), core: 99))
        #expect(await rig.active().map(\.serial) == [AF.serial])
    }

    // MARK: Defaults (06 §6)

    @Test func firstFollowSeedsTheDefaultAlertSetOnce() async {
        let rig = AlertRig(defaults: true)
        await rig.engine.setFollowed([AF.serial])
        let rules = await rig.engine.rules(AF.serial)
        #expect(rules.map(\.kind) == [
            .predictionDone, .predictionWithin(seconds: 300), .probeOffline(seconds: 60, onlyDuringCook: true), .batteryLow,
        ])
        // Unfollow, delete one, follow again: the user's choice stands, no reseed.
        await rig.engine.setFollowed([])
        await rig.engine.removeRule(AF.serial, id: "\(AF.serial.hex).battery")
        await rig.engine.setFollowed([AF.serial])
        #expect(await rig.engine.rules(AF.serial).count == 3)
    }

    // MARK: Follow set

    @Test func unfollowingClearsTheProbesAlerts() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61, overheating: [.t1])
        #expect(await rig.active().count == 2)
        await rig.engine.setFollowed([])
        #expect(await rig.active().isEmpty)
        #expect(rig.sound.playing.isEmpty)
        // Not followed: readings are ignored.
        await rig.snapshot(core: 70)
        #expect(await rig.active().isEmpty)
    }

    @Test func followingAProbeThatIsAlreadyReportingEvaluatesAtOnce() async {
        let rig = AlertRig()
        await rig.snapshot(core: 61)                         // seen, not followed
        await rig.engine.setFollowed([AF.serial])
        await rig.engine.addRule(AF.serial, hot)
        #expect(await rig.state("hot") == .firing)
    }

    // MARK: Keep awake

    @Test func keepAwakeIsHeldForTheWholeCookAndReleasedAfter() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(core: 22, prediction: AF.prediction(.notInserted))
        #expect(rig.keepAwake.history.isEmpty, "on the counter: nothing to protect")
        await rig.snapshot(core: 30, prediction: AF.prediction(.inserted))
        #expect(rig.keepAwake.isHeld)
        await rig.snapshot(core: 55, prediction: AF.prediction(.predicting))
        await rig.snapshot(core: 60, prediction: AF.prediction(.removalPredictionDone))
        #expect(rig.keepAwake.history == [true], "asserted once, not per reading")
        await rig.snapshot(core: 25, prediction: AF.prediction(.notInserted))
        #expect(rig.keepAwake.history == [true, false])
    }

    @Test func aHotCoreWithoutPredictionCountsAsACook() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(core: 41, prediction: AF.prediction(.notInserted))
        #expect(rig.keepAwake.isHeld)
    }

    @Test func instantReadIsNotACook() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(core: 90, mode: .instantRead, prediction: AF.prediction(.predicting))
        #expect(rig.keepAwake.history.isEmpty)
    }

    @Test func keepAwakeOutlastsAQuietProbeForTheIdleTimeoutThenLetsGo() async {
        let rig = AlertRig(cookIdle: .seconds(600))
        await rig.follow([])
        await rig.snapshot(prediction: AF.prediction(.predicting))
        let last = rig.clock.now()
        await rig.engine.ingest(snapshot: AF.snapshot(at: last, offline: true, prediction: AF.prediction(.predicting)))
        await rig.clock.advance(by: .seconds(590))
        #expect(rig.keepAwake.isHeld, "the app is still trying to reconnect")
        await rig.clock.advance(by: .seconds(20))
        #expect(rig.keepAwake.history == [true, false])
    }

    @Test func keepAwakeStaysWhileAnyProbeCooksAndEndsOnUnfollowOrStop() async {
        let rig = AlertRig()
        await rig.engine.setFollowed([AF.serial, AF.other])
        await rig.engine.ingest(snapshot: AF.snapshot(AF.serial, at: rig.clock.now(), prediction: AF.prediction(.predicting)))
        await rig.engine.ingest(snapshot: AF.snapshot(AF.other, at: rig.clock.now(), prediction: AF.prediction(.predicting)))
        await rig.engine.setFollowed([AF.other])
        #expect(rig.keepAwake.isHeld, "the other probe is still cooking")
        await rig.engine.setFollowed([])
        #expect(!rig.keepAwake.isHeld)

        await rig.engine.setFollowed([AF.serial])
        await rig.engine.ingest(snapshot: AF.snapshot(AF.serial, at: rig.clock.now(), core: 30, prediction: AF.prediction(.predicting)))
        #expect(rig.keepAwake.isHeld)
        await rig.engine.stop()
        #expect(!rig.keepAwake.isHeld, "quitting releases the assertion")
    }

    // MARK: Sinks

    @Test func notificationSinkPostsOnFireAndWithdrawsOnSnoozeAndClear() async {
        let rig = AlertRig()
        await rig.follow([hot])
        await rig.snapshot(core: 61)
        await rig.engine.snooze("hot", duration: .seconds(60))
        await rig.clock.advance(by: .seconds(61))
        await rig.snapshot(core: 20)
        #expect(rig.notifications.history == ["post hot", "withdraw hot", "post hot", "withdraw hot"])
    }

    @Test func eventsReachTheSinksInOrder() async {
        let rig = AlertRig()
        await rig.follow([hot, AlertRule(id: "bat", kind: .batteryLow)])
        await rig.snapshot(core: 61, battery: true)
        await rig.snapshot(core: 20, battery: false)
        #expect(Set(rig.transitions) == ["bat idle->firing", "hot idle->firing", "bat firing->idle", "hot firing->idle"])
        let firstClear = rig.transitions.firstIndex { $0.contains("->idle") } ?? 0
        #expect(rig.transitions[..<firstClear].allSatisfy { $0.contains("idle->firing") }, "fires before clears")
    }
}
