import CombustionCore
import CombustionSim
import Foundation
import Testing

struct ReplayAndRecordingTests {
    private let uartTX = GattUUID.uartTX.rawValue
    private let uartRX = GattUUID.uartRX.rawValue
    private let status = GattUUID.probeStatus.rawValue

    @Test func replayDeliversTimelineOnClockTime() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        await sim.startScan()
        var advs = sim.advertisements.makeAsyncIterator()
        sim.startReplay([
            ReplayEvent(t: 1, type: .adv, peripheral: "PROBE-A", hex: "01"),
            ReplayEvent(t: 2, type: .adv, peripheral: "PROBE-A", hex: "02"),
            ReplayEvent(t: 2, type: .adv, peripheral: "PROBE-A", hex: "03"),
        ])
        await clock.advance(by: .milliseconds(1500))
        #expect(await advs.next()?.mfrData == [1])
        await clock.advance(by: .milliseconds(500))
        #expect(await advs.next()?.mfrData == [2])
        #expect(await advs.next()?.mfrData == [3])
    }

    @Test func replayStateAndDisconnectEvents() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        var disc = c.disconnected.makeAsyncIterator()
        var states = sim.state.makeAsyncIterator()
        #expect(await states.next() == .poweredOn)
        sim.startReplay([
            ReplayEvent(t: 1, type: .disconnect, peripheral: "PROBE-A"),
            ReplayEvent(t: 2, type: .state, state: "poweredOff"),
        ])
        await clock.advance(by: .seconds(2))
        #expect(await disc.next() == .linkLost)
        #expect(await states.next() == .poweredOff)
    }

    @Test func recordedWritesAreAnsweredByTypeByteNotByFullFrame() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        let req = frame(type: 0x04, crc: 0x11, payload: [1])
        let resp1 = frame(type: 0x84, payload: [9, 9])
        let resp2 = frame(type: 0x85)
        sim.startReplay([
            ReplayEvent(t: 0.1, type: .write, peripheral: "PROBE-A", char: uartRX, hex: HexString.encode(req)),
            ReplayEvent(t: 0.2, type: .notify, peripheral: "PROBE-A", char: uartTX, hex: HexString.encode(resp1)),
            ReplayEvent(t: 0.3, type: .notify, peripheral: "PROBE-A", char: uartTX, hex: HexString.encode(resp2)),
        ])
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        var tx = try await c.subscribe(.uartTX).makeAsyncIterator()
        // Different CRC and payload, same type byte.
        try await c.write(.uartRX, frame(type: 0x04, crc: 0x77, payload: [5, 6, 7]), withResponse: true)
        #expect(await tx.next() == resp1)
        #expect(await tx.next() == resp2)
        // Repeats reuse the last recording.
        try await c.write(.uartRX, frame(type: 0x04), withResponse: true)
        #expect(await tx.next() == resp1)
        // An unknown type is unanswered.
        try await c.write(.uartRX, frame(type: 0x09), withResponse: true)
        sim.injectNotification(peripheral: probeA, characteristic: .uartTX, bytes: [0xEE])
        _ = await tx.next()  // consume resp2 of the repeat
        #expect(await tx.next() == [0xEE])
    }

    @Test func recordedResponseDelaysCanBeHonoured() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        var opts = SimulatedTransport.ReplayOptions()
        opts.useRecordedResponseDelays = true
        sim.startReplay([
            ReplayEvent(t: 0, type: .write, peripheral: "PROBE-A", char: uartRX, hex: HexString.encode(frame(type: 1))),
            ReplayEvent(t: 0.5, type: .notify, peripheral: "PROBE-A", char: uartTX, hex: "AA"),
        ], options: opts)
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        var tx = try await c.subscribe(.uartTX).makeAsyncIterator()
        try await c.write(.uartRX, frame(type: 1), withResponse: true)
        await clock.advance(by: .milliseconds(500))
        #expect(await tx.next() == [0xAA])
    }

    @Test func matcherCanBeSwapped() async throws {
        struct WholeFrame: WriteMatcher {
            func key(char: GattUUID, bytes: [UInt8]) -> String { HexString.encode(bytes) }
        }
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock, matcher: WholeFrame())
        let req = frame(type: 2, crc: 5)
        sim.startReplay([
            ReplayEvent(t: 0, type: .write, peripheral: "PROBE-A", char: uartRX, hex: HexString.encode(req)),
            ReplayEvent(t: 0, type: .notify, peripheral: "PROBE-A", char: uartTX, hex: "AB"),
        ])
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        var tx = try await c.subscribe(.uartTX).makeAsyncIterator()
        try await c.write(.uartRX, frame(type: 2, crc: 6), withResponse: true)  // different CRC: no match
        try await c.write(.uartRX, req, withResponse: true)
        #expect(await tx.next() == [0xAB])
    }

    @Test func probeStatusNotificationsStayOnTimelineEvenAfterWrites() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        sim.startReplay([
            ReplayEvent(t: 0, type: .write, peripheral: "PROBE-A", char: uartRX, hex: HexString.encode(frame(type: 1))),
            ReplayEvent(t: 1, type: .notify, peripheral: "PROBE-A", char: status, hex: "07"),
        ])
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        var st = try await c.subscribe(.probeStatus).makeAsyncIterator()
        await clock.advance(by: .seconds(1))
        #expect(await st.next() == [7])
    }

    @Test func recordThenReadBackThenReplayMatchesEventSequence() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // 1. Record a scripted session.
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        let request = frame(type: 0x01, crc: 0x22, payload: [1])
        let response = frame(type: 0x81, payload: [4, 5])
        sim.addResponder { w in w[4] == 0x01 ? [response] : [] }
        let writer = try ReplayWriter(directory: dir, meta: ReplayMeta(name: "scripted", devices: [.init(peripheral: "PROBE-A")]))
        let rec = RecordingTransport(inner: sim, writer: writer, clock: clock)

        var states = rec.state.makeAsyncIterator()
        #expect(await states.next() == .poweredOn)
        await rec.startScan()
        var advs = rec.advertisements.makeAsyncIterator()
        sim.injectAdvertisement(peripheral: probeA, mfrData: mfr, rssi: -61)
        #expect(await advs.next()?.rssi == -61)
        let conn = try await rec.connect(probeA, timeout: .seconds(5))
        var tx = try await conn.subscribe(.uartTX).makeAsyncIterator()
        var st = try await conn.subscribe(.probeStatus).makeAsyncIterator()
        var disc = conn.disconnected.makeAsyncIterator()
        await clock.advance(by: .milliseconds(500))
        try await conn.write(.uartRX, request, withResponse: true)
        #expect(await tx.next() == response)
        await clock.advance(by: .seconds(1))
        sim.injectNotification(peripheral: probeA, characteristic: .probeStatus, bytes: [0xAA, 0xBB])
        #expect(await st.next() == [0xAA, 0xBB])
        sim.forceDisconnect(probeA)
        #expect(await disc.next() == .linkLost)
        rec.stop()

        // 2. Read back.
        let reader = try ReplayReader(directory: dir)
        let expected: [ReplayEvent] = [
            ReplayEvent(t: 0, type: .state, state: "poweredOn"),
            ReplayEvent(t: 0, type: .adv, peripheral: "PROBE-A", hex: HexString.encode(mfr), rssi: -61),
            ReplayEvent(t: 0, type: .connect, peripheral: "PROBE-A"),
            ReplayEvent(t: 0.5, type: .write, peripheral: "PROBE-A", char: uartRX, hex: HexString.encode(request)),
            ReplayEvent(t: 0.5, type: .notify, peripheral: "PROBE-A", char: uartTX, hex: HexString.encode(response)),
            ReplayEvent(t: 1.5, type: .notify, peripheral: "PROBE-A", char: status, hex: "AABB"),
            ReplayEvent(t: 1.5, type: .disconnect, peripheral: "PROBE-A"),
        ]
        #expect(reader.events == expected)
        #expect(reader.meta.name == "scripted")

        // 3. Replay into a fresh simulator and compare what the app sees.
        let clock2 = TestClock()
        let sim2 = SimulatedTransport(clock: clock2)
        await sim2.startScan()
        let conn2 = try await sim2.connect(probeA, timeout: .seconds(5))
        var advs2 = sim2.advertisements.makeAsyncIterator()
        var st2 = try await conn2.subscribe(.probeStatus).makeAsyncIterator()
        var tx2 = try await conn2.subscribe(.uartTX).makeAsyncIterator()
        var disc2 = conn2.disconnected.makeAsyncIterator()
        var states2 = sim2.state.makeAsyncIterator()
        #expect(await states2.next() == .poweredOn)
        sim2.startReplay(reader.events)
        await clock2.advance(by: .milliseconds(500))
        let adv2 = await advs2.next()
        #expect(adv2?.mfrData == mfr)
        #expect(adv2?.rssi == -61)
        // The app repeats its request at 0.5 s and gets the recorded response.
        try await conn2.write(.uartRX, request, withResponse: true)
        #expect(await tx2.next() == response)
        await clock2.advance(by: .seconds(1))
        #expect(await st2.next() == [0xAA, 0xBB])
        #expect(await disc2.next() == .linkLost)
        #expect(clock2.monotonic() == .milliseconds(1500))
    }

    @Test func recordingTransportForwardsErrorsAndRecordsAppClose() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        let rec = RecordingTransport(inner: sim, writer: try ReplayWriter(directory: dir), clock: clock)
        sim.refuseConnects(1)
        await #expect(throws: TransportError.connectionRefused(probeA)) { try await rec.connect(probeA, timeout: .seconds(1)) }
        let c = try await rec.connect(probeA, timeout: .seconds(1))
        await clock.advance(by: .seconds(3))
        await c.close()
        await c.close()  // idempotent
        rec.stop()
        let events = try ReplayReader(directory: dir).events.filter { $0.type != .state }
        #expect(events == [
            ReplayEvent(t: 0, type: .connect, peripheral: "PROBE-A"),
            ReplayEvent(t: 3, type: .disconnect, peripheral: "PROBE-A"),
        ])
    }
}
