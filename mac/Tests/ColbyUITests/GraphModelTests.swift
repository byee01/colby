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
    @Test func yAxisFitsTheReadingsAndTarget() {
        // Readings run from about 20 °C to 100 °C ambient; the target 95 °C is inside that.
        let now = start.addingTimeInterval(600)
        let m = GraphModel(series: series(Array(0...120)), target: 95, range: .all, now: now, width: 400, unit: .celsius)
        #expect(m.yMin <= 20 && m.yMin >= 0)
        #expect(m.yMax >= 100 && m.yMax <= 120)
        #expect((m.yMax - m.yMin) / m.yStep <= 6)
    }

    @Test func aFlatRoomTemperatureTraceGetsATightAxis() {
        // The phone app's look: 72-77 °F fills the plot instead of hugging the bottom of 50-150.
        let axis = GraphModel.yAxis([72, 73.5, 75, 77], target: nil)
        #expect(axis.min == 65 && axis.max == 85 && axis.step == 5)
        // A target above the readings stays on the plot.
        let withTarget = GraphModel.yAxis([72, 77], target: 203)
        #expect(withTarget.min <= 72 && withTarget.max >= 203)
        // Nothing to show yet.
        #expect(GraphModel.yAxis([], target: nil) == (50, 100, 10))
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
