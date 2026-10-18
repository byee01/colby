import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

private func probeAd(
    serial: UInt32 = 0x1000_5A3F, celsius: Double = 25, highPower: Bool = false, withPrefs: Bool = true
) -> ProbeAdvertisement {
    ProbeAdvertisement(
        serial: ProbeSerial(serial),
        temperatures: try! ProbeTemperatures(celsius: (0..<8).map { celsius + Double($0) }),
        mode: .normal, color: .yellow, probeNumber: 1, batteryLow: false,
        virtualSensors: try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8),
        overheating: [],
        preferences: withPrefs ? ThermometerPreferences(powerMode: .normal, highRadioPower: highPower) : nil)
}

private struct Rig {
    let clock = TestClock()
    let transport: SimulatedTransport
    let source: AdvertisementSource
    init() {
        transport = SimulatedTransport(clock: clock)
        source = AdvertisementSource(transport: transport)
    }
    func inject(_ packet: AdvertisementPacket, from peripheral: PeripheralId = "P", rssi: Int = -60) throws {
        transport.injectAdvertisement(peripheral: peripheral, mfrData: try encodeAdvertisement(packet), rssi: rssi)
    }
}

struct AdvertisementSourceTests {
    @Test func probeAdvertisementBecomesObservation() async throws {
        let rig = Rig()
        let obs = rig.source.observations
        await rig.source.start()
        let ad = probeAd(highPower: true)
        try rig.inject(.probe(ad), rssi: -71)
        let o = try #require(await firstValue(obs))
        #expect(o.serial == ad.serial)
        #expect(o.payload == .advertisement(ad))
        #expect(o.source.kind == .advertisement)
        #expect(o.source.via == nil)
        #expect(o.source.hopCount == nil)
        #expect(o.source.rssi == -71)
        #expect(o.source.highRadioPower == true)
        #expect(o.source.lastSeen == rig.clock.now())
        #expect(o.receivedAt == rig.clock.now())
        #expect(await rig.source.diagnostics.probePackets == 1)
    }

    @Test func missingPreferencesLeaveHighRadioPowerUnknown() async throws {
        let rig = Rig()
        let obs = rig.source.observations
        await rig.source.start()
        try rig.inject(.probe(probeAd(withPrefs: false)))
        #expect(try #require(await firstValue(obs)).source.highRadioPower == nil)
    }

    @Test func repeatedAdvertisementCarriesNodeAndHopCount() async throws {
        let rig = Rig()
        let obs = rig.source.observations
        let sightings = rig.source.nodeSightings
        await rig.source.start()
        // The node announces itself, then repeats a probe's data.
        try rig.inject(.node(NodeAdvertisement(productType: .display, serial: "DISP000123")), from: "NODE-A", rssi: -50)
        let s = try #require(await firstValue(sightings))
        #expect(s == NodeSighting(serial: "DISP000123", productType: .display, peripheral: "NODE-A",
                                  rssi: -50, time: rig.clock.now()))
        let ad = probeAd(withPrefs: false)
        try rig.inject(.repeated(ad, hopCount: 3), from: "NODE-A", rssi: -80)
        let o = try #require(await firstValue(obs))
        #expect(o.source.kind == .nodeAdvertisement)
        #expect(o.source.via == "DISP000123")
        #expect(o.source.hopCount == 3)
        #expect(o.source.rssi == -80)
        #expect(o.serial == ad.serial)
        #expect(await rig.source.nodeSerial(for: "NODE-A") == "DISP000123")
    }

    @Test func repeatedAdvertisementFromUnknownPeripheralHasNoVia() async throws {
        let rig = Rig()
        let obs = rig.source.observations
        await rig.source.start()
        try rig.inject(.node(NodeAdvertisement(productType: .booster, serial: "BOOST00001")), from: "NODE-A")
        try rig.inject(.repeated(probeAd(), hopCount: 1), from: "NODE-B")
        let o = try #require(await firstValue(obs))
        #expect(o.source.kind == .nodeAdvertisement)
        #expect(o.source.via == nil)
        #expect(o.source.hopCount == 1)
    }

    @Test func sameProbeViaAdvertisementAndNodeAreSeparatePaths() async throws {
        let rig = Rig()
        let obs = rig.source.observations
        await rig.source.start()
        try rig.inject(.node(NodeAdvertisement(productType: .display, serial: "DISP000123")), from: "NODE-A")
        let ad = probeAd()
        try rig.inject(.probe(ad), from: "PROBE")
        try rig.inject(.repeated(ad, hopCount: 2), from: "NODE-A")
        var it = obs.makeAsyncIterator()
        let direct = try #require(await it.next())
        let viaNode = try #require(await it.next())
        #expect(direct.source.pathKey != viaNode.source.pathKey)
        #expect(direct.serial == viaNode.serial)
    }

    @Test func garbageIsCountedNotThrown() async throws {
        let rig = Rig()
        let obs = rig.source.observations
        await rig.source.start()
        rig.transport.injectAdvertisement(peripheral: "X", mfrData: [])
        rig.transport.injectAdvertisement(peripheral: "X", mfrData: [0x4C, 0x00, 0x01, 0x02])  // other vendor
        rig.transport.injectAdvertisement(peripheral: "X", mfrData: [0xC7, 0x09, 0x01, 0x00])  // truncated probe
        rig.transport.injectAdvertisement(peripheral: "X", mfrData: [0xC7, 0x09, 0x7F, 0x00])  // unknown product
        try rig.inject(.probe(probeAd()))
        _ = await firstValue(obs)
        let d = await rig.source.diagnostics
        #expect(d.received == 5)
        #expect(d.codecErrors == 3)
        #expect(d.unknownPackets == 1)
        #expect(d.probePackets == 1)
    }

    @Test func fixtureAdvertisementDecodes() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/fixtures/advertisement/probe_normal.json")
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let hex = try #require(json["hex"] as? String)
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)!
        }
        let rig = Rig()
        let obs = rig.source.observations
        await rig.source.start()
        rig.transport.injectAdvertisement(peripheral: "FIX", mfrData: bytes, rssi: -40)
        let o = try #require(await firstValue(obs))
        #expect(o.serial.hex == "10005A3F")
        guard case .advertisement(let ad) = o.payload else { Issue.record("not an advertisement"); return }
        #expect(ad.temperatures.celsius.first == 22.5)
        #expect(o.source.highRadioPower == false)
    }

    @Test func stopHaltsDelivery() async throws {
        let rig = Rig()
        await rig.source.start()
        await rig.source.stop()
        try rig.inject(.probe(probeAd()))  // transport is not scanning, nothing is delivered
        await rig.clock.settle()
        #expect(await rig.source.diagnostics.received == 0)
    }
}
