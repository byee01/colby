import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// Delegates to a `SimulatedTransport` and records when `connect` was called.
final class ConnectSpyTransport: BleTransport, @unchecked Sendable {
    let inner: SimulatedTransport
    private let clock: TestClock
    private let lock = NSLock()
    private var times: [Duration] = []

    init(inner: SimulatedTransport, clock: TestClock) {
        self.inner = inner
        self.clock = clock
    }

    /// Monotonic times of every connect call, successful or not.
    var attempts: [Duration] { lock.withLock { times } }

    var state: AsyncStream<BluetoothState> { inner.state }
    var advertisements: AsyncStream<RawAdvertisement> { inner.advertisements }
    func startScan() async { await inner.startScan() }
    func stopScan() async { await inner.stopScan() }
    func connect(_ id: PeripheralId, timeout: Duration) async throws -> any GattConnection {
        lock.withLock { times.append(clock.monotonic()) }
        return try await inner.connect(id, timeout: timeout)
    }
}

/// A `CombustionApp` over a simulated transport and a `TestClock`.
final class E2ERig: @unchecked Sendable {
    let clock = TestClock(wakeGrace: .microseconds(500))
    let transport: SimulatedTransport
    let spy: ConnectSpyTransport
    let app: CombustionApp
    let trace: JSONLTraceSink

    init(policy: (any ConnectionPolicy)? = nil, alertSinks: [any AlertSink] = [], keepAwake: (any KeepAwake)? = nil) throws {
        let clock = self.clock
        transport = SimulatedTransport(clock: clock)
        spy = ConnectSpyTransport(inner: transport, clock: clock)
        trace = try JSONLTraceSink(clock: clock)
        app = try CombustionApp(
            transport: spy, clock: clock, policy: policy, trace: trace, alertSinks: alertSinks, keepAwake: keepAwake)
    }

    func probe(_ serial: ProbeSerial, preload: Int = 0, sessionId: UInt32 = 1, offset: Double = 0,
               period: Duration = .seconds(5)) -> SimulatedProbe {
        let p = SimulatedProbe(serial: serial, transport: transport, clock: clock, sessionId: sessionId,
                               samplePeriod: period, curve: SimulatedProbe.cookCurve(offset: offset))
        if preload > 0 { p.preload(records: preload) }
        p.start()
        return p
    }

    /// Advances virtual time in `step`s, letting the pipeline drain after each.
    func run(_ total: Duration, step: Duration = .seconds(5)) async {
        var left = total
        while left > .zero {
            // End each step on a multiple of `step` so the probes' sample ticks (every 5 s) are the last
            // thing in a step: the stages that read the clock on receipt then see the sample's own time.
            let into = clock.monotonic().totalSeconds.truncatingRemainder(dividingBy: step.totalSeconds)
            let d = min(left, step - .seconds(into))
            await clock.advance(by: d)
            await drain()
            left -= d
        }
    }

    /// Lets the pipeline (simulator, links, stores, SQLite) consume what the last step produced, before time
    /// moves again: waits until writes, advertisements handled and stored samples stop changing. Real time
    /// is spent only to let other threads run; no outcome depends on how long that takes.
    func drain() async {
        var last = await fingerprint()
        var stable = 0
        for _ in 0..<400 {
            try? await Task.sleep(for: .milliseconds(1))
            await clock.settle()
            let now = await fingerprint()
            if now == last, now.last == 0 {
                stable += 1
                if stable >= 3 { return }
            } else {
                stable = 0
                last = now
            }
        }
    }

    private func fingerprint() async -> [Int] {
        let d = await app.diagnostics()
        var f = [transport.writes.count, d.advertisements.received]
        for serial in await app.probes.followedSerials().sorted() {
            if let key = try? await app.history.currentSession(of: serial) {
                f.append((try? await app.history.sampleCount(key)) ?? 0)
            }
        }
        f.append(d.logFetchesInFlight) // keep last: drain waits for it to be 0
        return f
    }

    /// Scheduler turns (no virtual time) until `condition` holds.
    func eventually(_ condition: () async -> Bool) async -> Bool {
        for i in 0..<2000 {
            if await condition() { return true }
            await clock.settle()
            if i % 50 == 49 { try? await Task.sleep(for: .milliseconds(1)) }
        }
        return await condition()
    }

    /// Runs in `step`s until `condition` holds or `limit` of virtual time has passed.
    func run(until condition: () async -> Bool, limit: Duration = .seconds(120), step: Duration = .seconds(1)) async -> Bool {
        var spent = Duration.zero
        while spent < limit {
            if await condition() { return true }
            await run(step, step: step)
            spent += step
        }
        return await condition()
    }

    func connected(_ serial: ProbeSerial) async -> Bool {
        await app.diagnostics().links[serial] == .connected
    }

    /// The seqs stored for the latest session of `serial`, ascending.
    func storedSeqs(_ serial: ProbeSerial, session index: Int = 0) async throws -> [UInt32] {
        let sessions = try await app.history.sessions(serial: serial)
        guard sessions.indices.contains(index),
              let series = try await app.history.currentSeries(sessions[index].key) else { return [] }
        return series.samples.map(\.seq)
    }

    func series(_ serial: ProbeSerial, session index: Int = 0) async throws -> TemperatureSeries {
        let sessions = try await app.history.sessions(serial: serial)
        let summary = try #require(sessions[safe: index])
        return try #require(try await app.history.currentSeries(summary.key))
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

let serialA = ProbeSerial(0x1000_000A)
let serialB = ProbeSerial(0x1000_000B)
let serialC = ProbeSerial(0x1000_000C)

func contiguous(_ range: ClosedRange<UInt32>) -> [UInt32] { Array(range) }

/// Checks connect-attempt times (seconds) against the schedule the backoff should produce. A woken task on a
/// busy machine can resume a little late in virtual time, and that delay carries into later attempts, so
/// each attempt may be up to `slack` seconds late but never early, and the count must match.
func expectSchedule(_ actual: [Double], _ expected: [Double], slack: Double = 5,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual.count == expected.count, "attempts \(actual)", sourceLocation: sourceLocation)
    for (a, e) in zip(actual, expected) {
        #expect(a >= e && a <= e + slack, "attempt at \(a), expected \(e) (+\(slack) s allowed) in \(actual)",
                sourceLocation: sourceLocation)
    }
}
