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
