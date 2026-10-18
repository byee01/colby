import Testing
@testable import CombustionCodec

/// Fixtures in uart_frames/: request encoding, response decoding, and framer streams.
@Suite("UART fixtures")
struct UartFixtureTests {
    @Test("encodeRequest", arguments: Fixtures.load("uart_frames", kind: "encodeRequest"))
    func encode(_ fixture: Fixture) throws {
        let variant = try Self.variant(fixture)
        let request = try Self.request(fixture.root["request"])
        let probe = fixture.root["probe"].string.flatMap { ProbeSerial(hex: $0) }
        let requestId = fixture.root["requestId"].uint32

        if !fixture.expectedError.isNull {
            do {
                _ = try encodeRequest(variant: variant, request, probe: probe, requestId: requestId)
                Issue.record("\(fixture.testDescription): expected an error")
            } catch let error as CodecError {
                #expect(firstDifference(expected: fixture.expectedError, actual: Render.error(error), subset: true) == nil, "\(fixture.testDescription): \(error)")
            }
            return
        }

        let bytes = try encodeRequest(variant: variant, request, probe: probe, requestId: requestId)
        #expect(Hex.string(bytes) == fixture.root["expectedHex"].string, "\(fixture.testDescription)")

        // And back: framer + decodeRequest recover the request.
        var framer = UartFramer(variant: variant, direction: .request)
        let outputs = framer.push(bytes)
        guard outputs.count == 1, case .frame(let frame) = outputs[0] else {
            Issue.record("\(fixture.testDescription): framer output \(outputs)")
            return
        }
        let decoded = try decodeRequest(frame)
        #expect(Self.sameRequest(decoded.request, Self.normalized(request)), "\(fixture.testDescription)")
        #expect(decoded.probe == (variant == .node ? probe : nil), "\(fixture.testDescription)")
        #expect(decoded.requestId == (variant == .node ? requestId : nil), "\(fixture.testDescription)")
    }

    @Test("decodeResponse", arguments: Fixtures.load("uart_frames", kind: "decodeResponse"))
    func decode(_ fixture: Fixture) throws {
        let variant = try Self.variant(fixture)
        var framer = UartFramer(variant: variant, direction: .response)
        let outputs = framer.push(fixture.hex)
        guard outputs.count == 1, case .frame(let frame) = outputs[0] else {
            Issue.record("\(fixture.testDescription): framer output \(outputs)")
            return
        }
        do {
            let response = try decodeResponse(frame)
            #expect(fixture.expectedError.isNull, "\(fixture.testDescription): expected an error")
            let difference = firstDifference(expected: fixture.expected, actual: Render.response(response))
            #expect(difference == nil, "\(fixture.testDescription): \(difference ?? "")")

            // Encoding the decoded response and decoding that again gives the same response.
            var again = UartFramer(variant: variant, direction: .response)
            let reencoded = again.push(try encodeResponse(response, variant: variant))
            guard reencoded.count == 1, case .frame(let reframe) = reencoded[0] else {
                Issue.record("\(fixture.testDescription): re-encoded frame not accepted")
                return
            }
            #expect(try decodeResponse(reframe) == response, "\(fixture.testDescription): re-encode round trip")
        } catch let error as CodecError {
            #expect(!fixture.expectedError.isNull, "\(fixture.testDescription): unexpected \(error)")
            #expect(firstDifference(expected: fixture.expectedError, actual: Render.error(error), subset: true) == nil, "\(fixture.testDescription): \(error)")
        }
    }

    @Test("framer streams", arguments: Fixtures.load("uart_frames", kind: "stream"))
    func stream(_ fixture: Fixture) throws {
        let variant = try Self.variant(fixture)
        let direction: UartDirection = fixture.root["direction"].string == "request" ? .request : .response
        var framer = UartFramer(variant: variant, direction: direction)
        var frames = [JSONValue]()
        var errors = [JSONValue]()
        for chunk in fixture.root["chunks"].array ?? [] {
            for output in framer.push(Hex.bytes(chunk.string ?? "")) {
                switch output {
                case .frame(let frame): frames.append(Render.frame(frame))
                case .error(let error): errors.append(Render.error(error)["kind"])
                }
            }
        }
        let expectedFrames = fixture.root["expectedFrames"]
        let expectedErrors = fixture.root["expectedErrors"]
        #expect(firstDifference(expected: expectedFrames, actual: .array(frames)) == nil, "\(fixture.testDescription) frames: \(firstDifference(expected: expectedFrames, actual: .array(frames)) ?? "")")
        #expect(firstDifference(expected: expectedErrors, actual: .array(errors)) == nil, "\(fixture.testDescription) errors: got \(errors)")

        // Every emitted frame re-encodes to bytes the framer accepts again.
        for case .frame(let frame) in UartFramer(variant: variant, direction: direction).pushAll(fixture.root["chunks"].array ?? []) {
            var again = UartFramer(variant: variant, direction: direction)
            #expect(again.push(try frame.encoded()) == [.frame(frame)], "\(fixture.testDescription): frame did not survive re-encoding")
        }
    }

    // MARK: JSON -> domain

    static func variant(_ fixture: Fixture) throws -> UartVariant {
        switch fixture.root["variant"].string {
        case "probe": return .probe
        case "node": return .node
        default: throw FixtureError(description: "\(fixture.testDescription): bad variant")
        }
    }

    static func request(_ json: JSONValue) throws -> UartRequest {
        switch json["type"].string {
        case "readSessionInfo": return .readSessionInfo
        case "readLogs": return .readLogs(start: json["start"].uint32!, end: json["end"].uint32!)
        case "setPrediction":
            let modes: [String: PredictionMode] = ["none": .none, "timeToRemoval": .timeToRemoval, "removalAndResting": .removalAndResting, "reserved": .reserved]
            return .setPrediction(setpoint: json["setpoint"].double!, mode: modes[json["mode"].string!]!)
        case "setAlarms": return .setAlarms(alarmConfig(json))
        case "silenceAlarms": return .silenceAlarms
        case "readProbeFirmware": return .readProbeFirmware
        case "readProbeHardware": return .readProbeHardware
        case "readProbeModel": return .readProbeModel
        default: throw FixtureError(description: "unknown request type \(json)")
        }
    }

    static func alarmConfig(_ json: JSONValue) -> AlarmConfig {
        func side(_ key: String) -> [AlarmChannel: Alarm] {
            var out = [AlarmChannel: Alarm]()
            for (name, value) in json[key].object ?? [:] {
                let channel = AlarmChannel.allCases.first { "\($0)" == name }!
                out[channel] = Alarm(isSet: value["set"].bool ?? false, temperature: value["temperature"].double!,
                                     tripped: value["tripped"].bool ?? false, alarming: value["alarming"].bool ?? false)
            }
            return out
        }
        return AlarmConfig(high: side("high"), low: side("low"))
    }

    /// Equality with a tolerance on alarm temperatures (0.1 steps are not exact in binary floating point).
    static func sameRequest(_ a: UartRequest, _ b: UartRequest) -> Bool {
        if case .setAlarms(let x) = a, case .setAlarms(let y) = b {
            return firstDifference(expected: Render.alarms(y), actual: Render.alarms(x)) == nil
        }
        return a == b
    }

    /// What decoding should return for a request: missing alarm channels come back as `Alarm.unset`.
    static func normalized(_ request: UartRequest) -> UartRequest {
        guard case .setAlarms(let config) = request else { return request }
        func fill(_ d: [AlarmChannel: Alarm]) -> [AlarmChannel: Alarm] {
            Dictionary(uniqueKeysWithValues: AlarmChannel.allCases.map { ($0, d[$0] ?? .unset) })
        }
        return .setAlarms(AlarmConfig(high: fill(config.high), low: fill(config.low)))
    }
}

extension UartFramer {
    /// Test helper: pushes every chunk and returns all outputs.
    func pushAll(_ chunks: [JSONValue]) -> [UartFramerOutput] {
        var copy = self
        return chunks.flatMap { copy.push(Hex.bytes($0.string ?? "")) }
    }
}
