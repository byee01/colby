#if canImport(SwiftUI) && canImport(AppKit)
import CombustionCodec
import CombustionCore
import Foundation
import Testing
@testable import ColbyUI

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func series(_ seqs: [UInt32], core: (UInt32) -> Double = { 20 + Double($0) / 10 }) -> TemperatureSeries {
    let sensors = try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8)
    let samples = seqs.map { seq in
        TemperatureSample(
            seq: seq, time: start.addingTimeInterval(Double(seq) * 5),
            temperatures: [core(seq), 0, 0, 30, 0, 0, 0, 100], virtualSensors: sensors,
            prediction: PredictionLog(virtualSensors: sensors, state: .predicting, mode: .timeToRemoval, type: .removal,
                                      setpoint: 0, rawSecondsRemaining: 0, estimatedCore: 0))
    }
    return TemperatureSeries(key: SessionKey(serial: ProbeSerial(1), sessionId: 1, startedAt: start),
                             samplePeriod: 5, anchorSeq: 0, anchorTime: start, samples: samples)
}

struct GraphModelTests {
    @Test func yAxisFollowsTheUxRule() {
        // Ambient 100 °C = 212 °F; target 95 °C = 203 °F. 212 + 30 → 250; lower bound 50.
        let now = start.addingTimeInterval(600)
        let m = GraphModel(series: series(Array(0...120)), target: 95, range: .all, now: now, width: 400, unit: .fahrenheit)
        #expect(m.yMin == 50)
        #expect(m.yMax == 250)
        #expect(m.yStep == 50)
        // In °C the data dips below 50, so the axis starts at 0.
        let mc = GraphModel(series: series(Array(0...120)), target: nil, range: .all, now: now, width: 400, unit: .celsius)
        #expect(mc.yMin == 0)
        #expect(mc.yMax == 150)
    }

    @Test func missingSamplesBreakTheLine() {
        let m = GraphModel(series: series(Array(0...10) + Array(30...40)), target: nil, range: .all,
                           now: start.addingTimeInterval(200), width: 400, unit: .celsius)
        #expect(m.points.count == 22)
        #expect(m.breaks == [11])
    }

    @Test func liveShowsTheLastThirtyMinutes() {
        let now = start.addingTimeInterval(4 * 3600)
        let m = GraphModel(series: series(Array(0...2880)), target: nil, range: .live, now: now, width: 600, unit: .celsius)
        #expect(m.end == now)
        #expect(m.start == now.addingTimeInterval(-1800))
    }

    @Test func nearestPicksTheClosestPoint() throws {
        let m = GraphModel(series: series(Array(0...10)), target: nil, range: .all,
                           now: start.addingTimeInterval(50), width: 400, unit: .celsius)
        let p = try #require(m.nearest(start.addingTimeInterval(12)))
        #expect(p.time == start.addingTimeInterval(10))
        #expect(abs(p.core - 20.2) < 1e-9)
    }
}
#endif
