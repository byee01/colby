@testable import CombustionCodec

/// SplitMix64: small, deterministic and identical on every platform, so a failing seed reproduces anywhere.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Random but always valid domain values (every one encodes without error).
enum Gen {
    static func bool(_ r: inout SeededRNG) -> Bool { Bool.random(using: &r) }
    static func serial(_ r: inout SeededRNG) -> ProbeSerial { ProbeSerial(.random(in: 0...UInt32.max, using: &r)) }

    static func temperatures(_ r: inout SeededRNG) -> ProbeTemperatures {
        try! ProbeTemperatures(raw: (0..<8).map { _ in .random(in: 0...ProbeTemperatures.maxRaw, using: &r) })
    }

    static func virtualSensors(_ r: inout SeededRNG) -> VirtualSensors {
        let core = SensorIndex(rawValue: .random(in: 0...5, using: &r))!
        let surface = SensorIndex(rawValue: .random(in: 3...6, using: &r))!
        let ambient = SensorIndex(rawValue: .random(in: 4...7, using: &r))!
        return try! VirtualSensors(core: core, surface: surface, ambient: ambient)
    }

    static func sensors(_ r: inout SeededRNG) -> Set<SensorIndex> {
        Set(SensorIndex.allCases.filter { _ in Bool.random(using: &r) })
    }

    static func mode(_ r: inout SeededRNG) -> ProbeMode { ProbeMode(rawValue: .random(in: 0...3, using: &r))! }
    static func color(_ r: inout SeededRNG) -> ProbeColor { ProbeColor(raw: .random(in: 0...7, using: &r)) }

    static func preferences(_ r: inout SeededRNG) -> ThermometerPreferences {
        ThermometerPreferences(byte: .random(in: 0...7, using: &r))
    }

    static func predictionState(_ r: inout SeededRNG) -> PredictionState {
        [.notInserted, .inserted, .warming, .predicting, .removalPredictionDone, .unknown].randomElement(using: &r)!
    }

    static func predictionMode(_ r: inout SeededRNG) -> PredictionMode { PredictionMode(rawValue: .random(in: 0...3, using: &r))! }
    static func predictionType(_ r: inout SeededRNG) -> PredictionType { PredictionType(rawValue: .random(in: 0...3, using: &r))! }

    static func prediction(_ r: inout SeededRNG) -> PredictionStatus {
        PredictionStatus(
            state: predictionState(&r), mode: predictionMode(&r), type: predictionType(&r),
            setpoint: Double(UInt32.random(in: 0...1023, using: &r)) / 10,
            heatStart: Double(UInt32.random(in: 0...1023, using: &r)) / 10,
            rawSecondsRemaining: .random(in: 0...0x1FFFF, using: &r),
            estimatedCore: Double(UInt32.random(in: 0...2047, using: &r)) / 10 - 20)
    }

    static func predictionLog(_ r: inout SeededRNG) -> PredictionLog {
        PredictionLog(
            virtualSensors: virtualSensors(&r), state: predictionState(&r), mode: predictionMode(&r), type: predictionType(&r),
            setpoint: Double(UInt32.random(in: 0...1023, using: &r)) / 10,
            rawSecondsRemaining: .random(in: 0...0x1FFFF, using: &r),
            estimatedCore: Double(UInt32.random(in: 0...2047, using: &r)) / 10 - 20)
    }

    static func alarm(_ r: inout SeededRNG) -> Alarm {
        Alarm(isSet: bool(&r), temperature: Double(UInt32.random(in: 0...8190, using: &r)) / 10 - 20,
              tripped: bool(&r), alarming: bool(&r))
    }

    static func alarms(_ r: inout SeededRNG) -> AlarmConfig {
        var high = [AlarmChannel: Alarm](), low = [AlarmChannel: Alarm]()
        for channel in AlarmChannel.allCases {
            high[channel] = alarm(&r)
            low[channel] = alarm(&r)
        }
        return AlarmConfig(high: high, low: low)
    }

    static func foodSafe(_ r: inout SeededRNG) -> FoodSafe {
        let integrated = bool(&r)
        func fine(_ r: inout SeededRNG) -> Double { Double(UInt32.random(in: 0...8191, using: &r)) * 0.05 }
        return FoodSafe(
            mode: integrated ? .integrated : .simplified,
            product: .random(in: 0...1023, using: &r),
            serving: bool(&r) ? .servedImmediately : .cookedAndChilled,
            thresholdTemp: integrated ? fine(&r) : nil, zValue: integrated ? fine(&r) : nil,
            referenceTemp: integrated ? fine(&r) : nil, dValue: integrated ? fine(&r) : nil,
            targetLogReduction: Double(UInt32.random(in: 0...255, using: &r)) / 10,
            state: [.notSafe, .safe, .safetyImpossible].randomElement(using: &r)!,
            logReduction: Double(UInt32.random(in: 0...255, using: &r)) / 10,
            secondsAboveThreshold: .random(in: 0...UInt16.max, using: &r),
            logSequence: .random(in: 0...UInt32.max, using: &r))
    }

    static func session(_ r: inout SeededRNG) -> SessionInfo {
        SessionInfo(sessionId: .random(in: 1...UInt32.max, using: &r), samplePeriodMs: .random(in: 0...UInt16.max, using: &r))
    }

    /// A complete status (all optional parts present). Session is nil half the time (written as zeros).
    static func status(_ r: inout SeededRNG) -> ProbeStatusPayload {
        let min = UInt32.random(in: 0...UInt32.max, using: &r)
        return ProbeStatusPayload(
            logRange: LogRange(min: min, max: .random(in: min...UInt32.max, using: &r)),
            temperatures: temperatures(&r), mode: mode(&r), color: color(&r), probeNumber: .random(in: 1...8, using: &r),
            batteryLow: bool(&r), virtualSensors: virtualSensors(&r), prediction: prediction(&r),
            foodSafe: foodSafe(&r), overheating: sensors(&r), preferences: preferences(&r), alarms: alarms(&r),
            session: bool(&r) ? session(&r) : nil)
    }

    static func probeAdvertisement(_ r: inout SeededRNG, withPreferences: Bool) -> ProbeAdvertisement {
        ProbeAdvertisement(
            serial: serial(&r), temperatures: temperatures(&r), mode: mode(&r), color: color(&r),
            probeNumber: .random(in: 1...8, using: &r), batteryLow: bool(&r), virtualSensors: virtualSensors(&r),
            overheating: sensors(&r), preferences: withPreferences ? preferences(&r) : nil)
    }

    static func request(_ r: inout SeededRNG, node: Bool) -> UartRequest {
        var choices: [UartRequest] = [
            .readSessionInfo,
            .readLogs(start: .random(in: 0...UInt32.max, using: &r), end: .random(in: 0...UInt32.max, using: &r)),
            .setPrediction(setpoint: Double(UInt32.random(in: 0...1023, using: &r)) / 10,
                           mode: [.none, .timeToRemoval, .removalAndResting].randomElement(using: &r)!),
            .setAlarms(alarms(&r)),
            .silenceAlarms,
        ]
        if node { choices += [.readProbeFirmware, .readProbeHardware, .readProbeModel] }
        return choices.randomElement(using: &r)!
    }

    static func text(_ r: inout SeededRNG, maxLength: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789-._|")
        return String((0..<Int.random(in: 0...maxLength, using: &r)).map { _ in letters.randomElement(using: &r)! })
    }

    static func response(_ r: inout SeededRNG, node: Bool) -> UartResponse {
        let probe: ProbeSerial? = node ? serial(&r) : nil
        let types: [UInt8] = [3, 4, 5, 0x0B, 0x0C, 1, 2, 7, 8, 9, 0x0A] + (node ? [0x46, 0x47, 0x48] : [])
        let type = types.randomElement(using: &r)!
        let success = Int.random(in: 0...4, using: &r) != 0
        let body: UartResponse.Body
        switch (success, type) {
        case (true, 3):
            body = .sessionInfo(probe: probe, SessionInfo(sessionId: .random(in: 0...UInt32.max, using: &r), samplePeriodMs: .random(in: 0...UInt16.max, using: &r)))
        case (true, 4):
            body = .logRecord(probe: probe, LogRecord(sequence: .random(in: 0...UInt32.max, using: &r), temperatures: temperatures(&r), prediction: predictionLog(&r)))
        case (true, 0x46): body = .revision(probe: probe, kind: .firmware, text: text(&r, maxLength: 20))
        case (true, 0x47): body = .revision(probe: probe, kind: .hardware, text: text(&r, maxLength: 16))
        case (true, 0x48): body = .revision(probe: probe, kind: .model, text: text(&r, maxLength: 50))
        default: body = .ack
        }
        return UartResponse(
            messageType: type, success: success,
            requestId: node ? .random(in: 0...UInt32.max, using: &r) : nil,
            responseId: node ? .random(in: 0...UInt32.max, using: &r) : nil, body: body)
    }
}
