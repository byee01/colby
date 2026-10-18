import CombustionCodec
import CombustionCore
import Foundation

/// Thread-safe collector for stream consumers in tests.
final class StoreLog<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [T] = []
    func add(_ v: T) { lock.withLock { storage.append(v) } }
    var items: [T] { lock.withLock { storage } }
    var last: T? { lock.withLock { storage.last } }
    var count: Int { lock.withLock { storage.count } }
}

enum StoreFixtures {
    static let t0 = TestClock.defaultStart
    static let serial = ProbeSerial(0x1000_5A3F)

    static func virtual(core: SensorIndex = .t1, surface: SensorIndex = .t4, ambient: SensorIndex = .t5) -> VirtualSensors {
        try! VirtualSensors(core: core, surface: surface, ambient: ambient)
    }

    static func temps(core: Double = 25, surface: Double = 30, ambient: Double = 40) -> ProbeTemperatures {
        // T1 core, T4 surface, T5 ambient (default virtual sensors); others fill with the core value.
        try! ProbeTemperatures(celsius: [core, core, core, surface, ambient, core, core, core])
    }

    static func prediction(state: PredictionState = .notInserted, mode: PredictionMode = .none, setpoint: Double = 0,
                           seconds: UInt32 = 0, est: Double = 25) -> PredictionStatus {
        PredictionStatus(state: state, mode: mode, type: mode == .none ? .none : .removal, setpoint: setpoint,
                         heatStart: 20, rawSecondsRemaining: seconds, estimatedCore: est)
    }

    static func status(
        core: Double = 25, surface: Double = 30, ambient: Double = 40, mode: ProbeMode = .normal,
        logMin: UInt32 = 0, logMax: UInt32 = 0, sessionId: UInt32? = 1, periodMs: UInt16 = 5000,
        prediction: PredictionStatus = StoreFixtures.prediction(), alarms: AlarmConfig? = AlarmConfig(),
        batteryLow: Bool = false
    ) -> ProbeStatusPayload {
        ProbeStatusPayload(
            logRange: LogRange(min: logMin, max: logMax), temperatures: temps(core: core, surface: surface, ambient: ambient),
            mode: mode, color: .yellow, probeNumber: 1, batteryLow: batteryLow, virtualSensors: virtual(),
            prediction: prediction, foodSafe: nil, overheating: [], preferences: nil, alarms: alarms,
            session: sessionId.map { SessionInfo(sessionId: $0, samplePeriodMs: periodMs) })
    }

    static func advertisement(serial: ProbeSerial = serial, core: Double = 25, mode: ProbeMode = .normal,
                              t1: Double? = nil) -> ProbeAdvertisement {
        var t = temps(core: core)
        if let t1 {
            var c = t.celsius
            c[0] = t1
            t = try! ProbeTemperatures(celsius: c)
        }
        return ProbeAdvertisement(serial: serial, temperatures: t, mode: mode, color: .yellow, probeNumber: 1,
                                  batteryLow: false, virtualSensors: virtual())
    }

    static func source(_ kind: LinkSource.Kind, via: NodeSerial? = nil, hop: Int? = nil, at: Date = t0) -> LinkSource {
        LinkSource(kind: kind, via: via, hopCount: hop, rssi: -60, highRadioPower: nil, lastSeen: at)
    }

    static func observe(_ payload: ProbeObservation.Payload, kind: LinkSource.Kind, via: NodeSerial? = nil,
                        hop: Int? = nil, at: Date, serial: ProbeSerial = serial) -> ProbeObservation {
        ProbeObservation(serial: serial, source: source(kind, via: via, hop: hop, at: at), payload: payload, receivedAt: at)
    }

    // MARK: Log records

    static func record(_ seq: UInt32, core: Double? = nil, surface: Double = 30, ambient: Double = 40,
                       mode: PredictionMode = .none, setpoint: Double = 0, state: PredictionState = .notInserted) -> LogRecord {
        let c = core ?? 20 + Double(seq % 600) * 0.5
        return LogRecord(
            sequence: seq, temperatures: temps(core: c, surface: surface, ambient: ambient),
            prediction: PredictionLog(virtualSensors: virtual(), state: state, mode: mode,
                                      type: mode == .none ? .none : .removal, setpoint: setpoint,
                                      rawSecondsRemaining: 0, estimatedCore: c))
    }
}

struct FetchFailure: Error {}

/// Log source for tests. Serves `records`, optionally withholding seqs (partial results) or failing a request.
final class StoreFakeFetcher: LogFetcher, @unchecked Sendable {
    struct Request: Equatable, Sendable {
        var start: UInt32
        var end: UInt32
    }

    private let lock = NSLock()
    private var records: [UInt32: LogRecord] = [:]
    private var withheld: Set<UInt32> = []
    private var failOnRequest: Int?
    private var log: [Request] = []

    init(seqs: ClosedRange<UInt32>? = nil, core: ((UInt32) -> Double)? = nil) {
        if let seqs { for s in seqs { records[s] = StoreFixtures.record(s, core: core?(s)) } }
    }

    func add(_ r: LogRecord) { lock.withLock { records[r.sequence] = r } }
    func addRange(_ r: ClosedRange<UInt32>) { for s in r { add(StoreFixtures.record(s)) } }
    func withhold(_ s: some Sequence<UInt32>) { lock.withLock { withheld = Set(s) } }
    func release() { lock.withLock { withheld = [] } }
    /// Throws (after delivering) on the n-th request, 1-based.
    func fail(onRequest n: Int?) { lock.withLock { failOnRequest = n } }
    var requests: [Request] { lock.withLock { log } }

    func readLogs(probe: ProbeSerial, start: UInt32, end: UInt32) -> AsyncThrowingStream<LogRecord, any Error> {
        let (recs, fails): ([LogRecord], Bool) = lock.withLock {
            log.append(Request(start: start, end: end))
            let n = log.count
            let out = (start...end).compactMap { s in withheld.contains(s) ? nil : records[s] }
            return (out, failOnRequest == n)
        }
        return AsyncThrowingStream { c in
            if fails {
                c.finish(throwing: FetchFailure())
            } else {
                for r in recs { c.yield(r) }
                c.finish()
            }
        }
    }
}

/// Gives consumer tasks scheduler turns until `condition` holds (bounded). Logic never depends on it;
/// it only absorbs real-thread scheduling latency between a send and its consumer.
func settle(_ clock: TestClock, until condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { await clock.settle() }
}
