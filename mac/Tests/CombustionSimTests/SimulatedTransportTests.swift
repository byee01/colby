import CombustionCore
import CombustionSim
import Foundation
import Testing

struct SimulatedTransportTests {
    private func make() -> (TestClock, SimulatedTransport) {
        let clock = TestClock()
        return (clock, SimulatedTransport(clock: clock))
    }

    @Test func stateStreamStartsWithCurrentAndFollowsChanges() async {
        let (_, sim) = make()
        var it = sim.state.makeAsyncIterator()
        #expect(await it.next() == .poweredOn)
        sim.setState(.poweredOff)
        #expect(await it.next() == .poweredOff)
        var late = sim.state.makeAsyncIterator()
        #expect(await late.next() == .poweredOff)
    }

    @Test func advertisementsOnlyWhileScanning() async {
        let (clock, sim) = make()
        var it = sim.advertisements.makeAsyncIterator()
        sim.injectAdvertisement(peripheral: probeA, mfrData: [1])  // not scanning: dropped
        await sim.startScan()
        await clock.advance(by: .seconds(2))
        sim.injectAdvertisement(peripheral: probeA, mfrData: mfr, rssi: -70)
        let adv = await it.next()
        #expect(adv?.mfrData == mfr)
        #expect(adv?.rssi == -70)
        #expect(adv?.time == clock.now())
        await sim.stopScan()
        sim.injectAdvertisement(peripheral: probeA, mfrData: [2])
        sim.setState(.poweredOff)  // finishes nothing, but proves the stream has no stray element
        #expect(sim.writes.isEmpty)
    }

    @Test func connectDiscoverReadAndMTU() async throws {
        let (_, sim) = make()
        sim.setMTU(247)
        sim.setReadValue(Array("1.2.3".utf8), characteristic: .firmwareRevision, peripheral: probeA)
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        #expect(c.mtu == 247)
        #expect(c.peripheral == probeA)
        let services = try await c.discover()
        #expect(services.map(\.uuid).contains(.uartService))
        #expect(try await c.read(.firmwareRevision) == Array("1.2.3".utf8))
        await #expect(throws: TransportError.characteristicNotFound(.modelNumber)) { try await c.read(.modelNumber) }
    }

    @Test func secondConnectionToSamePeripheralIsRejected() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        await #expect(throws: TransportError.alreadyConnected(probeA)) { try await sim.connect(probeA, timeout: .seconds(5)) }
        await c.close()
        _ = try await sim.connect(probeA, timeout: .seconds(5))
    }

    @Test func injectedNotificationReachesOnlySubscribers() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var status = try await c.subscribe(.probeStatus).makeAsyncIterator()
        sim.injectNotification(peripheral: probeA, characteristic: .uartTX, bytes: [9])  // nobody subscribed
        sim.injectNotification(peripheral: "other", characteristic: .probeStatus, bytes: [8])
        sim.injectNotification(peripheral: probeA, characteristic: .probeStatus, bytes: [1, 2])
        #expect(await status.next() == [1, 2])
    }

    @Test func responderAnswersWritesOnReplyCharacteristic() async throws {
        let (_, sim) = make()
        sim.addResponder { write in [frame(type: write[4] | 0x80), frame(type: 0x7F)] }
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var tx = try await c.subscribe(.uartTX).makeAsyncIterator()
        try await c.write(.uartRX, frame(type: 0x04), withResponse: true)
        #expect(await tx.next() == frame(type: 0x84))
        #expect(await tx.next() == frame(type: 0x7F))
        #expect(sim.writes == [SimulatedWrite(peripheral: probeA, characteristic: .uartRX, bytes: frame(type: 0x04))])
    }

    @Test func dropAndDuplicateFaults() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var it = try await c.subscribe(.probeStatus).makeAsyncIterator()
        sim.dropNextNotifications(1)
        sim.injectNotification(peripheral: probeA, characteristic: .probeStatus, bytes: [1])
        sim.duplicateNextNotifications(1, on: .probeStatus)
        sim.injectNotification(peripheral: probeA, characteristic: .probeStatus, bytes: [2])
        sim.injectNotification(peripheral: probeA, characteristic: .probeStatus, bytes: [3])
        #expect(await it.next() == [2])
        #expect(await it.next() == [2])
        #expect(await it.next() == [3])
    }

    @Test func faultOnOtherCharacteristicIsNotConsumed() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var it = try await c.subscribe(.probeStatus).makeAsyncIterator()
        sim.dropNextNotifications(1, on: .uartTX)
        sim.injectNotification(peripheral: probeA, characteristic: .probeStatus, bytes: [1])
        #expect(await it.next() == [1])
    }

    @Test func delayedResponsesArriveOnlyAfterClockAdvances() async throws {
        let (clock, sim) = make()
        sim.addResponder { _ in [[0xAA]] }
        sim.setResponseDelay(.milliseconds(300))
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var tx = try await c.subscribe(.uartTX).makeAsyncIterator()
        try await c.write(.uartRX, frame(type: 1), withResponse: true)
        await clock.advance(by: .milliseconds(299))
        sim.injectNotification(peripheral: probeA, characteristic: .uartTX, bytes: [0x01])  // marker
        #expect(await tx.next() == [0x01])
        await clock.advance(by: .milliseconds(1))
        #expect(await tx.next() == [0xAA])
    }

    @Test func refuseConnectThenAllow() async throws {
        let (_, sim) = make()
        sim.refuseConnects(2)
        await #expect(throws: TransportError.connectionRefused(probeA)) { try await sim.connect(probeA, timeout: .seconds(1)) }
        await #expect(throws: TransportError.connectionRefused(probeA)) { try await sim.connect(probeA, timeout: .seconds(1)) }
        _ = try await sim.connect(probeA, timeout: .seconds(1))
        sim.forceDisconnect(probeA)
        sim.refuseConnects(1, error: .operationFailed("slots full"))
        await #expect(throws: TransportError.operationFailed("slots full")) { try await sim.connect(probeA, timeout: .seconds(1)) }
    }

    @Test func connectDelayLongerThanTimeoutThrowsTimeout() async throws {
        let (clock, sim) = make()
        sim.setConnectDelay(.seconds(10))
        let attempt = Task { () -> TransportError? in
            do { _ = try await sim.connect(probeA, timeout: .seconds(4)); return nil } catch { return error as? TransportError }
        }
        await clock.advance(by: .seconds(4))
        #expect(await attempt.value == .timeout)

        sim.setConnectDelay(.seconds(2))
        let ok = Task { try await sim.connect(probeA, timeout: .seconds(4)) }
        await clock.advance(by: .seconds(2))
        _ = try await ok.value
    }

    @Test func forceDisconnectEndsStreamsAndFailsFurtherIO() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var sub = try await c.subscribe(.probeStatus).makeAsyncIterator()
        var disc = c.disconnected.makeAsyncIterator()
        sim.forceDisconnect(probeA, reason: .timeout)
        #expect(await disc.next() == .timeout)
        #expect(await disc.next() == nil)
        #expect(await sub.next() == nil)
        await #expect(throws: TransportError.disconnected) { try await c.write(.uartRX, [1], withResponse: false) }
        // Late observers still learn the reason.
        var late = c.disconnected.makeAsyncIterator()
        #expect(await late.next() == .timeout)
    }

    @Test func closeReportsRequested() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var disc = c.disconnected.makeAsyncIterator()
        await c.close()
        #expect(await disc.next() == .requested)
    }

    @Test func bluetoothOffDropsConnectionsAndBlocksConnect() async throws {
        let (_, sim) = make()
        let c = try await sim.connect(probeA, timeout: .seconds(5))
        var disc = c.disconnected.makeAsyncIterator()
        sim.setState(.poweredOff)
        #expect(await disc.next() == .bluetoothOff)
        await #expect(throws: TransportError.notPoweredOn(.poweredOff)) { try await sim.connect(probeA, timeout: .seconds(1)) }
        sim.setState(.poweredOn)
        _ = try await sim.connect(probeA, timeout: .seconds(1))
    }
}

struct SimulatedTransportConnectAndFaultTests {
    @Test func blockedConnectsAreRefusedUntilAllowed() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        sim.blockConnects(to: probeA)
        await #expect(throws: TransportError.connectionRefused(probeA)) {
            _ = try await sim.connect(probeA, timeout: .seconds(1))
        }
        #expect(!sim.isConnected(probeA))
        sim.allowConnects(to: probeA)
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        #expect(sim.isConnected(probeA))
        await c.close()
        #expect(!sim.isConnected(probeA))
    }

    @Test func dropCanSkipNotificationsFirst() async throws {
        let clock = TestClock()
        let sim = SimulatedTransport(clock: clock)
        let c = try await sim.connect(probeA, timeout: .seconds(1))
        var it = try await c.subscribe(.uartTX).makeAsyncIterator()
        sim.dropNextNotifications(2, after: 3, on: .uartTX)
        for i in 0..<8 { sim.injectNotification(peripheral: probeA, characteristic: .uartTX, bytes: [UInt8(i)]) }
        var got: [UInt8] = []
        for _ in 0..<6 { if let b = await it.next() { got += b } }
        #expect(got == [0, 1, 2, 5, 6, 7])
    }
}
