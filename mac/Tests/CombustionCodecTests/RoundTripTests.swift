import Testing
@testable import CombustionCodec

/// encode then decode returns the original, for random valid values from many seeds.
@Suite("Round trips")
struct RoundTripTests {
    static let seeds = Array(UInt64(1)...UInt64(30))
    static let iterations = 60

    @Test("temperatures", arguments: seeds)
    func temperatures(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let t = Gen.temperatures(&rng)
            #expect(ProbeTemperatures(packed: t.packed()) == t)
            #expect(try ProbeTemperatures(celsius: t.celsius) == t)
        }
    }

    @Test("virtual sensors", arguments: seeds)
    func virtualSensors(seed: UInt64) {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let v = Gen.virtualSensors(&rng)
            #expect(VirtualSensors(bits: v.bits) == v)
        }
    }

    @Test("prediction status and log", arguments: seeds)
    func prediction(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let p = Gen.prediction(&rng)
            #expect(PredictionStatus(packed: try p.packed()) == p)
            let l = Gen.predictionLog(&rng)
            #expect(PredictionLog(packed: try l.packed()) == l)
        }
    }

    @Test("alarms", arguments: seeds)
    func alarms(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let a = Gen.alarms(&rng)
            let bytes = try a.packed()
            #expect(bytes.count == 44)
            #expect(AlarmConfig(packed: bytes) == a)
        }
    }

    @Test("food safe", arguments: seeds)
    func foodSafe(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let f = Gen.foodSafe(&rng)
            let packed = try f.packed()
            #expect(FoodSafe(data: packed.data, status: packed.status) == f)
        }
    }

    @Test("probe status, both layouts", arguments: seeds)
    func probeStatus(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            var status = Gen.status(&rng)
            let current = try encodeProbeStatus(status)
            #expect(current.count == 100)
            #expect(try decodeProbeStatus(current) == status)

            let legacy = try encodeProbeStatus(status, layout: .legacy)
            #expect(legacy.count == 94)
            status.session = nil
            #expect(try decodeProbeStatus(legacy) == status)
        }
    }

    @Test("node probe status, both layouts", arguments: seeds)
    func nodeStatus(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            var node = NodeProbeStatus(serial: Gen.serial(&rng), status: Gen.status(&rng), hopCount: .random(in: 1...4, using: &rng))
            let current = try encodeNodeProbeStatus(node)
            #expect(current.count == 105)
            #expect(try decodeNodeProbeStatus(current) == node)

            let legacy = try encodeNodeProbeStatus(node, layout: .legacy)
            #expect(legacy.count == 99)
            node.status.session = nil
            #expect(try decodeNodeProbeStatus(legacy) == node)
        }
    }

    @Test("advertisements", arguments: seeds)
    func advertisements(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let probe = AdvertisementPacket.probe(Gen.probeAdvertisement(&rng, withPreferences: true))
            #expect(try decodeAdvertisement(encodeAdvertisement(probe)) == probe)

            let hops = Int.random(in: 1...4, using: &rng)
            let repeated = AdvertisementPacket.repeated(Gen.probeAdvertisement(&rng, withPreferences: false), hopCount: hops)
            let bytes = try encodeAdvertisement(repeated)
            #expect(bytes.count == 24)
            #expect(try decodeAdvertisement(bytes) == repeated)

            let withPrefs = AdvertisementPacket.repeated(Gen.probeAdvertisement(&rng, withPreferences: true), hopCount: hops)
            #expect(try decodeAdvertisement(encodeAdvertisement(withPrefs)) == withPrefs)

            let type = [NodeProductType.display, .booster].randomElement(using: &rng)!
            let node = AdvertisementPacket.node(NodeAdvertisement(
                productType: type, serial: Gen.text(&rng, maxLength: 10).uppercased(), preferences: UInt8.random(in: 1...255, using: &rng)))
            #expect(try decodeAdvertisement(encodeAdvertisement(node)) == node)
        }
    }

    @Test("requests", arguments: seeds)
    func requests(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let node = Bool.random(using: &rng)
            let request = Gen.request(&rng, node: node)
            let probe = Gen.serial(&rng)
            let requestId = UInt32.random(in: 0...UInt32.max, using: &rng)
            let variant: UartVariant = node ? .node : .probe

            var framer = UartFramer(variant: variant, direction: .request)
            let bytes = try encodeRequest(variant: variant, request, probe: probe, requestId: requestId)
            guard case .frame(let frame)? = framer.push(bytes).first else {
                Issue.record("no frame for \(request)")
                continue
            }
            let decoded = try decodeRequest(frame)
            #expect(decoded.request == request)
            #expect(decoded.probe == (node ? probe : nil))
            #expect(decoded.requestId == (node ? requestId : nil))
            #expect(frame.messageType == request.messageType)
        }
    }

    @Test("responses", arguments: seeds)
    func responses(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        for _ in 0..<Self.iterations {
            let node = Bool.random(using: &rng)
            let response = Gen.response(&rng, node: node)
            let variant: UartVariant = node ? .node : .probe
            var framer = UartFramer(variant: variant)
            guard case .frame(let frame)? = framer.push(try encodeResponse(response, variant: variant)).first else {
                Issue.record("no frame for \(response)")
                continue
            }
            #expect(try decodeResponse(frame) == response)
        }
    }

    @Test("ProbeSerial hex")
    func serialHex() {
        #expect(ProbeSerial(0x2A).hex == "0000002A")
        #expect(ProbeSerial(hex: "2a") == ProbeSerial(0x2A))
        #expect(ProbeSerial(hex: "FFFFFFFF")?.rawValue == .max)
        #expect(ProbeSerial(hex: "") == nil)
        #expect(ProbeSerial(hex: "123456789") == nil)
        #expect(ProbeSerial(hex: "XYZ") == nil)
        #expect(ProbeSerial(1) < ProbeSerial(2))
        #expect("\(ProbeSerial(0xABC))" == "00000ABC")
    }
}
