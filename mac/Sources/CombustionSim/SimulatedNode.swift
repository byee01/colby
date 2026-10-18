import CombustionCodec
import CombustionCore
import Foundation

/// A virtual MeatNet node (Display, Booster, ...) on top of `SimulatedTransport`, driven by a `Clock`.
///
/// It relays `SimulatedProbe`s the way a node on the repeater network would, independent of whether the
/// Mac can hear those probes directly:
/// - Every 250 ms it advertises itself, plus one repeated-probe advertisement per relayed probe.
/// - When a relayed probe makes a log record and the app is connected to the node, it sends a `0x45`
///   Probe Status for it. Every second it sends a `0x49` heartbeat.
/// - It answers node-variant UART requests: Read Logs and Read Session Information from the probe's log,
///   the probe Device Information reads, and (forwarded to the probe) prediction, alarms and silence.
///
/// Controls: `relay` / `stopRelaying` (a probe joins or leaves the node's network), `setInRange`
/// (out of range: no advertisements, the connection drops with `.linkLost`, connects are refused).
///
/// Lock order: the transport calls responders while holding its lock, so this class never calls the
/// transport while holding its own lock.
public final class SimulatedNode: @unchecked Sendable {
    public static let advertisementPeriod: Duration = .milliseconds(250)
    public static let heartbeatEvery = 4 // advertisement periods

    public let serial: NodeSerial
    public let productType: NodeProductType
    public let peripheral: PeripheralId

    private let transport: SimulatedTransport
    private let clock: any Clock

    private struct Relayed {
        var probe: SimulatedProbe
        var hops: Int
    }

    private let lock = NSLock()
    private var relayed: [ProbeSerial: Relayed] = [:]
    private var inRange = true
    private var running = false
    private var ticks = 0
    private var nextResponseId: UInt32 = 5000
    private var received: [(probe: ProbeSerial?, request: UartRequest)] = []
    private var heartbeats = 0
    private var task: Task<Void, Never>?

    public init(
        serial: NodeSerial, productType: NodeProductType = .display, transport: SimulatedTransport,
        clock: any Clock, peripheral: PeripheralId? = nil
    ) {
        self.serial = serial
        self.productType = productType
        self.transport = transport
        self.clock = clock
        self.peripheral = peripheral ?? PeripheralId("NODE-\(serial)")
    }

    deinit { task?.cancel() }

    // MARK: Lifecycle

    /// Registers the UART responder and starts advertising on the clock. Idempotent.
    public func start() {
        let shouldStart: Bool = lock.withLock {
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }
        transport.addResponder(peripheral: peripheral) { [weak self] bytes in self?.respond(bytes) ?? [] }
        let ticks = clock.timer(every: Self.advertisementPeriod)
        task = Task { [weak self] in
            for await _ in ticks {
                guard let self else { return }
                self.tick()
            }
        }
    }

    public func stop() {
        lock.withLock { running = false }
        task?.cancel()
        task = nil
    }

    // MARK: Controls

    /// The probe joins the node's network, `hops` repeater hops (1...4) away.
    public func relay(_ probe: SimulatedProbe, hops: Int = 1) {
        let first: Bool = lock.withLock {
            let first = relayed[probe.serial] == nil
            relayed[probe.serial] = Relayed(probe: probe, hops: hops)
            return first
        }
        if first { probe.onSample { [weak self] in self?.sampled(probe.serial) } }
    }

    public func stopRelaying(_ probe: SimulatedProbe) {
        lock.withLock { _ = relayed.removeValue(forKey: probe.serial) }
    }

    public var isInRange: Bool { lock.withLock { inRange } }

    /// Out of range: no advertisements, the open connection drops with `.linkLost`, connects are refused.
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

    /// Strings the app reads from the node's Device Information service.
    public func setDeviceInfo(_ info: DeviceInfo) {
        for (uuid, text) in [(GattUUID.firmwareRevision, info.firmware), (.hardwareRevision, info.hardware),
                             (.modelNumber, info.model)] {
            if let text { transport.setReadValue(Array(text.utf8), characteristic: uuid, peripheral: peripheral) }
        }
    }

    // MARK: Observation

    /// Every request answered (or refused), in order, with the probe it named.
    public var requests: [(probe: ProbeSerial?, request: UartRequest)] { lock.withLock { received } }
    public var heartbeatsSent: Int { lock.withLock { heartbeats } }

    // MARK: Internals

    private func tick() {
        struct Work {
            var ads: [[UInt8]]
            var heartbeat: [UInt8]?
        }
        let work: Work? = lock.withLock {
            guard running, inRange else { return nil }
            ticks += 1
            var ads: [[UInt8]] = []
            if let own = try? encodeAdvertisement(.node(NodeAdvertisement(productType: productType, serial: serial))) {
                ads.append(own)
            }
            for r in relayed.values {
                if let ad = try? encodeAdvertisement(.repeated(r.probe.currentAdvertisement, hopCount: r.hops)) {
                    ads.append(ad)
                }
            }
            var beat: [UInt8]?
            if ticks % Self.heartbeatEvery == 0 {
                heartbeats += 1
                var payload = Array(serial.utf8.prefix(10))
                payload += [UInt8](repeating: 0, count: 10 - payload.count)
                beat = try? UartFrame(variant: .node, direction: .request, messageType: UartMessageType.heartbeat,
                                      requestId: 0, payload: payload).encoded()
            }
            return Work(ads: ads, heartbeat: beat)
        }
        guard let work else { return }
        for ad in work.ads { transport.injectAdvertisement(peripheral: peripheral, mfrData: ad) }
        if let beat = work.heartbeat, transport.isConnected(peripheral) {
            transport.injectNotification(peripheral: peripheral, characteristic: .uartTX, bytes: beat)
        }
    }

    /// A relayed probe made a record: push its status to the connected app.
    private func sampled(_ probeSerial: ProbeSerial) {
        let (relay, live): (Relayed?, Bool) = lock.withLock { (relayed[probeSerial], running && inRange) }
        guard live, let relay, transport.isConnected(peripheral) else { return }
        let probe = relay.probe
        let layout: StatusLayout = probe.isLegacyLayout ? .legacy : .current
        guard let payload = try? encodeNodeProbeStatus(
            NodeProbeStatus(serial: probeSerial, status: probe.currentStatus, hopCount: relay.hops), layout: layout),
              let frame = try? UartFrame(variant: .node, direction: .request, messageType: UartMessageType.probeStatus,
                                         requestId: 0, payload: payload).encoded() else { return }
        transport.injectNotification(peripheral: peripheral, characteristic: .uartTX, bytes: frame)
    }

    /// Answers one RX write. Called by the transport (under its lock), so nothing here touches the transport.
    private func respond(_ bytes: [UInt8]) -> [[UInt8]] {
        var framer = UartFramer(variant: .node, direction: .request)
        var out: [[UInt8]] = []
        for case .frame(let frame) in framer.push(bytes) {
            guard let message = try? decodeRequest(frame), let requestId = message.requestId else { continue }
            out += answer(message, requestId: requestId)
        }
        return out
    }

    private func answer(_ message: UartRequestMessage, requestId: UInt32) -> [[UInt8]] {
        let type = message.request.messageType
        let (relay, responseIds): (Relayed?, ClosedRange<UInt32>) = lock.withLock {
            received.append((message.probe, message.request))
            let base = nextResponseId
            nextResponseId &+= 300 // room for a whole log read
            return (message.probe.flatMap { relayed[$0] }, base...(base &+ 299))
        }
        var ids = responseIds.makeIterator()
        func reply(success: Bool = true, _ body: UartResponse.Body = .ack) -> [UInt8] {
            let response = UartResponse(
                messageType: type, success: success, requestId: requestId, responseId: ids.next() ?? 0, body: body)
            return (try? encodeResponse(response, variant: .node)) ?? []
        }
        // Global silence names no probe; everything else needs a probe on this node's network.
        if case .silenceAlarms = message.request, message.probe == nil { return [reply()] }
        guard let probe = message.probe, let relay else { return [reply(success: false)] }
        let source = relay.probe

        switch message.request {
        case .readSessionInfo:
            if source.isLegacyLayout { return [reply(success: false)] }
            let info = SessionInfo(sessionId: source.sessionId, samplePeriodMs: UInt16(source.samplePeriod.totalSeconds * 1000))
            return [reply(.sessionInfo(probe: probe, info))]
        case .readLogs(let start, let end):
            let count = source.recordCount
            guard start <= end, Int(start) < count else { return [] }
            return (start...min(end, UInt32(count - 1))).compactMap { seq in
                source.record(seq).map { reply(.logRecord(probe: probe, $0)) }
            }
        case .setPrediction, .setAlarms, .silenceAlarms:
            source.applyRelayed(message.request)
            return [reply()]
        case .readProbeFirmware:
            return [reply(.revision(probe: probe, kind: .firmware, text: "v1.2.3"))]
        case .readProbeHardware:
            return [reply(.revision(probe: probe, kind: .hardware, text: "HW-A"))]
        case .readProbeModel:
            return [reply(.revision(probe: probe, kind: .model, text: "Predictive Probe"))]
        }
    }
}
