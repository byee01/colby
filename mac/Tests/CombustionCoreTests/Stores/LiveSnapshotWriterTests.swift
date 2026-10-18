import CombustionCodec
@testable import CombustionCore
import Foundation
import Testing

/// The widget snapshot (docs/02 §18): content, order and write throttling.
struct LiveSnapshotWriterTests {
    final class CollectingWriter: LiveSnapshotWriting, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Data] = []
        var writes: [Data] { lock.withLock { stored } }
        func write(_ data: Data) async throws { lock.withLock { stored.append(data) } }
    }

    private struct Rig {
        let clock = TestClock()
        let out = CollectingWriter()
        let writer: LiveSnapshotWriter
        init() { writer = LiveSnapshotWriter(clock: clock, writer: out) }

        func snap(_ serial: ProbeSerial = AF.serial, core: Double?, number: Int = 1, offline: Bool = false,
                  prediction: PredictionStatus? = nil) async {
            var s = AF.snapshot(serial, at: clock.now(), core: core, offline: offline, prediction: prediction)
            s.probeNumber = number
            await writer.ingest(snapshots: [serial: s])
        }
    }

    private func decode(_ data: Data) throws -> LiveSnapshot {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(LiveSnapshot.self, from: data)
    }

    @Test func writesOnlyFollowedProbesWithTheFieldsAWidgetShows() async throws {
        let rig = Rig()
        await rig.writer.setFollowed([AF.serial])
        await rig.writer.setName("Brisket", for: AF.serial)
        await rig.snap(AF.other, core: 50, number: 2)
        await rig.snap(core: 74, prediction: AF.prediction(.predicting))
        let readyAt = rig.clock.now().addingTimeInterval(222)
        var view = AF.view(seconds: 222)
        view.readyAt = readyAt
        await rig.writer.ingest(prediction: view)

        let last = try decode(try #require(rig.out.writes.last))
        #expect(last.probes.count == 1, "probe 2 is not followed")
        let p = try #require(last.probes.first)
        #expect(p.serial == AF.serial.hex)
        #expect(p.name == "Brisket")
        #expect(p.core == 74)
        #expect(p.target == 60)
        #expect(p.state == "predicting")
        #expect(p.secondsRemaining == 222)
        #expect(p.readyAt == readyAt)
        #expect(p.isOffline == false)
        #expect(p.trend == [74])
    }

    @Test func noTargetWhenNoPredictionModeIsSet() async throws {
        let rig = Rig()
        await rig.writer.setFollowed([AF.serial])
        var status = AF.prediction(.inserted)
        status.mode = .none
        await rig.snap(core: 30, prediction: status)
        #expect(await rig.writer.current().probes.first?.target == nil)
    }

    @Test func soonestFinishFirstThenReadyThenTheRestByProbeNumber() async throws {
        let rig = Rig()
        let a = ProbeSerial(1), b = ProbeSerial(2), c = ProbeSerial(3), d = ProbeSerial(4)
        await rig.writer.setFollowed([a, b, c, d])
        for (s, n) in [(a, 1), (b, 2), (c, 3), (d, 4)] { await rig.snap(s, core: 50, number: n) }
        func view(_ s: ProbeSerial, _ state: PredictionState, readyIn: TimeInterval? = nil) -> PredictionView {
            var v = AF.view(s, state: state, seconds: readyIn.map { UInt32($0) })
            v.readyAt = readyIn.map { rig.clock.now().addingTimeInterval($0) }
            return v
        }
        await rig.writer.ingest(prediction: view(a, .predicting, readyIn: 3600))
        await rig.writer.ingest(prediction: view(b, .removalPredictionDone))
        await rig.writer.ingest(prediction: view(c, .predicting, readyIn: 600))
        await rig.writer.ingest(prediction: view(d, .warming))
        #expect(await rig.writer.current().probes.map(\.number) == [3, 1, 2, 4])
    }

    @Test func temperatureChangesAreThrottledToOneWriteEveryFiveSecondsButStateChangesWriteAtOnce() async throws {
        let rig = Rig()
        await rig.writer.setFollowed([AF.serial])
        await rig.snap(core: 70)
        let afterFirst = rig.out.writes.count
        for core in [70.5, 71.0, 71.5] {
            await rig.clock.advance(by: .seconds(1))
            await rig.snap(core: core)
        }
        #expect(rig.out.writes.count == afterFirst, "within 5 s: no write yet")

        await rig.writer.ingest(prediction: AF.view(state: .removalPredictionDone))
        #expect(rig.out.writes.count == afterFirst + 1, "Ready is written immediately")

        await rig.snap(core: 72)
        await rig.clock.advance(by: .seconds(6))
        for _ in 0..<200 where rig.out.writes.count < afterFirst + 2 { await Task.yield() }
        #expect(rig.out.writes.count == afterFirst + 2, "one trailing write when the interval is up")
        #expect(try decode(rig.out.writes.last!).probes.first?.core == 72)
    }

    @Test func trendKeepsOnePointPerFiveSecondsAndTheLastThirty() async throws {
        let rig = Rig()
        await rig.writer.setFollowed([AF.serial])
        for i in 0..<80 {
            await rig.snap(core: Double(i))
            await rig.clock.advance(by: .milliseconds(2500))
        }
        let trend = try #require(await rig.writer.current().probes.first?.trend)
        #expect(trend.count == LiveSnapshotWriter.trendLength)
        #expect(trend.last == 78)
        #expect(zip(trend, trend.dropFirst()).allSatisfy { $1 - $0 == 2 }, "every second reading, 5 s apart")
    }

    @Test func anOfflineProbeIsFlaggedAndAddsNoTrendPoint() async throws {
        let rig = Rig()
        await rig.writer.setFollowed([AF.serial])
        await rig.snap(core: 70)
        await rig.clock.advance(by: .seconds(10))
        await rig.snap(core: 70, offline: true)
        let p = try #require(await rig.writer.current().probes.first)
        #expect(p.isOffline)
        #expect(p.trend == [70])
    }
}
