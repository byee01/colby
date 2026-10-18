import Testing
@testable import CombustionCodec

/// Validation errors, reserved values and the small helpers: the branches fixtures do not reach.
@Suite("Edge cases")
struct EdgeCaseTests {
    // MARK: CRC and bits

    @Test("CRC-16/CCITT-FALSE check value")
    func crcCheckValue() {
        #expect(crc16Ccitt(Array("123456789".utf8)) == 0x29B1)
        #expect(crc16Ccitt([UInt8]()) == 0xFFFF)
    }

    @Test("bit reader and writer are LSB first")
    func bits() {
        var writer = BitWriter(byteCount: 2)
        writer.write(0b101, bits: 3)
        writer.write(0x1FF, bits: 9)
        #expect(writer.bytes == [0b1111_1101, 0b0000_1111])
        var reader = BitReader(writer.bytes)
        #expect(reader.read(3) == 0b101)
        #expect(reader.read(9) == 0x1FF)
    }

    // MARK: Temperatures and sensors

    @Test("temperature validation")
    func temperatureValidation() throws {
        #expect(throws: CodecError.self) { try ProbeTemperatures(raw: [0, 1]) }
        #expect(throws: CodecError.self) { try ProbeTemperatures(raw: [UInt16](repeating: 0x2000, count: 8)) }
        #expect(throws: CodecError.self) { try ProbeTemperatures(celsius: [Double](repeating: -20.1, count: 8)) }
        #expect(throws: CodecError.self) { try ProbeTemperatures(celsius: [Double](repeating: 390, count: 8)) }
        #expect(throws: CodecError.self) { try ProbeTemperatures(celsius: [Double](repeating: .nan, count: 8)) }
        let t = try ProbeTemperatures(celsius: [-20, 369, 22.5, 22.52, 0, 1, 2, 3])
        #expect(t.raw[0] == 0)
        #expect(t.raw[1] == 7780)
        #expect(t.raw[3] == 850)
        #expect(abs(t[.t2] - 369) < 1e-9)
        #expect(t.celsius.count == 8)
    }

    @Test("virtual sensor validation and temperatures")
    func virtualSensors() throws {
        #expect(throws: CodecError.self) { try VirtualSensors(core: .t7, surface: .t4, ambient: .t8) }
        #expect(throws: CodecError.self) { try VirtualSensors(core: .t1, surface: .t3, ambient: .t8) }
        #expect(throws: CodecError.self) { try VirtualSensors(core: .t1, surface: .t8, ambient: .t8) }
        #expect(throws: CodecError.self) { try VirtualSensors(core: .t1, surface: .t4, ambient: .t4) }
        let v = try VirtualSensors(core: .t6, surface: .t7, ambient: .t8)
        let t = try ProbeTemperatures(raw: [100, 200, 300, 400, 500, 600, 700, 800])
        let picked = v.temperatures(from: t)
        #expect(picked.core == t[.t6])
        #expect(picked.surface == t[.t7])
        #expect(picked.ambient == t[.t8])
        // Undefined core values 6 and 7 read as T1.
        #expect(VirtualSensors(bits: 6).core == .t1)
        #expect(VirtualSensors(bits: 7).core == .t1)
    }

    @Test("overheat mask: bit n is T(n+1)")
    func overheat() {
        #expect(OverheatMask.decode(0b0000_0101) == [.t1, .t3])
        #expect(OverheatMask.encode([.t8, .t2]) == 0b1000_0010)
    }

    // MARK: Identifiers

    @Test("mode/ID byte")
    func modeAndId() throws {
        let ident = ModeAndId(byte: 0b101_110_01)
        #expect(ident.mode == .instantRead)
        #expect(ident.color == .unknown(6))
        #expect(ident.probeNumber == 6)
        #expect(try ident.byte() == 0b101_110_01)
        #expect(throws: CodecError.self) { try ModeAndId(mode: .normal, color: .yellow, probeNumber: 0).byte() }
        #expect(throws: CodecError.self) { try ModeAndId(mode: .normal, color: .yellow, probeNumber: 9).byte() }
        #expect(throws: CodecError.self) { try ModeAndId(mode: .normal, color: .unknown(8), probeNumber: 1).byte() }
        #expect(ProbeColor(raw: 0) == .yellow && ProbeColor(raw: 1) == .grey)
        #expect(ProbeColor.grey.raw == 1 && ProbeColor.yellow.raw == 0 && ProbeColor.unknown(5).raw == 5)
    }

    @Test("thermometer preferences byte")
    func preferences() {
        for byte in UInt8(0)...7 {
            #expect(ThermometerPreferences(byte: byte).byte == byte)
        }
        #expect(ThermometerPreferences(byte: 0xF8).byte == 0)
        let made = ThermometerPreferences(powerMode: .alwaysOn, highRadioPower: true)
        #expect(made.byte == 5)
        #expect(ThermometerPreferences(powerMode: .reserved(2), highRadioPower: false).byte == 2)
    }

    // MARK: Prediction

    @Test("prediction percent to removal")
    func percent() {
        var p = PredictionStatus(state: .predicting, mode: .timeToRemoval, type: .removal, setpoint: 60, heatStart: 20,
                                 rawSecondsRemaining: 100, estimatedCore: 40)
        #expect(p.percentToRemoval == 50)
        p.estimatedCore = 10
        #expect(p.percentToRemoval == 0)
        p.estimatedCore = 70
        #expect(p.percentToRemoval == 100)
        p.heatStart = 60
        #expect(p.percentToRemoval == nil)
    }

    @Test("prediction encode validation")
    func predictionValidation() {
        var p = PredictionStatus(state: .predicting, mode: .none, type: .none, setpoint: 60, heatStart: 20, rawSecondsRemaining: 0, estimatedCore: 20)
        #expect(throws: Never.self) { try p.packed() }
        p.setpoint = 102.4
        #expect(throws: CodecError.self) { try p.packed() }
        p.setpoint = 60; p.heatStart = -1
        #expect(throws: CodecError.self) { try p.packed() }
        p.heatStart = 20; p.rawSecondsRemaining = 0x20000
        #expect(throws: CodecError.self) { try p.packed() }
        p.rawSecondsRemaining = 0; p.estimatedCore = 185
        #expect(throws: CodecError.self) { try p.packed() }

        let sensors = try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8)
        var log = PredictionLog(virtualSensors: sensors, state: .unknown, mode: .reserved, type: .reserved, setpoint: 1, rawSecondsRemaining: 1, estimatedCore: 1)
        #expect(throws: Never.self) { try log.packed() }
        log.rawSecondsRemaining = 0x20000
        #expect(throws: CodecError.self) { try log.packed() }
    }

    @Test("reserved prediction states read as unknown")
    func reservedStates() {
        for raw in UInt32(5)...15 { #expect(PredictionState(raw: raw) == .unknown) }
        #expect(PredictionState.unknown.raw == 15)
        #expect(maxPredictionSetpoint == 102.3)
    }

    @Test("set prediction data")
    func setPredictionData() throws {
        #expect(try encodeSetPredictionData(setpoint: 102.3, mode: .removalAndResting) == 1023 | 2 << 10)
        #expect(throws: CodecError.self) { try encodeSetPredictionData(setpoint: 60, mode: .reserved) }
        #expect(throws: CodecError.self) { try encodeSetPredictionData(setpoint: 102.4, mode: .none) }
        #expect(throws: CodecError.self) { try encodeSetPredictionData(setpoint: -1, mode: .none) }
        let decoded = decodeSetPredictionData(650 | 1 << 10)
        #expect(decoded.setpoint == 65 && decoded.mode == .timeToRemoval)
    }

    // MARK: Alarms, food safe, session

    @Test("alarm validation")
    func alarmValidation() throws {
        #expect(throws: CodecError.self) { try AlarmConfig(high: [.core: Alarm(isSet: true, temperature: 799.5)]).packed() }
        #expect(throws: CodecError.self) { try AlarmConfig(low: [.t1: Alarm(isSet: true, temperature: -20.5)]).packed() }
        #expect(throws: CodecError.self) { try AlarmConfig(low: [.t1: Alarm(isSet: true, temperature: .nan)]).packed() }
        let bytes = try AlarmConfig(high: [.t1: Alarm(isSet: true, temperature: 799)]).packed()
        #expect(bytes.count == 44)
        #expect(bytes.u16(at: 0) == 8190 << 3 | 1)
        // Missing channels are sent as unset at -20 C.
        #expect(bytes.u16(at: 2) == 0)
        #expect(Alarm.unset == Alarm(isSet: false, temperature: -20, tripped: false, alarming: false))
    }

    @Test("food safe validation and reserved values")
    func foodSafeValidation() throws {
        var f = FoodSafe(mode: .integrated, product: 1023, serving: .cookedAndChilled, thresholdTemp: 409.55, zValue: 0, referenceTemp: 1, dValue: 2,
                         targetLogReduction: 25.5, state: .safe, logReduction: 25.5, secondsAboveThreshold: 1, logSequence: 2)
        #expect(throws: Never.self) { try f.packed() }
        f.product = 1024
        #expect(throws: CodecError.self) { try f.packed() }
        f.product = 1; f.thresholdTemp = 409.6
        #expect(throws: CodecError.self) { try f.packed() }
        f.thresholdTemp = 1; f.targetLogReduction = 25.6
        #expect(throws: CodecError.self) { try f.packed() }
        f.targetLogReduction = 1; f.logReduction = 26
        #expect(throws: CodecError.self) { try f.packed() }
        f.logReduction = 1; f.state = .safetyImpossible; f.mode = .simplified
        let packed = try f.packed()
        // Simplified mode drops integrated values on decode.
        let back = FoodSafe(data: packed.data, status: packed.status)
        #expect(back?.thresholdTemp == nil && back?.state == .safetyImpossible)
        #expect(FoodSafe(data: [UInt8](repeating: 0, count: 10), status: [UInt8](repeating: 0, count: 8)) != nil)
        #expect(SessionInfo(sessionId: 0, samplePeriodMs: 1).isSupplied == false)
        #expect(SessionInfo(sessionId: 1, samplePeriodMs: 1).isSupplied)
    }

    // MARK: Status and advertisement encoders

    @Test("status encode needs every optional part")
    func statusEncodeMissingParts() throws {
        var rng = SeededRNG(seed: 7)
        let full = Gen.status(&rng)
        for keyPath in [\ProbeStatusPayload.foodSafe, \.overheating, \.preferences, \.alarms] as [PartialKeyPath<ProbeStatusPayload>] {
            var partial = full
            switch keyPath {
            case \ProbeStatusPayload.foodSafe: partial.foodSafe = nil
            case \ProbeStatusPayload.overheating: partial.overheating = nil
            case \ProbeStatusPayload.preferences: partial.preferences = nil
            default: partial.alarms = nil
            }
            #expect(throws: CodecError.self) { try encodeProbeStatus(partial) }
        }
        var badProbe = full
        badProbe.probeNumber = 0
        #expect(throws: CodecError.self) { try encodeProbeStatus(badProbe) }
        #expect(throws: CodecError.self) { try encodeNodeProbeStatus(NodeProbeStatus(serial: ProbeSerial(1), status: full, hopCount: 0)) }
        #expect(throws: CodecError.self) { try encodeNodeProbeStatus(NodeProbeStatus(serial: ProbeSerial(1), status: full, hopCount: 5)) }
    }

    @Test("advertisement encoder edge cases")
    func advertisementEncoder() throws {
        #expect(try encodeAdvertisement(.unknown(productType: 9)) == [0xC7, 0x09, 9])
        #expect(try decodeAdvertisement([0xC7, 0x09, 9]) == .unknown(productType: 9))
        #expect(throws: CodecError.self) { try encodeAdvertisement(.node(NodeAdvertisement(productType: .display, serial: "ELEVENCHARS"))) }
        var rng = SeededRNG(seed: 3)
        let probe = Gen.probeAdvertisement(&rng, withPreferences: false)
        #expect(throws: CodecError.self) { try encodeAdvertisement(.repeated(probe, hopCount: 0)) }
        var bad = probe
        bad.probeNumber = 9
        #expect(throws: CodecError.self) { try encodeAdvertisement(.probe(bad)) }
        // A probe without overheating or preferences encodes to 23 bytes and decodes the same.
        bad = probe; bad.overheating = nil
        let short = try encodeAdvertisement(.probe(bad))
        #expect(short.count == 23)
        #expect(try decodeAdvertisement(short) == .probe(bad))
        // Preferences without overheating: overheating is written as zero.
        var onlyPrefs = probe
        onlyPrefs.overheating = nil
        onlyPrefs.preferences = ThermometerPreferences(powerMode: .alwaysOn, highRadioPower: false)
        let decoded = try decodeAdvertisement(encodeAdvertisement(.probe(onlyPrefs)))
        guard case .probe(let p) = decoded else { Issue.record("not a probe"); return }
        #expect(p.overheating == [] && p.preferences == onlyPrefs.preferences)
    }

    // MARK: UART encoders and decoders

    @Test("frame encoding validation")
    func frameValidation() {
        #expect(throws: CodecError.self) { try UartFrame(variant: .probe, direction: .response, messageType: 1, success: true, payload: [UInt8](repeating: 0, count: 256)).encoded() }
        #expect(throws: CodecError.self) { try UartFrame(variant: .probe, direction: .request, messageType: 0x80).encoded() }
        #expect(throws: CodecError.self) { try UartFrame(variant: .probe, direction: .response, messageType: 1).encoded() }
        #expect(throws: CodecError.self) { try UartFrame(variant: .node, direction: .request, messageType: 1).encoded() }
        #expect(throws: CodecError.self) { try UartFrame(variant: .node, direction: .response, messageType: 1, requestId: 1, success: true).encoded() }
    }

    @Test("request encoding validation")
    func requestValidation() {
        #expect(throws: CodecError.missingField("probe")) { try encodeRequest(variant: .node, .readSessionInfo, requestId: 1) }
        #expect(throws: CodecError.missingField("requestId")) { try encodeRequest(variant: .node, .readSessionInfo, probe: ProbeSerial(1)) }
        #expect(throws: CodecError.unknownMessageType(0x47)) { try encodeRequest(variant: .probe, .readProbeHardware) }
        #expect(throws: CodecError.unknownMessageType(0x48)) { try encodeRequest(variant: .probe, .readProbeModel) }
        #expect(throws: CodecError.self) { try encodeRequest(variant: .probe, .setPrediction(setpoint: 103, mode: .none)) }
    }

    @Test("decodeRequest rejects what it cannot read")
    func decodeRequestErrors() throws {
        func frame(_ variant: UartVariant, _ type: UInt8, _ payload: [UInt8], direction: UartDirection = .request) -> UartFrame {
            UartFrame(variant: variant, direction: direction, messageType: type, requestId: variant == .node ? 1 : nil, payload: payload)
        }
        #expect(throws: CodecError.unknownMessageType(3)) { try decodeRequest(frame(.probe, 3, [], direction: .response)) }
        #expect(throws: CodecError.unknownMessageType(0x45)) { try decodeRequest(frame(.node, 0x45, [])) }
        #expect(throws: CodecError.unknownMessageType(0x46)) { try decodeRequest(frame(.probe, 0x46, [])) }
        #expect(throws: CodecError.unknownMessageType(0x47)) { try decodeRequest(frame(.probe, 0x47, [])) }
        #expect(throws: CodecError.unknownMessageType(0x48)) { try decodeRequest(frame(.probe, 0x48, [])) }
        #expect(throws: CodecError.tooShort(expected: 4, actual: 0)) { try decodeRequest(frame(.node, 3, [])) }
        #expect(throws: CodecError.tooShort(expected: 12, actual: 4)) { try decodeRequest(frame(.node, 4, [0, 0, 0, 0])) }
        #expect(throws: CodecError.tooShort(expected: 2, actual: 1)) { try decodeRequest(frame(.probe, 5, [0])) }
        #expect(throws: CodecError.tooShort(expected: 44, actual: 3)) { try decodeRequest(frame(.probe, 0x0B, [0, 0, 0])) }
        #expect(throws: CodecError.tooShort(expected: 16, actual: 2)) { try decodeRequest(frame(.node, 0x0C, [0, 1])) }
        #expect(throws: CodecError.tooShort(expected: 4, actual: 0)) { try decodeRequest(frame(.node, 0x46, [])) }
        #expect(throws: CodecError.tooShort(expected: 4, actual: 0)) { try decodeRequest(frame(.node, 0x47, [])) }
        #expect(throws: CodecError.tooShort(expected: 4, actual: 0)) { try decodeRequest(frame(.node, 0x48, [])) }

        // Global silence (flag 1) names no probe.
        let global = frame(.node, 0x0C, [1, 1] + [UInt8](repeating: 0, count: 14))
        #expect(try decodeRequest(global).probe == nil)
        let targeted = frame(.node, 0x0C, [0, 1, 0x3F, 0x5A, 0, 0x10] + [UInt8](repeating: 0, count: 10))
        #expect(try decodeRequest(targeted).probe == ProbeSerial(0x10005A3F))
    }

    @Test("decodeResponse rejects what it cannot read")
    func decodeResponseErrors() {
        #expect(throws: CodecError.unknownMessageType(3)) {
            try decodeResponse(UartFrame(variant: .probe, direction: .request, messageType: 3))
        }
        // A frame built by hand without a success flag counts as failed.
        let noFlag = UartFrame(variant: .probe, direction: .response, messageType: 5)
        #expect(throws: Never.self) { try decodeResponse(noFlag) }
        #expect((try? decodeResponse(noFlag))?.success == false)
    }

    @Test("response encoding validation")
    func responseEncoding() {
        let node = UartResponse(messageType: 3, success: true, requestId: 1, responseId: 2, body: .sessionInfo(probe: nil, SessionInfo(sessionId: 1, samplePeriodMs: 1)))
        #expect(throws: CodecError.missingField("probe")) { try encodeResponse(node, variant: .node) }
        let long = UartResponse(messageType: 0x46, success: true, requestId: 1, responseId: 2,
                                body: .revision(probe: ProbeSerial(1), kind: .firmware, text: String(repeating: "x", count: 21)))
        #expect(throws: CodecError.self) { try encodeResponse(long, variant: .node) }
        let noIds = UartResponse(messageType: 5, success: true, body: .ack)
        #expect(throws: CodecError.missingField("requestId")) { try encodeResponse(noIds, variant: .node) }
    }

    @Test("message type constants")
    func messageTypes() {
        #expect(UartRequest.readSessionInfo.messageType == 0x03)
        #expect(UartRequest.readLogs(start: 0, end: 0).messageType == 0x04)
        #expect(UartRequest.setPrediction(setpoint: 0, mode: .none).messageType == 0x05)
        #expect(UartRequest.setAlarms(AlarmConfig()).messageType == 0x0B)
        #expect(UartRequest.silenceAlarms.messageType == 0x0C)
        #expect(UartRequest.readProbeFirmware.messageType == 0x46)
        #expect(UartRequest.readProbeHardware.messageType == 0x47)
        #expect(UartRequest.readProbeModel.messageType == 0x48)
        #expect(UartMessageType.probeStatus == 0x45)
    }

    @Test("node 0x45 frames carry a decodable status")
    func nodeStatusFrame() throws {
        var rng = SeededRNG(seed: 11)
        let node = NodeProbeStatus(serial: Gen.serial(&rng), status: Gen.status(&rng), hopCount: 3)
        let frame = UartFrame(variant: .node, direction: .request, messageType: UartMessageType.probeStatus, requestId: 9, payload: try encodeNodeProbeStatus(node))
        var framer = UartFramer(variant: .node)
        guard case .frame(let received)? = framer.push(try frame.encoded()).first else { Issue.record("no frame"); return }
        #expect(received.direction == .request && received.messageType == 0x45)
        var expected = node
        expected.status.session = node.status.session
        #expect(try decodeNodeProbeStatus(received.payload) == expected)
    }
}
