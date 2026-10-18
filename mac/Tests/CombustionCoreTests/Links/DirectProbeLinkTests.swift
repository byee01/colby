import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

private func statusPayload(core: Double = 54.35, logMax: UInt32 = 10, session: SessionInfo? = nil) -> ProbeStatusPayload {
    ProbeStatusPayload(
        logRange: LogRange(min: 0, max: logMax),
        temperatures: try! ProbeTemperatures(celsius: (0..<8).map { _ in core }),
        mode: .normal, color: .yellow, probeNumber: 1, batteryLow: false,
        virtualSensors: try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8),
        prediction: PredictionStatus(
            state: .predicting, mode: .timeToRemoval, type: .removal,
            setpoint: 60, heatStart: 20, rawSecondsRemaining: 1800, estimatedCore: 50),
        foodSafe: FoodSafe(mode: .simplified, product: 1, serving: .servedImmediately, state: .notSafe),
        overheating: [], preferences: ThermometerPreferences(powerMode: .normal, highRadioPower: true),
        alarms: AlarmConfig(),
        session: session)
}

struct DirectProbeLinkTests {
    private func makeLink(_ rig: LinkRig) async throws -> DirectProbeLink {
        let link = DirectProbeLink(serial: linkProbe, connection: rig.connection, clock: rig.clock)
        try await link.start()
        return link
    }

    @Test func statusNotificationsBecomeObservations() async throws {
        let rig = try await LinkRig()
        let link = DirectProbeLink(serial: linkProbe, connection: rig.connection, clock: rig.clock)
        let obs = link.observations
        try await link.start()
        let session = SessionInfo(sessionId: 42, samplePeriodMs: 5000)
        let bytes = try encodeProbeStatus(statusPayload(session: session))
        rig.notify(bytes, on: .probeStatus)
        var it = obs.makeAsyncIterator()
        let o = try #require(await it.next())
        #expect(o.serial == linkProbe)
        #expect(o.source.kind == .directConnection)
        #expect(o.source.via == nil)
        #expect(o.source.rssi == nil)
        #expect(o.source.highRadioPower == true)
        #expect(o.source.lastSeen == rig.clock.now())
        #expect(o.receivedAt == rig.clock.now())
        #expect(o.payload == .status(try decodeProbeStatus(bytes)))

        await rig.clock.advance(by: .seconds(5))
        rig.notify(try encodeProbeStatus(statusPayload(core: 55)), on: .probeStatus)
        let second = try #require(await it.next())
        #expect(second.receivedAt == rig.clock.now())
        guard case .status(let p) = second.payload else { Issue.record("expected status"); return }
        #expect(abs(p.temperatures[.t1] - 55) < 0.05)
    }

    @Test func undecodableStatusIsCounted() async throws {
        let rig = try await LinkRig()
        let link = DirectProbeLink(serial: linkProbe, connection: rig.connection, clock: rig.clock)
        let obs = link.observations
        try await link.start()
        rig.notify([1, 2, 3], on: .probeStatus)
        rig.notify(try encodeProbeStatus(statusPayload()), on: .probeStatus)
        _ = await firstValue(obs)
        #expect(await link.statusDecodeErrors == 1)
    }

    @Test func readLogsThroughSimulatedProbe() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .probe), case .readLogs(let s, let e) = msg.request else { return [] }
            return (s...e).map(probeLogReply)
        }
        let fetcher: any LogFetcher = link
        let records = try await collectLogs(fetcher.readLogs(probe: linkProbe, start: 5, end: 9))
        #expect(records == (5...9).map(linkRecord))
    }

    @Test func readLogsForAnotherProbeFails() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        await #expect(throws: UartError.failure) { try await collectLogs(link.readLogs(probe: otherProbe, start: 1, end: 2)) }
        #expect(rig.transport.writes.isEmpty)
    }

    /// Live fetches and backfill share one link; the probe UART allows one Read Logs at a time, so the
    /// second caller must wait for its turn rather than fail with `.busy`.
    @Test func concurrentReadLogsAreSerializedNotRejectedAsBusy() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .probe), case .readLogs(let s, let e) = msg.request else { return [] }
            return (s...e).map(probeLogReply)
        }
        async let first = collectLogs(link.readLogs(probe: linkProbe, start: 0, end: 4))
        async let second = collectLogs(link.readLogs(probe: linkProbe, start: 10, end: 14))
        async let third = collectLogs(link.readLogs(probe: linkProbe, start: 20, end: 21))
        let (a, b, c) = try await (first, second, third)
        #expect(a == (0...4).map(linkRecord))
        #expect(b == (10...14).map(linkRecord))
        #expect(c == (20...21).map(linkRecord))
        #expect(rig.transport.writes.count == 3)
    }

    @Test func readLogsIdleTimeoutUsesTheClock() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        var it = link.readLogs(probe: linkProbe, start: 1, end: 9).makeAsyncIterator()
        await rig.waitForWrites(1)
        rig.notify(probeLogReply(1))
        #expect(try await takeLogs(1, from: &it) == [1])
        await rig.clock.advance(by: .seconds(2))
        #expect(try await it.next() == nil)
    }

    @Test func readSessionInfoAndSendPassthrough() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .probe) else { return [] }
            switch msg.request {
            case .readSessionInfo:
                return [probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession))]
            case .silenceAlarms:
                return [probeReply(UartMessageType.silenceAlarms)]
            default:
                return []
            }
        }
        #expect(try await link.readSessionInfo() == linkSession)
        #expect(try await link.send(.silenceAlarms).body == .ack)
    }

    @Test func startFailsWhenCharacteristicsAreMissing() async throws {
        let rig = try await LinkRig()
        rig.transport.setGattProfile([GattService(uuid: .uartService, characteristics: [.uartRX, .uartTX])])
        let link = DirectProbeLink(serial: linkProbe, connection: rig.connection, clock: rig.clock)
        await #expect(throws: TransportError.characteristicNotFound(.probeStatus)) { try await link.start() }
        var it = link.disconnected.makeAsyncIterator()
        #expect(await it.next() == .requested)
        // The failed start released the connection slot.
        _ = try await rig.transport.connect(linkPeripheral, timeout: .seconds(1))
    }

    @Test func disconnectEndsStreamsAndFailsPendingRequests() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        let obs = link.observations
        let pending = Task { try await link.send(.readSessionInfo) }
        let logs = link.readLogs(probe: linkProbe, start: 1, end: 5)
        await rig.waitForWrites(2)

        rig.transport.forceDisconnect(linkPeripheral, reason: .linkLost)

        var it = link.disconnected.makeAsyncIterator()
        #expect(await it.next() == .linkLost)
        #expect(await it.next() == nil)
        var observed = obs.makeAsyncIterator()
        #expect(await observed.next() == nil)
        await #expect(throws: UartError.disconnected) { try await pending.value }
        await #expect(throws: UartError.disconnected) { try await collectLogs(logs) }
        // Late subscribers still learn why.
        var late = link.disconnected.makeAsyncIterator()
        #expect(await late.next() == .linkLost)
        await #expect(throws: UartError.disconnected) { try await link.send(.silenceAlarms) }
    }

    @Test func closeClosesTheConnectionAndFinishesStreams() async throws {
        let rig = try await LinkRig()
        let link = try await makeLink(rig)
        let obs = link.observations
        await link.close()
        var it = link.disconnected.makeAsyncIterator()
        #expect(await it.next() == .requested)
        var observed = obs.makeAsyncIterator()
        #expect(await observed.next() == nil)
        await #expect(throws: UartError.disconnected) { try await link.send(.silenceAlarms) }
        // The slot on the transport is free again.
        _ = try await rig.transport.connect(linkPeripheral, timeout: .seconds(1))
    }
}
