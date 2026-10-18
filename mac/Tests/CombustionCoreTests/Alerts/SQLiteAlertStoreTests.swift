import CombustionCodec
@testable import CombustionCore
import Foundation
import Testing

/// Alert rules and the alert log in SQLite (docs/02 §11).
struct SQLiteAlertStoreTests {
    private static let everyKind: [AlertRule] = [
        AlertRule(id: "a", kind: .temperatureAbove(channel: .core, celsius: 95, hysteresis: 0.5)),
        AlertRule(id: "b", kind: .temperatureBelow(channel: .ambient, celsius: 107.2), enabled: false),
        AlertRule(id: "c", kind: .predictionWithin(seconds: 300)),
        AlertRule(id: "d", kind: .predictionDone),
        AlertRule(id: "e", kind: .restingDone),
        AlertRule(id: "f", kind: .ambientOutOfRange(min: 107, max: 135, sustain: 300)),
        AlertRule(id: "g", kind: .stall(window: 1800, minRise: 1.1)),
        AlertRule(id: "h", kind: .probeOffline(seconds: 60, onlyDuringCook: true)),
        AlertRule(id: "i", kind: .batteryLow),
    ]

    @Test func everyRuleKindRoundTripsInOrderWithItsEnabledFlag() async throws {
        let store = try SQLiteAlertStore(path: ":memory:")
        await store.saveRules(Self.everyKind, for: AF.serial)
        #expect(await store.loadRules(for: AF.serial) == Self.everyKind)
        #expect(await store.lastError == nil)
    }

    @Test func anUnconfiguredProbeIsNilButAnEmptyListStaysEmpty() async throws {
        let store = try SQLiteAlertStore(path: ":memory:")
        #expect(await store.loadRules(for: AF.serial) == nil, "nil means: seed the defaults")
        await store.saveRules([], for: AF.serial)
        #expect(await store.loadRules(for: AF.serial) == [], "the user removed every rule; do not re-seed")
        #expect(await store.loadRules(for: AF.other) == nil)
    }

    @Test func savingReplacesTheProbesRulesAndLeavesOtherProbesAlone() async throws {
        let store = try SQLiteAlertStore(path: ":memory:")
        await store.saveRules(Array(Self.everyKind.prefix(3)), for: AF.serial)
        await store.saveRules([AlertRule(id: "x", kind: .batteryLow)], for: AF.other)
        await store.saveRules([Self.everyKind[4], Self.everyKind[0]], for: AF.serial)
        #expect(await store.loadRules(for: AF.serial) == [Self.everyKind[4], Self.everyKind[0]])
        #expect(await store.loadRules(for: AF.other) == [AlertRule(id: "x", kind: .batteryLow)])
    }

    @Test func rulesSurviveAReopenAndShareTheFileWithHistory() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("colby-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        _ = try HistoryStore(path: path, clock: TestClock())
        do {
            let store = try SQLiteAlertStore(path: path)
            await store.saveRules(Self.everyKind, for: AF.serial)
        }
        let reopened = try SQLiteAlertStore(path: path)
        #expect(await reopened.loadRules(for: AF.serial) == Self.everyKind)
    }

    @Test func theEngineSeedsDefaultsOnceAndARestartedEngineKeepsTheEdits() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("colby-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let seed: @Sendable (ProbeSerial) -> [AlertRule] = { AlertRule.defaults(for: $0) }

        let first = AlertEngine(clock: TestClock(), ruleStore: try SQLiteAlertStore(path: path), defaultRules: seed)
        await first.setFollowed([AF.serial])
        let defaults = await first.rules(AF.serial)
        #expect(defaults == AlertRule.defaults(for: AF.serial))
        await first.removeRule(AF.serial, id: defaults[1].id)

        let second = AlertEngine(clock: TestClock(), ruleStore: try SQLiteAlertStore(path: path), defaultRules: seed)
        await second.setFollowed([AF.serial])
        #expect(await second.rules(AF.serial) == defaults.filter { $0.id != defaults[1].id })
    }

    // MARK: Alert log

    private func event(_ id: String, _ from: AlertState, _ to: AlertState, firedAt: Date, at: Date) -> AlertEvent {
        let inst = AlertInstance(
            id: id, serial: AF.serial, source: .rule(.predictionDone), state: to, firedAt: firedAt, value: 93.5)
        return AlertEvent(instance: inst, from: from, to: to, at: at)
    }

    @Test func oneFiringIsOneRowWithItsAcknowledgeAndClearTimes() async throws {
        let store = try SQLiteAlertStore(path: ":memory:")
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        await store.record(event("r", .idle, .firing, firedAt: t0, at: t0))
        await store.record(event("r", .firing, .snoozed, firedAt: t0, at: t0 + 10))
        await store.record(event("r", .snoozed, .firing, firedAt: t0, at: t0 + 310))
        await store.record(event("r", .firing, .acknowledged, firedAt: t0, at: t0 + 320))
        await store.record(event("r", .acknowledged, .idle, firedAt: t0, at: t0 + 900))

        let log = try await store.events(for: AF.serial, in: t0 - 1...t0 + 1000)
        #expect(log == [AlertLogEntry(alertId: "r", serial: AF.serial, firedAt: t0, acknowledgedAt: t0 + 320,
                                      clearedAt: t0 + 900, value: 93.5)])
    }

    @Test func aSecondCrossingIsASecondRow() async throws {
        let store = try SQLiteAlertStore(path: ":memory:")
        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        await store.record(event("r", .idle, .firing, firedAt: t0, at: t0))
        await store.record(event("r", .firing, .idle, firedAt: t0, at: t0 + 60))
        await store.record(event("r", .idle, .firing, firedAt: t0 + 120, at: t0 + 120))
        let log = try await store.events(for: AF.serial, in: t0...t0 + 200)
        #expect(log.map(\.firedAt) == [t0, t0 + 120])
        #expect(log.map(\.clearedAt) == [t0 + 60, nil])
    }

    @Test func theAppLogsWhatTheEngineFires() async throws {
        let rig = AlertRig()
        let store = try SQLiteAlertStore(path: ":memory:")
        let events = rig.engine.events
        let consumer = Task { await store.consume(events) }
        defer { consumer.cancel() }

        await rig.follow([AlertRule(id: "hot", kind: .temperatureAbove(channel: .core, celsius: 60))])
        let fired = rig.clock.now()
        await rig.snapshot(core: 61)
        await rig.clock.advance(by: .seconds(30))
        await rig.engine.acknowledge("hot")

        var log: [AlertLogEntry] = []
        for _ in 0..<200 {
            log = try await store.events(for: AF.serial, in: fired - 1...fired + 60)
            if log.first?.acknowledgedAt != nil { break }
            await Task.yield()
        }
        #expect(log.count == 1)
        #expect(log.first?.alertId == "hot")
        #expect(log.first?.acknowledgedAt == fired + 30)
        #expect(log.first?.value == 61)
    }
}
