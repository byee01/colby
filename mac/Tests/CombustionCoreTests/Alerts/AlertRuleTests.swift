import CombustionCodec
import CombustionCore
import Foundation
import Testing

/// One section per rule type of docs/02 §9: it fires, it clears, and it only fires once per crossing.
struct AlertRuleTests {
    // MARK: temperatureAbove / temperatureBelow

    @Test func temperatureAboveFiresAtTheThresholdAndClearsBelowTheHysteresis() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "hot", kind: .temperatureAbove(channel: .core, celsius: 60, hysteresis: 2))])

        await rig.snapshot(core: 59.9)
        #expect(await rig.active().isEmpty)
        await rig.snapshot(core: 60)
        #expect(await rig.state("hot") == .firing)
        #expect(await rig.active().first?.value == 60)

        // Hovering inside the hysteresis band neither clears nor fires again.
        await rig.snapshot(core: 58.5)
        await rig.snapshot(core: 60.5)
        await rig.snapshot(core: 58.1)
        #expect(await rig.state("hot") == .firing)
        #expect(rig.transitions == ["hot idle->firing"])

        await rig.snapshot(core: 57.9)
        #expect(await rig.active().isEmpty)
        #expect(rig.transitions == ["hot idle->firing", "hot firing->idle"])

        // Re-armed after the clear: the next crossing fires again.
        await rig.snapshot(core: 61)
        #expect(rig.transitions.suffix(1) == ["hot idle->firing"])
    }

    @Test func temperatureBelowFiresAtTheThresholdAndClearsAboveTheHysteresis() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "cold", kind: .temperatureBelow(channel: .ambient, celsius: 100, hysteresis: 3))])
        await rig.snapshot(ambient: 105)
        #expect(await rig.active().isEmpty)
        await rig.snapshot(ambient: 100)
        #expect(await rig.state("cold") == .firing)
        await rig.snapshot(ambient: 102.9)
        #expect(await rig.state("cold") == .firing)
        await rig.snapshot(ambient: 103.1)
        #expect(await rig.active().isEmpty)
    }

    @Test func temperatureRuleWorksOnAnyChannel() async {
        let rig = AlertRig()
        await rig.follow([
            AlertRule(id: "t3", kind: .temperatureAbove(channel: .t3, celsius: 50)),
            AlertRule(id: "surface", kind: .temperatureAbove(channel: .surface, celsius: 90)),
        ])
        await rig.snapshot(core: 30, surface: 91, t3: 51)
        #expect(Set(await rig.active().map(\.id)) == ["t3", "surface"])
    }

    @Test func missingReadingLeavesTheAlertAlone() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "hot", kind: .temperatureAbove(channel: .surface, celsius: 60))])
        await rig.snapshot(surface: 70)
        #expect(await rig.state("hot") == .firing)
        await rig.snapshot(surface: nil)    // Instant Read style gap: no value, no verdict
        #expect(await rig.state("hot") == .firing)
        await rig.snapshot(surface: 50)
        #expect(await rig.active().isEmpty)
    }

    // MARK: predictionWithin

    @Test func predictionWithinFiresAtNSecondsAndClearsWhenTheCountdownGoesAway() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "five", kind: .predictionWithin(seconds: 300))])
        await rig.snapshot()
        await rig.view(AF.view(seconds: 600))
        #expect(await rig.active().isEmpty)
        await rig.view(AF.view(seconds: 301))
        #expect(await rig.active().isEmpty)
        await rig.view(AF.view(seconds: 300))
        #expect(await rig.state("five") == .firing)
        #expect(await rig.active().first?.value == 300)

        // A re-estimate that nudges the number back up by one rounding step does not clear it.
        await rig.view(AF.view(seconds: 310))
        #expect(await rig.state("five") == .firing)
        // A big jump (prediction restarted) does.
        await rig.view(AF.view(seconds: 900))
        #expect(await rig.active().isEmpty)
        await rig.view(AF.view(seconds: 250))
        #expect(rig.transitions == ["five idle->firing", "five firing->idle", "five idle->firing"])
    }

    @Test func predictionWithinIgnoresStaleViews() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "five", kind: .predictionWithin(seconds: 300))])
        await rig.snapshot()
        await rig.view(AF.view(seconds: 100, stale: true))
        #expect(await rig.active().isEmpty, "a frozen number is not news")
        await rig.view(AF.view(seconds: 100))
        #expect(await rig.state("five") == .firing)
        await rig.view(AF.view(seconds: 100, stale: true))
        #expect(await rig.state("five") == .firing, "and not a reason to clear either")
    }

    @Test func predictionWithinClearsWhenPredictionEnds() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "five", kind: .predictionWithin(seconds: 300))])
        await rig.snapshot()
        await rig.view(AF.view(seconds: 200))
        #expect(await rig.state("five") == .firing)
        await rig.view(AF.view(state: .removalPredictionDone, seconds: nil))
        #expect(await rig.active().isEmpty)
    }

    // MARK: predictionDone (latches)

    @Test func predictionDoneFiresWhenRemovalIsDoneAndStaysUntilAcknowledged() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "ready", kind: .predictionDone)])
        await rig.snapshot()
        await rig.view(AF.view(seconds: 20))
        #expect(await rig.active().isEmpty)
        await rig.view(AF.view(state: .removalPredictionDone, seconds: nil))
        #expect(await rig.state("ready") == .firing)
        #expect(rig.sound.playing["ready"] == .ready)

        // The state moves on (probe pulled, resting starts): the alert still stands and the sound keeps looping.
        await rig.view(AF.view(state: .predicting, type: .resting, seconds: 300))
        #expect(await rig.state("ready") == .firing)
        #expect(rig.sound.playing["ready"] == .ready)

        await rig.engine.acknowledge("ready")
        #expect(await rig.state("ready") == .acknowledged)
        #expect(rig.sound.playing.isEmpty)
        // Acknowledged and the condition is gone: it clears.
        await rig.view(AF.view(state: .predicting, type: .resting, seconds: 290))
        #expect(await rig.active().isEmpty)
        #expect(rig.transitions == ["ready idle->firing", "ready firing->acknowledged", "ready acknowledged->idle"])
    }

    @Test func predictionDoneIsNotTheRestingPhase() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "ready", kind: .predictionDone)])
        await rig.snapshot()
        await rig.view(AF.view(state: .removalPredictionDone, type: .resting, seconds: nil))
        #expect(await rig.active().isEmpty)
    }

    // MARK: restingDone

    @Test func restingDoneFiresWhenTheRestingPredictionReachesZero() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "rest", kind: .restingDone)])
        await rig.snapshot()
        await rig.view(AF.view(type: .resting, seconds: 120))
        #expect(await rig.active().isEmpty)
        await rig.view(AF.view(type: .resting, seconds: 0))
        #expect(await rig.state("rest") == .firing)
        #expect(rig.sound.playing["rest"] == .ready)
        await rig.engine.acknowledge("rest")
        await rig.view(AF.view(state: .removalPredictionDone, type: .resting, seconds: nil))
        #expect(await rig.state("rest") == .acknowledged, "still done: stays in the list")
    }

    @Test func restingDoneAlsoOnTheDoneState() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "rest", kind: .restingDone)])
        await rig.snapshot()
        await rig.view(AF.view(type: .removal, seconds: 0))
        #expect(await rig.active().isEmpty, "a removal countdown at 0 is not resting")
        await rig.view(AF.view(state: .removalPredictionDone, type: .resting, seconds: nil))
        #expect(await rig.state("rest") == .firing)
    }

    // MARK: ambientOutOfRange (sustain)

    @Test func ambientOutOfRangeFiresOnlyAfterTheSustainTime() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "amb", kind: .ambientOutOfRange(min: 100, max: 150, sustain: 120))])
        await rig.snapshot(ambient: 125)
        await rig.snapshot(ambient: 160)
        #expect(await rig.active().isEmpty)
        // No new reading needed: the clock alone brings it due.
        await rig.clock.advance(by: .seconds(119))
        #expect(await rig.active().isEmpty)
        await rig.clock.advance(by: .seconds(2))
        #expect(await rig.state("amb") == .firing)
        #expect(await rig.active().first?.value == 160)
    }

    @Test func ambientBlipThatReturnsToRangeStartsTheSustainOver() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "amb", kind: .ambientOutOfRange(min: 100, max: 150, sustain: 120))])
        await rig.snapshot(ambient: 160)
        await rig.clock.advance(by: .seconds(100))
        await rig.snapshot(ambient: 140)            // back inside: the clock restarts
        await rig.clock.advance(by: .seconds(10))
        await rig.snapshot(ambient: 80)             // below min this time
        await rig.clock.advance(by: .seconds(100))
        #expect(await rig.active().isEmpty, "only 100 s of the new excursion")
        await rig.clock.advance(by: .seconds(21))
        #expect(await rig.state("amb") == .firing)
        await rig.snapshot(ambient: 120)
        #expect(await rig.active().isEmpty)
    }

    // MARK: stall

    @Test func stallFiresWhenTheCoreBarelyRoseOverTheWindowWhilePredicting() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "stall", kind: .stall(window: 1800, minRise: 2))])
        let predicting = AF.prediction(.predicting)
        await rig.snapshot(core: 65, prediction: predicting)
        for _ in 0..<4 {
            await rig.clock.advance(by: .seconds(360))
            await rig.snapshot(core: 65.5, prediction: predicting)
        }
        #expect(await rig.active().isEmpty, "24 min of history: the window is not covered yet")
        await rig.clock.advance(by: .seconds(360))
        await rig.snapshot(core: 65.6, prediction: predicting)
        #expect(await rig.state("stall") == .firing, "30 min, rose 0.6 °C")
        #expect((await rig.active().first?.value ?? 9) < 2)

        // The core moves again: it clears.
        await rig.clock.advance(by: .seconds(300))
        await rig.snapshot(core: 75, prediction: predicting)
        #expect(await rig.active().isEmpty)
    }

    @Test func stallDoesNotFireWhenTheCoreIsRisingOrNotPredicting() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "stall", kind: .stall(window: 1800, minRise: 2))])
        let predicting = AF.prediction(.predicting)
        var core = 40.0
        for _ in 0..<8 {
            await rig.snapshot(core: core, prediction: predicting)
            await rig.clock.advance(by: .seconds(300))
            core += 1
        }
        #expect(await rig.active().isEmpty, "rising 1 °C per 5 min")

        let idle = AlertRig()
        await idle.follow([AlertRule(id: "stall", kind: .stall(window: 600, minRise: 2))])
        await idle.snapshot(core: 65, prediction: AF.prediction(.inserted))
        await idle.clock.advance(by: .seconds(900))
        await idle.snapshot(core: 65, prediction: AF.prediction(.inserted))
        #expect(await idle.active().isEmpty, "a plateau with no prediction is just a probe sitting there")
    }

    // MARK: probeOffline

    @Test func probeOfflineFiresAfterNSecondsWithoutASourceAndClearsWhenDataReturns() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "off", kind: .probeOffline(seconds: 60))])
        await rig.snapshot()
        let lastData = rig.clock.now()
        await rig.clock.advance(by: .seconds(10))
        // The store drops the last source 10 s after the last data and shows the probe offline.
        await rig.engine.ingest(snapshot: AF.snapshot(at: lastData, offline: true))
        #expect(await rig.active().isEmpty)
        await rig.clock.advance(by: .seconds(49))
        #expect(await rig.active().isEmpty)
        await rig.clock.advance(by: .seconds(2))
        #expect(await rig.state("off") == .firing, "60 s after the last data")

        await rig.snapshot()
        #expect(await rig.active().isEmpty)
        #expect(rig.transitions == ["off idle->firing", "off firing->idle"])
    }

    @Test func probeOfflineDuringCookOnlyIgnoresAProbeThatWasNotCooking() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "off", kind: .probeOffline(seconds: 60, onlyDuringCook: true))])
        await rig.snapshot(core: 22)                 // sitting on the counter
        await rig.engine.ingest(snapshot: AF.snapshot(at: rig.clock.now(), core: 22, offline: true))
        await rig.clock.advance(by: .seconds(120))
        #expect(await rig.active().isEmpty)

        let cook = AlertRig()
        await cook.follow([AlertRule(id: "off", kind: .probeOffline(seconds: 60, onlyDuringCook: true))])
        await cook.snapshot(prediction: AF.prediction(.predicting))
        let last = cook.clock.now()
        await cook.clock.advance(by: .seconds(10))
        await cook.engine.ingest(snapshot: AF.snapshot(at: last, offline: true, prediction: AF.prediction(.predicting)))
        await cook.clock.advance(by: .seconds(51))
        #expect(await cook.state("off") == .firing)
    }

    // MARK: batteryLow

    @Test func batteryLowFiresAndClears() async {
        let rig = AlertRig()
        await rig.follow([AlertRule(id: "bat", kind: .batteryLow)])
        await rig.snapshot()
        #expect(await rig.active().isEmpty)
        await rig.snapshot(battery: true)
        #expect(await rig.state("bat") == .firing)
        await rig.snapshot(core: 26, battery: true)
        #expect(rig.transitions == ["bat idle->firing"], "once per crossing")
        await rig.snapshot(battery: false)
        #expect(await rig.active().isEmpty)
    }

    // MARK: Probe alarms and overheat

    @Test func probeAlarmFiresWhenAlarmingGoesTrueOnAnyChannel() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(alarms: AF.alarming(.high, .core, temperature: 70, false))
        #expect(await rig.active().isEmpty, "set and not alarming")
        await rig.snapshot(alarms: AF.alarming(.low, .surface, temperature: 30))
        let alert = await rig.active().first
        #expect(alert?.id == "\(AF.serial.hex).alarm.low.surface")
        #expect(alert?.source == .probeAlarm(kind: .low, channel: .surface))
        #expect(alert?.priority == .probeAlarm)
        #expect(rig.sound.playing[alert?.id ?? ""] == .probeAlarm)
        #expect(rig.notifications.visible.count == 1)

        // Silenced on the Display or phone: the bit drops and the alert clears here too.
        await rig.snapshot(alarms: AF.alarming(.low, .surface, temperature: 30, false))
        #expect(await rig.active().isEmpty)
        #expect(rig.sound.playing.isEmpty && rig.notifications.visible.isEmpty)
    }

    @Test func overheatBitFiresPerSensorAndClears() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(overheating: [.t2, .t7])
        let ids = Set(await rig.active().map(\.id))
        #expect(ids == ["\(AF.serial.hex).overheat.t2", "\(AF.serial.hex).overheat.t7"])
        #expect(await rig.active().allSatisfy { $0.priority == .overheat })
        await rig.snapshot(overheating: [.t7])
        #expect(Set(await rig.active().map(\.id)) == ["\(AF.serial.hex).overheat.t7"])
        await rig.snapshot(overheating: [])
        #expect(await rig.active().isEmpty)
    }

    @Test func probeAlarmsClearWhileTheProbeIsOffline() async {
        let rig = AlertRig()
        await rig.follow([])
        await rig.snapshot(alarms: AF.alarming(.high, .core), overheating: [.t1])
        #expect(await rig.active().count == 2)
        await rig.snapshot(offline: true, alarms: AF.alarming(.high, .core), overheating: [.t1])
        #expect(await rig.active().isEmpty, "an offline probe's bits say nothing current; probeOffline covers it")
    }
}
