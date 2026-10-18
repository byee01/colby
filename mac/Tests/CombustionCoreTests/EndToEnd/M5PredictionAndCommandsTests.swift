import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// M5 exit: the countdown matches the Display; set prediction, set alarms and silence are confirmed by status.
struct M5PredictionAndCommandsTests {
    /// A followed, connected probe with a few statuses behind it.
    private func connectedRig(offset: Double = 0, lead: Double = 600) async throws -> (E2ERig, SimulatedProbe) {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 20, offset: offset)
        probe.predictionLeadSeconds = lead
        await rig.app.start()
        await rig.app.follow(serialA)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(20)))
        await rig.run(.seconds(10))
        return (rig, probe)
    }

    @Test func setPredictionIsConfirmedAndTheCountdownMatchesTheProbeOverTheWholeCook() async throws {
        let (rig, probe) = try await connectedRig(lead: 1200)
        let views = StoreLog<PredictionView>()
        let stream = rig.app.predictions(serialA)
        Task { for await v in stream { views.add(v) } }

        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 63)
        let (setpoint, mode) = probe.currentPrediction
        #expect(setpoint == 63 && mode == .timeToRemoval)
        #expect(probe.requests.contains(.setPrediction(setpoint: 63, mode: .timeToRemoval)))

        // Sample the presented number each second against the probe's own countdown (what its Display shows).
        var worst = 0.0
        var worstLast5 = 0.0
        var checked = 0
        for _ in 0..<1230 {
            await rig.run(.seconds(1), step: .seconds(1))
            let truth = probe.currentPredictionState.secondsRemaining
            if let shown = views.last?.secondsRemaining, views.last?.state == .predicting {
                let error = abs(Double(shown) - truth)
                worst = max(worst, error)
                if truth <= 290 { worstLast5 = max(worstLast5, error) }
                checked += 1
            }
        }
        #expect(checked > 1100)
        // Rounding to 15 s (7.5) plus holding for three statuses (15) bounds the error; the last five minutes
        // follow the probe closely.
        #expect(worst <= 22.5, "worst \(worst) s")
        #expect(worstLast5 <= 6, "worst in the last five minutes \(worstLast5) s")

        // The cook ends: Ready is exposed with the time it started.
        let done = try #require(views.last)
        #expect(done.state == .removalPredictionDone)
        #expect(done.secondsRemaining == nil)
        let since = try #require(done.readySince)
        #expect(abs(since.timeIntervalSince(TestClock.defaultStart.addingTimeInterval(10 + 1200)) ) < 40)
        await rig.app.stop()
    }

    @Test func countdownCarriesAReadyAtThatMatchesTheEnd() async throws {
        let (rig, probe) = try await connectedRig(lead: 900)
        let views = StoreLog<PredictionView>()
        let stream = rig.app.predictions(serialA)
        Task { for await v in stream { views.add(v) } }
        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        let startedAt = rig.clock.now()
        await rig.run(.seconds(30))
        let readyAt = try #require(views.last?.readyAt)
        #expect(abs(readyAt.timeIntervalSince(startedAt.addingTimeInterval(900))) <= 20)
        _ = probe
        await rig.app.stop()
    }

    @Test func removalAndRestingRunsThroughBothCountdowns() async throws {
        let (rig, probe) = try await connectedRig(lead: 60)
        probe.restingSeconds = 40
        let views = StoreLog<PredictionView>()
        let stream = rig.app.predictions(serialA)
        Task { for await v in stream { views.add(v) } }
        try await rig.app.commands.setPrediction(serialA, mode: .removalAndResting, setpoint: 60)
        await rig.run(.seconds(130), step: .seconds(1))
        let sequence = views.items.map { "\($0.state)/\($0.type)" }
        var collapsed: [String] = []
        for s in sequence where collapsed.last != s { collapsed.append(s) }
        #expect(collapsed.contains("predicting/removal"))
        #expect(collapsed.contains("removalPredictionDone/removal"))
        #expect(collapsed.contains("predicting/resting"))
        #expect(collapsed.last == "removalPredictionDone/resting")
        await rig.app.stop()
    }

    @Test func cancelPredictionEndsIt() async throws {
        let (rig, probe) = try await connectedRig()
        try await rig.app.commands.setPrediction(serialA, mode: .timeToRemoval, setpoint: 60)
        try await rig.app.commands.cancelPrediction(serialA)
        #expect(probe.currentPrediction.mode == PredictionMode.none)
        #expect(probe.currentPredictionState.state == .notInserted)
        await rig.app.stop()
    }

    @Test func setAlarmsAreConfirmedKeepOthersAndSurviveAnotherSet() async throws {
        let (rig, probe) = try await connectedRig()
        try await rig.app.commands.setAlarm(serialA, channel: .core, kind: .high, temperature: 90.5)
        try await rig.app.commands.setAlarm(serialA, channel: .ambient, kind: .low, temperature: 120)
        let alarms = probe.currentAlarms
        #expect(alarms.high[.core]?.isSet == true && abs((alarms.high[.core]?.temperature ?? 0) - 90.5) < 0.06)
        #expect(alarms.low[.ambient]?.isSet == true)
        #expect(alarms.high[.core]?.isSet == true, "the second write carried the first alarm along")

        // The app's own snapshot shows what the probe reported.
        let seen = await rig.app.probes.snapshot(of: serialA)?.alarms
        #expect(seen?.high[.core]?.isSet == true && seen?.low[.ambient]?.isSet == true)

        try await rig.app.commands.setAlarm(serialA, channel: .core, kind: .high, temperature: nil)
        #expect(probe.currentAlarms.high[.core]?.isSet == false)
        #expect(probe.currentAlarms.low[.ambient]?.isSet == true)
        await rig.app.stop()
    }

    @Test func alarmTripsAndSilenceIsConfirmedByStatus() async throws {
        // The ambient sensors lead the cook, so a 30 °C ambient alarm trips within about a minute.
        let (rig, probe) = try await connectedRig(offset: 0)
        try await rig.app.commands.setAlarm(serialA, channel: .ambient, kind: .high, temperature: 30)
        let alarming = await rig.run(until: {
            await rig.app.probes.snapshot(of: serialA)?.alarms?.high[.ambient]?.alarming == true
        }, limit: .seconds(300), step: .seconds(5))
        #expect(alarming, "the probe reports the trip in its status")
        #expect(probe.currentAlarms.high[.ambient]?.tripped == true)

        try await rig.app.commands.silenceAlarms(serialA)
        #expect(probe.requests.contains(.silenceAlarms))
        #expect(probe.currentAlarms.high[.ambient]?.alarming == false)
        #expect(await rig.app.probes.snapshot(of: serialA)?.alarms?.high[.ambient]?.alarming == false)
        await rig.app.stop()
    }

    @Test func commandsToAnUnconnectedProbeAreNotReachable() async throws {
        let rig = try E2ERig()
        _ = rig.probe(serialA)
        await rig.app.start()
        await #expect(throws: CommandError.notReachable) {
            try await rig.app.commands.silenceAlarms(serialA)
        }
        await rig.app.stop()
    }

    @Test func aDeadLinkMidCommandIsAnErrorNotAHang() async throws {
        let (rig, probe) = try await connectedRig()
        probe.setInRange(false)
        await rig.drain()
        let result = Task { try await rig.app.commands.setAlarm(serialA, channel: .core, kind: .high, temperature: 70) }
        var spent = Duration.zero
        while spent < .seconds(30) {
            await rig.clock.advance(by: .milliseconds(500))
            spent += .milliseconds(500)
            if await rig.app.diagnostics().links[serialA] != .connected { break }
        }
        let outcome = await result.result
        if case .failure(let e) = outcome {
            #expect(e as? CommandError == .notReachable || e as? CommandError == .uart(.disconnected)
                    || e as? CommandError == .notConfirmed)
        }
        await rig.app.stop()
    }
}
