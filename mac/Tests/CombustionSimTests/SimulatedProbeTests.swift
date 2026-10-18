import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

private let serial = ProbeSerial(0x1000_5A3F)

private struct Rig {
    let clock = TestClock()
    let transport: SimulatedTransport
    let probe: SimulatedProbe
    init(sessionId: UInt32 = 9, preload: Int = 0) {
        transport = SimulatedTransport(clock: clock)
        probe = SimulatedProbe(serial: serial, transport: transport, clock: clock, sessionId: sessionId)
        if preload > 0 { probe.preload(records: preload) }
    }

    /// Advances in 250 ms ticks and lets the probe's task run after each.
    func advance(_ d: Duration) async {
        var left = d
        while left > .zero {
            let step = min(left, .milliseconds(250))
            await clock.advance(by: step)
            for _ in 0..<20 { await Task.yield() }
            left -= step
        }
    }

    func request(_ r: UartRequest, on connection: any GattConnection) async throws {
        try await connection.write(.uartRX, try encodeRequest(variant: .probe, r), withResponse: true)
    }
}

/// Collects frames from a stream until `count` arrive.
private func frames(_ stream: AsyncStream<[UInt8]>, count: Int) async -> [UartResponse] {
    var framer = UartFramer(variant: .probe, direction: .response)
    var out: [UartResponse] = []
    for await bytes in stream {
        for case .frame(let f) in framer.push(bytes) {
            if let r = try? decodeResponse(f) { out.append(r) }
        }
        if out.count >= count { break }
    }
    return out
}

struct SimulatedProbeTests {
    @Test func advertisesEveryQuarterSecondOnlyWhileInRange() async throws {
        let rig = Rig()
        rig.probe.start()
        await rig.transport.startScan()
        let ads = rig.transport.advertisements
        let seen = Counter()
        let task = Task { for await _ in ads { seen.increment() } }
        await rig.advance(.seconds(2))
        let inRange = seen.value
        #expect(inRange == 8)

        rig.probe.setInRange(false)
        await rig.advance(.seconds(2))
        #expect(seen.value == inRange)
        rig.probe.setInRange(true)
        await rig.advance(.seconds(1))
        #expect(seen.value == inRange + 4)
        task.cancel()
    }

    @Test func advertisementCarriesSerialAndEightTemperatures() async throws {
        let rig = Rig(preload: 200)
        rig.probe.start()
        await rig.transport.startScan()
        let ads = rig.transport.advertisements
        let first = Task { () -> RawAdvertisement? in
            for await a in ads { return a }
            return nil
        }
        await rig.advance(.milliseconds(250))
        let raw = try #require(await first.value)
        guard case .probe(let ad) = try decodeAdvertisement(raw.mfrData) else { Issue.record("not a probe packet"); return }
        #expect(ad.serial == serial)
        #expect(ad.temperatures.celsius == rig.probe.record(200)!.temperatures.celsius)
        // The default cook curve spreads the sensors: T8 (ambient) leads T1 (core).
        #expect(ad.temperatures[.t8] > ad.temperatures[.t1])
    }

    @Test func logsOneRecordPerSamplePeriodAndSendsStatusOnlyWhenConnected() async throws {
        let rig = Rig()
        rig.probe.start()
        await rig.transport.startScan()
        await rig.advance(.seconds(10))
        #expect(rig.probe.logRange == LogRange(min: 0, max: 2))

        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let status = try await connection.subscribe(.probeStatus)
        let task = Task { () -> ProbeStatusPayload? in
            for await bytes in status { return try? decodeProbeStatus(bytes) }
            return nil
        }
        await rig.advance(.seconds(5))
        let payload = try #require(await task.value)
        #expect(payload.logRange == LogRange(min: 0, max: 3))
        #expect(payload.session == SessionInfo(sessionId: 9, samplePeriodMs: 5000))
        #expect(payload.temperatures == rig.probe.record(3)!.temperatures)
    }

    @Test func answersSessionInfoAndLogRequests() async throws {
        let rig = Rig(preload: 20)
        rig.probe.start()
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let tx = try await connection.subscribe(.uartTX)

        try await rig.request(.readSessionInfo, on: connection)
        try await rig.request(.readLogs(start: 5, end: 8), on: connection)
        let responses = await frames(tx, count: 5)
        #expect(responses.first?.body == .sessionInfo(probe: nil, SessionInfo(sessionId: 9, samplePeriodMs: 5000)))
        let records = responses.dropFirst().compactMap { r -> LogRecord? in
            if case .logRecord(_, let rec) = r.body { return rec } else { return nil }
        }
        #expect(records.map(\.sequence) == [5, 6, 7, 8])
        #expect(records.map(\.temperatures) == (5...8).map { rig.probe.record($0)!.temperatures })
        #expect(rig.probe.requests == [.readSessionInfo, .readLogs(start: 5, end: 8)])
    }

    @Test func readLogsBeyondTheEndIsClampedAndPastTheEndIsSilent() async throws {
        let rig = Rig(preload: 4) // seqs 0...4
        rig.probe.start()
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let tx = try await connection.subscribe(.uartTX)
        try await rig.request(.readLogs(start: 3, end: 100), on: connection)
        try await rig.request(.readLogs(start: 50, end: 60), on: connection)
        try await rig.request(.silenceAlarms, on: connection)
        let responses = await frames(tx, count: 3)
        #expect(responses.map(\.messageType) == [4, 4, UartMessageType.silenceAlarms])
    }

    @Test func commandsAreAcknowledgedAndRemembered() async throws {
        let rig = Rig()
        rig.probe.start()
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let tx = try await connection.subscribe(.uartTX)
        let alarms = AlarmConfig(high: [.core: Alarm(isSet: true, temperature: 70)])
        try await rig.request(.setPrediction(setpoint: 63, mode: .timeToRemoval), on: connection)
        try await rig.request(.setAlarms(alarms), on: connection)
        try await rig.request(.silenceAlarms, on: connection)
        let responses = await frames(tx, count: 3)
        #expect(responses.map(\.messageType) == [UartMessageType.setPrediction, UartMessageType.setAlarms, UartMessageType.silenceAlarms])
        #expect(responses.allSatisfy { $0.success && $0.body == .ack })
        #expect(rig.probe.currentPrediction.setpoint == 63)
        #expect(rig.probe.currentPrediction.mode == .timeToRemoval)
        #expect(rig.probe.currentAlarms.high[.core]?.temperature == 70)
    }

    // MARK: Prediction, alarms, silence

    /// Statuses the app would receive, decoded, newest last.
    private final class StatusLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [ProbeStatusPayload] = []
        func add(_ s: ProbeStatusPayload) { lock.withLock { items.append(s) } }
        var all: [ProbeStatusPayload] { lock.withLock { items } }
    }

    private func listen(_ rig: Rig) async throws -> (any GattConnection, StatusLog) {
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let stream = try await connection.subscribe(.probeStatus)
        let log = StatusLog()
        Task { for await b in stream { if let s = try? decodeProbeStatus(b) { log.add(s) } } }
        return (connection, log)
    }

    @Test func setPredictionStartsACountdownAndStatusShowsItAtOnce() async throws {
        let rig = Rig()
        rig.probe.predictionLeadSeconds = 100
        rig.probe.start()
        let (connection, statuses) = try await listen(rig)
        await rig.advance(.seconds(5))
        let before = statuses.all.count
        #expect(statuses.all.last?.prediction.state == .notInserted)

        try await rig.request(.setPrediction(setpoint: 63, mode: .timeToRemoval), on: connection)
        for _ in 0..<50 { await Task.yield() }
        let now = try #require(statuses.all.dropFirst(before).first, "a status right after the command, not at the next sample")
        #expect(now.prediction.state == .predicting)
        #expect(now.prediction.mode == .timeToRemoval && now.prediction.type == .removal)
        #expect(now.prediction.setpoint == 63)
        #expect(now.prediction.rawSecondsRemaining == 100)

        await rig.advance(.seconds(30))
        let later = try #require(statuses.all.last)
        #expect(later.prediction.rawSecondsRemaining == 70)
        #expect(later.prediction.estimatedCore > now.prediction.estimatedCore, "the estimate climbs toward the set point")
        // The log records carry the same prediction.
        let record = try #require(rig.probe.record(later.logRange.max))
        #expect(record.prediction.state == .predicting && record.prediction.rawSecondsRemaining == 70)
    }

    @Test func predictionEndsDoneAndRemovalAndRestingContinuesIntoResting() async throws {
        let rig = Rig()
        rig.probe.predictionLeadSeconds = 20
        rig.probe.restingSeconds = 15
        rig.probe.start()
        let (connection, statuses) = try await listen(rig)
        try await rig.request(.setPrediction(setpoint: 60, mode: .removalAndResting), on: connection)
        await rig.advance(.seconds(60))
        let phases = statuses.all.map { "\($0.prediction.state)/\($0.prediction.type)" }
        var collapsed: [String] = []
        for p in phases where collapsed.last != p { collapsed.append(p) }
        #expect(collapsed.suffix(4) == [
            "predicting/removal", "removalPredictionDone/removal", "predicting/resting", "removalPredictionDone/resting",
        ], "\(collapsed)")
    }

    @Test func cancellingThePredictionResetsIt() async throws {
        let rig = Rig()
        rig.probe.start()
        let (connection, statuses) = try await listen(rig)
        try await rig.request(.setPrediction(setpoint: 60, mode: .timeToRemoval), on: connection)
        try await rig.request(.setPrediction(setpoint: 0, mode: .none), on: connection)
        for _ in 0..<50 { await Task.yield() }
        #expect(statuses.all.last?.prediction.state == .notInserted)
        #expect(statuses.all.last?.prediction.mode == PredictionMode.none)
    }

    @Test func alarmTripsWhenTheTemperatureIsReachedAndSilenceQuietsItButKeepsItTripped() async throws {
        let rig = Rig()
        rig.probe.setCurve { seq, _ in [Double](repeating: 20 + Double(seq), count: 8) }   // +1 °C per sample
        rig.probe.start()
        let (connection, statuses) = try await listen(rig)
        let config = AlarmConfig(high: [.core: Alarm(isSet: true, temperature: 24), .ambient: Alarm(isSet: true, temperature: 90)],
                                 low: [.surface: Alarm(isSet: true, temperature: 21)])
        try await rig.request(.setAlarms(config), on: connection)
        for _ in 0..<50 { await Task.yield() }
        // Set while the probe reads 20 °C: the low surface alarm (21) is not reached and the high ones are not either.
        #expect(statuses.all.last?.alarms?.high[.core]?.alarming == false)
        #expect(statuses.all.last?.alarms?.high[.core]?.isSet == true)

        await rig.advance(.seconds(25))   // the record reaches 24 and beyond
        let tripped = try #require(statuses.all.last?.alarms)
        #expect(tripped.high[.core]?.tripped == true && tripped.high[.core]?.alarming == true)
        #expect(tripped.high[.ambient]?.tripped == false, "90 °C is not reached")

        try await rig.request(.silenceAlarms, on: connection)
        for _ in 0..<50 { await Task.yield() }
        let quiet = try #require(statuses.all.last?.alarms)
        #expect(quiet.high[.core]?.alarming == false && quiet.high[.core]?.tripped == true)
        await rig.advance(.seconds(15))
        #expect(statuses.all.last?.alarms?.high[.core]?.alarming == false, "silenced stays silenced")
    }

    @Test func alarmsAlreadyBeyondTheirTemperatureTripAtOnce() async throws {
        let rig = Rig(preload: 10)
        rig.probe.setCurve { _, _ in [Double](repeating: 50, count: 8) }
        rig.probe.preload(records: 1)   // a record made with the new curve
        rig.probe.start()
        let (connection, statuses) = try await listen(rig)
        try await rig.request(.setAlarms(AlarmConfig(low: [.core: Alarm(isSet: true, temperature: 60)])), on: connection)
        for _ in 0..<50 { await Task.yield() }
        #expect(statuses.all.last?.alarms?.low[.core]?.alarming == true)
        // Read-only bits sent by the app are ignored.
        try await rig.request(.setAlarms(AlarmConfig(low: [.core: Alarm(isSet: false, temperature: 60, tripped: true, alarming: true)])), on: connection)
        for _ in 0..<50 { await Task.yield() }
        #expect(statuses.all.last?.alarms?.low[.core]?.alarming == false)
    }

    @Test func batteryAndOverheatAreReportedInAdvertisementAndStatus() async throws {
        let rig = Rig()
        rig.probe.batteryLow = true
        rig.probe.overheating = [.t2]
        rig.probe.start()
        await rig.transport.startScan()
        let ads = rig.transport.advertisements
        let first = Task { () -> RawAdvertisement? in
            for await a in ads { return a }
            return nil
        }
        let (_, statuses) = try await listen(rig)
        await rig.advance(.seconds(5))
        guard case .probe(let ad) = try decodeAdvertisement(try #require(await first.value).mfrData) else {
            Issue.record("not a probe packet")
            return
        }
        #expect(ad.batteryLow && ad.overheating == [.t2])
        #expect(statuses.all.last?.batteryLow == true && statuses.all.last?.overheating == [.t2])
    }

    @Test func outOfRangeDropsTheLinkAndRefusesConnects() async throws {
        let rig = Rig()
        rig.probe.start()
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        var drops = connection.disconnected.makeAsyncIterator()
        rig.probe.setInRange(false)
        #expect(await drops.next() == .linkLost)
        await #expect(throws: TransportError.connectionRefused(rig.probe.peripheral)) {
            _ = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        }
        rig.probe.setInRange(true)
        _ = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
    }

    @Test func newSessionRestartsTheLogWithANewId() async throws {
        let rig = Rig(sessionId: 5, preload: 50)
        rig.probe.start()
        #expect(rig.probe.logRange.max == 50)
        rig.probe.newSession()
        #expect(rig.probe.sessionId == 6)
        #expect(rig.probe.logRange == LogRange(min: 0, max: 0))
        await rig.advance(.seconds(10))
        #expect(rig.probe.logRange.max == 2)
        rig.probe.newSession(sessionId: 1000)
        #expect(rig.probe.sessionId == 1000)
    }

    @Test func legacyFirmwareHasNoSessionIdAndRejectsSessionInfo() async throws {
        let rig = Rig()
        rig.probe.legacyFirmware = true
        rig.probe.start()
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let status = try await connection.subscribe(.probeStatus)
        let tx = try await connection.subscribe(.uartTX)
        let bytes = Task { () -> [UInt8]? in
            for await b in status { return b }
            return nil
        }
        await rig.advance(.seconds(5))
        let raw = try #require(await bytes.value)
        #expect(raw.count == 94)
        #expect(try decodeProbeStatus(raw).session == nil)

        try await rig.request(.readSessionInfo, on: connection)
        let r = try #require(await frames(tx, count: 1).first)
        #expect(!r.success)
    }

    @Test func linkDropsAfterAPartialLogDownload() async throws {
        let rig = Rig(preload: 99)
        rig.probe.start()
        let connection = try await rig.transport.connect(rig.probe.peripheral, timeout: .seconds(1))
        let tx = try await connection.subscribe(.uartTX)
        var drops = connection.disconnected.makeAsyncIterator()
        rig.probe.dropLinkAfterLogRecords(10)
        try await rig.request(.readLogs(start: 0, end: 99), on: connection)
        #expect(await frames(tx, count: 10).count == 10)
        await rig.advance(.milliseconds(250))
        #expect(await drops.next() == .linkLost)
    }

    @Test func customCurveShapesTheRecords() async throws {
        let rig = Rig()
        rig.probe.setCurve { seq, _ in [Double](repeating: 30 + Double(seq), count: 8) }
        rig.probe.start()
        await rig.advance(.seconds(10))
        #expect(rig.probe.record(2)!.temperatures[.t3] == 32)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func increment() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
