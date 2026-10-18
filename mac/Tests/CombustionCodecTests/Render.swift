@testable import CombustionCodec

/// Turns decoded values into the fixture JSON shape (see spec/fixtures/README.md).
enum Render {
    static func nullable<T>(_ value: T?, _ f: (T) -> JSONValue) -> JSONValue { value.map(f) ?? .null }
    static func number<T: BinaryInteger>(_ v: T) -> JSONValue { .number(Double(v)) }

    static func sensors(_ set: Set<SensorIndex>) -> JSONValue { .array(set.sorted().map { .string("\($0)") }) }

    static func virtual(_ v: VirtualSensors) -> JSONValue {
        ["core": .string("\(v.core)"), "surface": .string("\(v.surface)"), "ambient": .string("\(v.ambient)")]
    }

    static func preferences(_ p: ThermometerPreferences) -> JSONValue {
        ["powerMode": .string("\(p.powerMode)"), "highRadioPower": .bool(p.highRadioPower)]
    }

    static func temperatures(_ t: ProbeTemperatures) -> JSONValue { .array(t.celsius.map { .number($0) }) }

    static func prediction(_ p: PredictionStatus) -> JSONValue {
        ["state": .string("\(p.state)"), "mode": .string("\(p.mode)"), "type": .string("\(p.type)"), "setpoint": .number(p.setpoint),
         "heatStart": .number(p.heatStart), "rawSecondsRemaining": number(p.rawSecondsRemaining), "estimatedCore": .number(p.estimatedCore)]
    }

    static func predictionLog(_ p: PredictionLog) -> JSONValue {
        ["virtualSensors": virtual(p.virtualSensors), "state": .string("\(p.state)"), "mode": .string("\(p.mode)"), "type": .string("\(p.type)"),
         "setpoint": .number(p.setpoint), "rawSecondsRemaining": number(p.rawSecondsRemaining), "estimatedCore": .number(p.estimatedCore)]
    }

    static func foodSafe(_ f: FoodSafe) -> JSONValue {
        ["mode": .string("\(f.mode)"), "product": number(f.product), "serving": .string("\(f.serving)"),
         "thresholdTemp": nullable(f.thresholdTemp) { .number($0) }, "zValue": nullable(f.zValue) { .number($0) },
         "referenceTemp": nullable(f.referenceTemp) { .number($0) }, "dValue": nullable(f.dValue) { .number($0) },
         "targetLogReduction": .number(f.targetLogReduction), "state": .string("\(f.state)"), "logReduction": .number(f.logReduction),
         "secondsAboveThreshold": number(f.secondsAboveThreshold), "logSequence": number(f.logSequence)]
    }

    static func alarm(_ a: Alarm) -> JSONValue {
        ["set": .bool(a.isSet), "tripped": .bool(a.tripped), "alarming": .bool(a.alarming), "temperature": .number(a.temperature)]
    }

    static func alarms(_ c: AlarmConfig) -> JSONValue {
        func side(_ d: [AlarmChannel: Alarm]) -> JSONValue {
            .object(Dictionary(uniqueKeysWithValues: d.map { ("\($0.key)", alarm($0.value)) }))
        }
        return ["high": side(c.high), "low": side(c.low)]
    }

    static func status(_ s: ProbeStatusPayload) -> JSONValue {
        ["logRange": ["min": number(s.logRange.min), "max": number(s.logRange.max)],
         "temperatures": temperatures(s.temperatures), "mode": .string("\(s.mode)"), "color": .string("\(s.color)"),
         "probeNumber": number(s.probeNumber), "batteryLow": .bool(s.batteryLow), "virtualSensors": virtual(s.virtualSensors),
         "prediction": prediction(s.prediction), "foodSafe": nullable(s.foodSafe, foodSafe), "overheating": nullable(s.overheating, sensors),
         "preferences": nullable(s.preferences, preferences), "alarms": nullable(s.alarms, alarms),
         "session": nullable(s.session) { ["sessionId": number($0.sessionId), "samplePeriodMs": number($0.samplePeriodMs)] }]
    }

    static func nodeStatus(_ n: NodeProbeStatus) -> JSONValue {
        ["probeSerial": .string(n.serial.hex), "hopCount": number(n.hopCount), "status": status(n.status)]
    }

    static func probeAdvertisement(_ p: ProbeAdvertisement, kind: String, hopCount: Int? = nil) -> JSONValue {
        var o: [String: JSONValue] = [
            "kind": .string(kind), "serial": .string(p.serial.hex), "temperatures": temperatures(p.temperatures), "mode": .string("\(p.mode)"),
            "color": .string("\(p.color)"), "probeNumber": number(p.probeNumber), "batteryLow": .bool(p.batteryLow),
            "virtualSensors": virtual(p.virtualSensors), "overheating": nullable(p.overheating, sensors),
            "preferences": nullable(p.preferences, preferences)]
        if let hopCount { o["hopCount"] = number(hopCount) }
        return .object(o)
    }

    static func advertisement(_ p: AdvertisementPacket) -> JSONValue {
        switch p {
        case .probe(let a): return probeAdvertisement(a, kind: "probe")
        case .repeated(let a, let hops): return probeAdvertisement(a, kind: "repeated", hopCount: hops)
        case .node(let n):
            return ["kind": "node", "productType": number(n.productType.rawValue), "nodeProductType": .string("\(n.productType)"),
                    "serial": .string(n.serial), "preferences": nullable(n.preferences) { number($0) }]
        case .unknown(let t): return ["kind": "unknown", "productType": number(t)]
        }
    }

    static func error(_ e: CodecError) -> JSONValue {
        switch e {
        case .tooShort(let expected, let actual): return ["kind": "tooShort", "expected": number(expected), "actual": number(actual)]
        case .badSync: return ["kind": "badSync"]
        case .badCrc(let expected, let actual): return ["kind": "badCrc", "expected": number(expected), "actual": number(actual)]
        case .unknownMessageType(let t): return ["kind": "unknownMessageType", "type": number(t)]
        case .outOfRange(let field, let value): return ["kind": "outOfRange", "field": .string(field), "value": .number(value.isNaN ? 0 : value)]
        case .missingField(let field): return ["kind": "missingField", "field": .string(field)]
        }
    }

    static func frame(_ f: UartFrame) -> JSONValue {
        ["direction": .string("\(f.direction)"), "messageType": number(f.messageType), "requestId": nullable(f.requestId) { number($0) },
         "responseId": nullable(f.responseId) { number($0) }, "success": nullable(f.success) { .bool($0) },
         "payloadHex": .string(Hex.string(f.payload))]
    }

    static func response(_ r: UartResponse) -> JSONValue {
        let probeValue: (ProbeSerial?) -> JSONValue = { nullable($0) { .string($0.hex) } }
        let body: JSONValue
        switch r.body {
        case .ack: body = ["type": "ack"]
        case .sessionInfo(let probe, let info):
            body = ["type": "sessionInfo", "probe": probeValue(probe), "sessionId": number(info.sessionId), "samplePeriodMs": number(info.samplePeriodMs)]
        case .logRecord(let probe, let record):
            body = ["type": "logRecord", "probe": probeValue(probe), "sequence": number(record.sequence),
                    "temperatures": temperatures(record.temperatures), "prediction": predictionLog(record.prediction)]
        case .revision(let probe, let kind, let text):
            body = ["type": "revision", "probe": probeValue(probe), "kind": .string("\(kind)"), "text": .string(text)]
        }
        return ["messageType": number(r.messageType), "success": .bool(r.success), "requestId": nullable(r.requestId) { number($0) },
                "responseId": nullable(r.responseId) { number($0) }, "body": body]
    }
}
