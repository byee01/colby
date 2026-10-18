import CombustionCodec
import CombustionCore
import Foundation
import Testing

/// A route that records requests and lets the test decide what the probe does about them.
final class FakeRoute: CommandRoute, CommandRouting, @unchecked Sendable {
    typealias Handler = @Sendable (UartRequest) async throws -> Void

    private let lock = NSLock()
    private var log: [UartRequest] = []
    private var reachable = true
    private var handler: Handler = { _ in }

    var requests: [UartRequest] { lock.withLock { log } }
    func setReachable(_ value: Bool) { lock.withLock { reachable = value } }
    func onSend(_ h: @escaping Handler) { lock.withLock { handler = h } }

    func commandRoute(for probe: ProbeSerial) -> (any CommandRoute)? { lock.withLock { reachable } ? self : nil }

    func send(_ request: UartRequest, to probe: ProbeSerial, timeout: Duration) async throws -> UartResponse {
        let h: Handler = lock.withLock {
            log.append(request)
            return handler
        }
        try await h(request)
        return UartResponse(messageType: request.messageType, success: true, body: .ack)
    }
}

struct CommandsTests {
    typealias F = StoreFixtures

    struct Rig {
        let clock = TestClock()
        let store: ProbeStore
        let route = FakeRoute()
        let commands: Commands

        init(alarms: AlarmConfig? = AlarmConfig(), prediction: PredictionStatus = F.prediction()) async {
            store = ProbeStore(clock: clock)
            commands = Commands(probes: store, routing: route, clock: clock)
            if let alarms { await push(alarms: alarms, prediction: prediction) }
        }

        /// A full status from the probe, now.
        func push(alarms: AlarmConfig?, prediction: PredictionStatus = F.prediction(), seq: UInt32 = 0) async {
            await store.ingest(F.observe(
                .status(F.status(logMax: seq, prediction: prediction, alarms: alarms)), kind: .directConnection, at: clock.now()))
        }

        /// The probe applies `request` to its state and reports it in a status, as the real one does.
        func probeApplies(_ transform: @escaping @Sendable (UartRequest) -> (AlarmConfig?, PredictionStatus)) {
            let store = store, clock = clock
            route.onSend { request in
                let (alarms, prediction) = transform(request)
                await store.ingest(F.observe(
                    .status(F.status(logMax: 1, prediction: prediction, alarms: alarms)), kind: .directConnection, at: clock.now()))
            }
        }

        /// Runs `body`, advancing the clock until it finishes (for commands that end by timeout).
        func finish<T: Sendable>(within limit: Duration = .seconds(30), _ body: @escaping @Sendable () async throws -> T) async -> Result<T, any Error> {
            let task = Task { try await body() }
            var spent = Duration.zero
            let done = StoreLog<Bool>()
            Task {
                _ = await task.result
                done.add(true)
            }
            while done.count == 0 && spent < limit {
                await clock.advance(by: .milliseconds(500))
                spent += .milliseconds(500)
            }
            return await task.result
        }
    }

    static func alarms(high: [AlarmChannel: Alarm] = [:], low: [AlarmChannel: Alarm] = [:]) -> AlarmConfig {
        AlarmConfig(high: high, low: low)
    }

    // MARK: Set prediction

    @Test func setPredictionIsConfirmedByTheNextStatus() async throws {
        let rig = await Rig()
        rig.probeApplies { request in
            guard case .setPrediction(let sp, let mode) = request else { return (AlarmConfig(), F.prediction()) }
            return (AlarmConfig(), F.prediction(state: .predicting, mode: mode, setpoint: sp, seconds: 1800))
        }
        try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: 63)
        #expect(rig.route.requests == [.setPrediction(setpoint: 63, mode: .timeToRemoval)])
    }

    @Test func setPredictionNotConfirmedWhenTheStatusKeepsTheOldValue() async {
        let rig = await Rig()
        let result = await rig.finish { try await rig.commands.setPrediction(F.serial, mode: .removalAndResting, setpoint: 57) }
        #expect(throws: CommandError.notConfirmed) { try result.get() }
        #expect(rig.clock.monotonic() >= .seconds(5) && rig.clock.monotonic() < .seconds(7), "waits 5 s on the clock")
    }

    @Test func aStatusWithADifferentSetpointDoesNotConfirm() async {
        let rig = await Rig()
        rig.probeApplies { _ in (AlarmConfig(), F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 50)) }
        let result = await rig.finish { try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: 63) }
        #expect(throws: CommandError.notConfirmed) { try result.get() }
    }

    @Test func cancelPredictionSendsModeNone() async throws {
        let rig = await Rig(prediction: F.prediction(state: .predicting, mode: .timeToRemoval, setpoint: 60))
        rig.probeApplies { _ in (AlarmConfig(), F.prediction()) }
        try await rig.commands.cancelPrediction(F.serial)
        #expect(rig.route.requests == [.setPrediction(setpoint: 0, mode: .none)])
    }

    // MARK: Validation

    @Test func outOfRangeValuesAreRejectedBeforeAnythingIsSent() async {
        let rig = await Rig()
        await #expect(throws: CommandError.outOfRange(field: "setpoint")) {
            try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: 102.4)
        }
        await #expect(throws: CommandError.outOfRange(field: "setpoint")) {
            try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: -0.1)
        }
        await #expect(throws: CommandError.outOfRange(field: "setpoint")) {
            try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: .nan)
        }
        await #expect(throws: CommandError.outOfRange(field: "mode")) {
            try await rig.commands.setPrediction(F.serial, mode: .none, setpoint: 60)
        }
        await #expect(throws: CommandError.outOfRange(field: "temperature")) {
            try await rig.commands.setAlarm(F.serial, channel: .core, kind: .high, temperature: 800)
        }
        await #expect(throws: CommandError.outOfRange(field: "temperature")) {
            try await rig.commands.setAlarm(F.serial, channel: .core, kind: .low, temperature: -20.5)
        }
        var bad = AlarmConfig()
        bad.high[.ambient] = Alarm(isSet: true, temperature: 900)
        await #expect(throws: CommandError.outOfRange(field: "high.ambient")) {
            try await rig.commands.setAlarms(F.serial, bad)
        }
        #expect(rig.route.requests.isEmpty)
    }

    @Test func limitsThemselvesAreAccepted() async throws {
        let rig = await Rig()
        rig.probeApplies { request in
            switch request {
            case .setPrediction(let sp, let mode): return (AlarmConfig(), F.prediction(state: .predicting, mode: mode, setpoint: sp))
            case .setAlarms(let c): return (c, F.prediction())
            default: return (AlarmConfig(), F.prediction())
            }
        }
        try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: 102.3)
        try await rig.commands.setPrediction(F.serial, mode: .timeToRemoval, setpoint: 0)
        try await rig.commands.setAlarm(F.serial, channel: .ambient, kind: .high, temperature: 799)
        try await rig.commands.setAlarm(F.serial, channel: .ambient, kind: .low, temperature: -20)
    }

    // MARK: Routing and errors

    @Test func notReachableWhenNoRouteExists() async {
        let rig = await Rig()
        rig.route.setReachable(false)
        await #expect(throws: CommandError.notReachable) { try await rig.commands.silenceAlarms(F.serial) }
    }

    @Test func uartFailureIsWrapped() async {
        let rig = await Rig()
        rig.route.onSend { _ in throw UartError.failure }
        await #expect(throws: CommandError.uart(.failure)) { try await rig.commands.silenceAlarms(F.serial) }
        rig.route.onSend { _ in throw UartError.timeout }
        await #expect(throws: CommandError.uart(.timeout)) { try await rig.commands.cancelPrediction(F.serial) }
    }

    // MARK: Alarms: read-modify-write

    @Test func setAlarmChangesOneEntryAndResendsTheRest() async throws {
        let existing = Self.alarms(high: [.core: Alarm(isSet: true, temperature: 80, tripped: true, alarming: false)],
                              low: [.surface: Alarm(isSet: true, temperature: 5)])
        let rig = await Rig(alarms: existing)
        rig.probeApplies { request in
            if case .setAlarms(let c) = request { return (c, F.prediction()) }
            return (existing, F.prediction())
        }
        try await rig.commands.setAlarm(F.serial, channel: .ambient, kind: .high, temperature: 200)

        guard case .setAlarms(let sent)? = rig.route.requests.first else { Issue.record("no setAlarms")
            return
        }
        #expect(sent.high[.ambient] == Alarm(isSet: true, temperature: 200))
        #expect(sent.high[.core] == Alarm(isSet: true, temperature: 80), "other entries kept, read-only bits cleared")
        #expect(sent.low[.surface] == Alarm(isSet: true, temperature: 5))
        #expect((try? sent.packed().count) == 44, "all 22 entries go on the wire")
    }

    @Test func setAlarmWithNilClearsIt() async throws {
        let existing = Self.alarms(high: [.core: Alarm(isSet: true, temperature: 80)])
        let rig = await Rig(alarms: existing)
        rig.probeApplies { request in
            if case .setAlarms(let c) = request { return (c, F.prediction()) }
            return (existing, F.prediction())
        }
        try await rig.commands.setAlarm(F.serial, channel: .core, kind: .high, temperature: nil)
        guard case .setAlarms(let sent)? = rig.route.requests.first else { Issue.record("no setAlarms")
            return
        }
        #expect(sent.high[.core]?.isSet == false)
    }

    @Test func setAlarmNeedsAFullStatusFirst() async {
        let rig = await Rig(alarms: nil)
        await #expect(throws: CommandError.alarmStateUnknown) {
            try await rig.commands.setAlarm(F.serial, channel: .core, kind: .high, temperature: 70)
        }
        // A status without alarms (old firmware) is the same as none.
        await rig.push(alarms: nil)
        await #expect(throws: CommandError.alarmStateUnknown) {
            try await rig.commands.setAlarm(F.serial, channel: .core, kind: .high, temperature: 70)
        }
        #expect(rig.route.requests.isEmpty)
    }

    @Test func setAlarmNotConfirmedIfAnotherWriterWinsTheRace() async {
        let rig = await Rig()
        // The phone app wrote its own value just after ours.
        let theirs = Self.alarms(high: [.core: Alarm(isSet: true, temperature: 90)])
        rig.probeApplies { _ in (theirs, F.prediction()) }
        let result = await rig.finish { try await rig.commands.setAlarm(F.serial, channel: .core, kind: .high, temperature: 70) }
        #expect(throws: CommandError.notConfirmed) { try result.get() }
    }

    @Test func setAlarmsReplacesEverythingAndMissingChannelsAreUnset() async throws {
        let existing = Self.alarms(high: [.core: Alarm(isSet: true, temperature: 80)])
        let rig = await Rig(alarms: existing)
        rig.probeApplies { request in
            if case .setAlarms(let c) = request { return (c, F.prediction()) }
            return (existing, F.prediction())
        }
        var replacement = AlarmConfig()
        replacement.low[.ambient] = Alarm(isSet: true, temperature: 100)
        try await rig.commands.setAlarms(F.serial, replacement)
        guard case .setAlarms(let sent)? = rig.route.requests.first else { Issue.record("no setAlarms")
            return
        }
        #expect(sent.high[.core] == nil || sent.high[.core]?.isSet == false)
        #expect(sent.low[.ambient]?.isSet == true)
    }

    @Test func twoSetAlarmCallsOnOneProbeDoNotOverwriteEachOther() async throws {
        let rig = await Rig()
        // The probe keeps what it is sent; each status reflects the latest config.
        let state = StoreLog<AlarmConfig>()
        state.add(AlarmConfig())
        let store = rig.store, clock = rig.clock
        rig.route.onSend { request in
            guard case .setAlarms(let c) = request else { return }
            state.add(c)
            await store.ingest(F.observe(.status(F.status(logMax: 1, alarms: c)), kind: .directConnection, at: clock.now()))
        }
        async let a: Void = rig.commands.setAlarm(F.serial, channel: .core, kind: .high, temperature: 80)
        async let b: Void = rig.commands.setAlarm(F.serial, channel: .ambient, kind: .high, temperature: 200)
        _ = try await (a, b)
        let final = try #require(state.last)
        #expect(final.high[.core]?.isSet == true && final.high[.ambient]?.isSet == true,
                "the second call read the first one's result")
        #expect(rig.route.requests.count == 2)
    }

    // MARK: Silence

    @Test func silenceIsConfirmedOnlyOnceNothingIsAlarming() async throws {
        let alarming = Self.alarms(high: [.core: Alarm(isSet: true, temperature: 60, tripped: true, alarming: true)])
        let rig = await Rig(alarms: alarming)
        let quiet = Self.alarms(high: [.core: Alarm(isSet: true, temperature: 60, tripped: true, alarming: false)])
        let store = rig.store, clock = rig.clock
        rig.route.onSend { _ in
            // First a status that still alarms (sent before the probe handled the command), then the quiet one.
            await store.ingest(F.observe(.status(F.status(logMax: 1, alarms: alarming)), kind: .directConnection, at: clock.now()))
            await store.ingest(F.observe(.status(F.status(logMax: 2, alarms: quiet)), kind: .directConnection, at: clock.now()))
        }
        try await rig.commands.silenceAlarms(F.serial)
        #expect(rig.route.requests == [.silenceAlarms])
    }

    @Test func silenceNotConfirmedWhileStillAlarming() async {
        let alarming = Self.alarms(low: [.surface: Alarm(isSet: true, temperature: 60, tripped: true, alarming: true)])
        let rig = await Rig(alarms: alarming)
        rig.probeApplies { _ in (alarming, F.prediction()) }
        let result = await rig.finish { try await rig.commands.silenceAlarms(F.serial) }
        #expect(throws: CommandError.notConfirmed) { try result.get() }
    }

    // MARK: Trace

    @Test func commandsEmitTraceLines() async throws {
        let clock = TestClock()
        let trace = try JSONLTraceSink(clock: clock)
        let store = ProbeStore(clock: clock)
        let route = FakeRoute()
        let commands = Commands(probes: store, routing: route, clock: clock, trace: trace)
        route.setReachable(false)
        _ = try? await commands.silenceAlarms(F.serial)
        #expect(trace.lines.count == 1)
        #expect(trace.lines[0].contains("\"op\":\"silenceAlarms\"") && trace.lines[0].contains("\"result\":\"notReachable\""))
    }
}
