import CombustionCodec
import CombustionCore
import Foundation

/// A scriptable virtual probe on top of `SimulatedTransport`, driven by a `Clock`.
///
/// Every 250 ms it advertises (when in range). Every `samplePeriod` it appends a log record, and, when
/// the app is connected, sends a Probe Status notification. It answers UART requests on RX.
///
/// Controls: `setInRange` (out of range: no adverts, the connection drops with `.linkLost`, connects are
/// refused), `newSession` (charger removal: new session id, log restarts at seq 0), `legacyFirmware`
/// (session id 0, 94 B status, Read Session Information fails), `preload` (a cook that started before
/// the app did), `dropLinkAfterLogRecords` (link loss in the middle of a log download).
///
/// Lock order: the transport calls responders while holding its lock, so this class never calls the
/// transport while holding its own lock.
public final class SimulatedProbe: @unchecked Sendable {
    /// Eight temperatures (°C) for log record `seq`.
    public typealias Curve = @Sendable (_ seq: UInt32, _ samplePeriod: Double) -> [Double]

    public static let advertisementPeriod: Duration = .milliseconds(250)

    public let serial: ProbeSerial
    public let peripheral: PeripheralId
    public let samplePeriod: Duration

    private let transport: SimulatedTransport
    private let clock: any Clock
    private let probeNumber: Int
    private let ticksPerSample: Int
    private let virtualSensors: VirtualSensors

    private let lock = NSLock()
    private var curve: Curve
    private var records: [LogRecord] = []
    private var session: UInt32
    private var ticks = 0
    private var inRange = true
    private var legacy = false
    private var running = false
    private var task: Task<Void, Never>?
    private var setpoint = 0.0
    private var predictionMode: PredictionMode = .none
    private var alarms = AlarmConfig()
    private var received: [UartRequest] = []
    private var cutLogsAfter: Int?
    private var dropLinkOnNextTick = false

    public init(
        serial: ProbeSerial, transport: SimulatedTransport, clock: any Clock,
        peripheral: PeripheralId? = nil, sessionId: UInt32 = 1, samplePeriod: Duration = .seconds(5),
        probeNumber: Int = 1, curve: Curve? = nil
    ) {
        self.serial = serial
        self.transport = transport
        self.clock = clock
        self.peripheral = peripheral ?? PeripheralId("PROBE-\(serial.hex)")
        self.session = sessionId
        self.samplePeriod = samplePeriod
        self.probeNumber = probeNumber
        self.curve = curve ?? SimulatedProbe.cookCurve()
        self.virtualSensors = try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8)
        let ticks = Int((samplePeriod.totalSeconds / Self.advertisementPeriod.totalSeconds).rounded())
        self.ticksPerSample = max(1, ticks)
        appendRecordLocked()
    }

    deinit { task?.cancel() }

    // MARK: Lifecycle

    /// Registers the UART responder and starts advancing on the clock. Idempotent.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        transport.addResponder(peripheral: peripheral) { [weak self] bytes in self?.respond(bytes) ?? [] }
        // A timer, not a sleep loop: a TestClock timer re-arms itself, so no tick is lost if this task
        // is slow to resume.
        let ticks = clock.timer(every: Self.advertisementPeriod)
        task = Task { [weak self] in
            for await _ in ticks {
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// Stops advancing. The responder stays registered but stops answering.
    public func stop() {
        lock.withLock { running = false }
        task?.cancel()
        task = nil
    }

    // MARK: Controls

    public var isInRange: Bool { lock.withLock { inRange } }

    /// Out of range: no advertisements, the open connection drops with `.linkLost`, connects are refused.
    /// The probe keeps logging.
    public func setInRange(_ value: Bool) {
        let changed: Bool = lock.withLock {
            defer { inRange = value }
            return inRange != value
        }
        guard changed else { return }
        if value {
            transport.allowConnects(to: peripheral)
        } else {
            transport.blockConnects(to: peripheral)
            transport.forceDisconnect(peripheral, reason: .linkLost)
        }
    }

    /// Charger removal: a new session id and an empty log; the first record (seq 0) is written at once.
    public func newSession(sessionId: UInt32? = nil) {
        lock.withLock {
            session = sessionId ?? session &+ 1
            records.removeAll()
            ticks = 0
            appendRecordLocked()
        }
    }

    /// Old firmware: no session id (status reports 0 and is 94 B) and no Read Session Information.
    public var legacyFirmware: Bool {
        get { lock.withLock { legacy } }
        set { lock.withLock { legacy = newValue } }
    }

    public func setCurve(_ curve: @escaping Curve) { lock.withLock { self.curve = curve } }

    /// Appends `count` records instantly, as if the probe had been cooking before the app started.
    public func preload(records count: Int) {
        lock.withLock { for _ in 0..<count { appendRecordLocked() } }
    }

    /// The next Read Logs answers with `count` records only, then the link drops on the next tick.
    public func dropLinkAfterLogRecords(_ count: Int) {
        lock.withLock { cutLogsAfter = count }
    }

    // MARK: Observation

    public var sessionId: UInt32 { lock.withLock { session } }
    public var logRange: LogRange { lock.withLock { LogRange(min: 0, max: UInt32(records.count - 1)) } }
    public var recordCount: Int { lock.withLock { records.count } }
    public func record(_ seq: UInt32) -> LogRecord? { lock.withLock { records.indices.contains(Int(seq)) ? records[Int(seq)] : nil } }
    /// Every UART request answered, in order.
    public var requests: [UartRequest] { lock.withLock { received } }
    public var currentAlarms: AlarmConfig { lock.withLock { alarms } }
    public var currentPrediction: (setpoint: Double, mode: PredictionMode) { lock.withLock { (setpoint, predictionMode) } }

    // MARK: A simple cook

    /// Core climbs from `start` toward 95 °C over hours; the ambient sensors lead it, with a smooth
    /// gradient in between. `offset` separates probes in multi-probe tests.
    public static func cookCurve(start: Double = 20, offset: Double = 0) -> Curve {
        { seq, period in
            let t = Double(seq) * period
            let core = start + offset + 70 * (1 - exp(-t / 6000))
            let ambient = start + offset + 100 * (1 - exp(-t / 600))
            return (0..<8).map { core + (ambient - core) * Double($0) / 7 }
        }
    }

    // MARK: Internals

    private func appendRecordLocked() {
        let seq = UInt32(records.count)
        let temps = (try? ProbeTemperatures(celsius: curve(seq, samplePeriod.totalSeconds)))
            ?? (try! ProbeTemperatures(raw: [UInt16](repeating: 0, count: 8)))
        let core = temps[virtualSensors.core]
        records.append(LogRecord(
            sequence: seq, temperatures: temps,
            prediction: PredictionLog(
                virtualSensors: virtualSensors, state: predictionStateLocked(), mode: predictionMode,
                type: predictionMode == .none ? .none : .removal, setpoint: setpoint,
                rawSecondsRemaining: predictionMode == .none ? 0 : 600, estimatedCore: core)))
    }

    private func predictionStateLocked() -> PredictionState {
        predictionMode == .none ? .notInserted : .predicting
    }

    private func tick() {
        enum Work { case idle, send(advertisement: [UInt8], status: [UInt8]?, drop: Bool) }
        let work: Work = lock.withLock {
            guard running else { return .idle }
            ticks += 1
            let sampled = ticks % ticksPerSample == 0
            if sampled { appendRecordLocked() }
            let drop = dropLinkOnNextTick
            dropLinkOnNextTick = false
            guard inRange else { return .idle }
            let last = records[records.count - 1]
            let ad = (try? encodeAdvertisement(.probe(advertisement(last)))) ?? []
            let status = sampled ? (try? encodeProbeStatus(statusPayload(last), layout: legacy ? .legacy : .current)) : nil
            return .send(advertisement: ad, status: status, drop: drop)
        }
        guard case .send(let ad, let status, let drop) = work else { return }
        transport.injectAdvertisement(peripheral: peripheral, mfrData: ad)
        if let status, transport.isConnected(peripheral) {
            transport.injectNotification(peripheral: peripheral, characteristic: .probeStatus, bytes: status)
        }
        if drop { transport.forceDisconnect(peripheral, reason: .linkLost) }
    }

    private func advertisement(_ last: LogRecord) -> ProbeAdvertisement {
        ProbeAdvertisement(
            serial: serial, temperatures: last.temperatures, mode: .normal, color: .yellow,
            probeNumber: probeNumber, batteryLow: false, virtualSensors: virtualSensors,
            overheating: [], preferences: ThermometerPreferences(powerMode: .normal, highRadioPower: false))
    }

    private func statusPayload(_ last: LogRecord) -> ProbeStatusPayload {
        let p = last.prediction
        return ProbeStatusPayload(
            logRange: LogRange(min: 0, max: last.sequence), temperatures: last.temperatures, mode: .normal,
            color: .yellow, probeNumber: probeNumber, batteryLow: false, virtualSensors: virtualSensors,
            prediction: PredictionStatus(
                state: p.state, mode: p.mode, type: p.type, setpoint: p.setpoint, heatStart: 20,
                rawSecondsRemaining: p.rawSecondsRemaining, estimatedCore: p.estimatedCore),
            foodSafe: FoodSafe(mode: .simplified, product: 1, serving: .servedImmediately, state: .notSafe),
            overheating: [], preferences: ThermometerPreferences(powerMode: .normal, highRadioPower: false),
            alarms: alarms,
            session: legacy ? nil : SessionInfo(sessionId: session, samplePeriodMs: UInt16(samplePeriod.totalSeconds * 1000)))
    }

    /// Answers one RX write. Called by the transport (under its lock), so nothing here touches the transport.
    private func respond(_ bytes: [UInt8]) -> [[UInt8]] {
        var framer = UartFramer(variant: .probe, direction: .request)
        var out: [[UInt8]] = []
        for case .frame(let frame) in framer.push(bytes) {
            guard let message = try? decodeRequest(frame) else { continue }
            out += lock.withLock { answerLocked(message.request) }
        }
        return out
    }

    private func answerLocked(_ request: UartRequest) -> [[UInt8]] {
        received.append(request)
        func reply(_ type: UInt8, success: Bool = true, _ body: UartResponse.Body = .ack) -> [UInt8] {
            (try? encodeResponse(UartResponse(messageType: type, success: success, body: body), variant: .probe)) ?? []
        }
        switch request {
        case .readSessionInfo:
            if legacy { return [reply(UartMessageType.readSessionInfo, success: false)] }
            let info = SessionInfo(sessionId: session, samplePeriodMs: UInt16(samplePeriod.totalSeconds * 1000))
            return [reply(UartMessageType.readSessionInfo, .sessionInfo(probe: nil, info))]
        case .readLogs(let start, let end):
            guard start <= end, Int(start) < records.count else { return [] }
            var seqs = Array(start...min(end, UInt32(records.count - 1)))
            if let cut = cutLogsAfter {
                cutLogsAfter = nil
                seqs = Array(seqs.prefix(cut))
                dropLinkOnNextTick = true
            }
            return seqs.map { reply(UartMessageType.readLogs, .logRecord(probe: nil, records[Int($0)])) }
        case .setPrediction(let sp, let mode):
            setpoint = sp
            predictionMode = mode
            return [reply(UartMessageType.setPrediction)]
        case .setAlarms(let config):
            alarms = config
            return [reply(UartMessageType.setAlarms)]
        case .silenceAlarms:
            return [reply(UartMessageType.silenceAlarms)]
        case .readProbeFirmware, .readProbeHardware, .readProbeModel:
            return []
        }
    }
}
