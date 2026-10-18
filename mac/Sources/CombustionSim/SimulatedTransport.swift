import CombustionCore
import Foundation

public struct SimulatedWrite: Equatable, Sendable {
    public var peripheral: PeripheralId
    public var characteristic: GattUUID
    public var bytes: [UInt8]

    public init(peripheral: PeripheralId, characteristic: GattUUID, bytes: [UInt8]) {
        self.peripheral = peripheral
        self.characteristic = characteristic
        self.bytes = bytes
    }
}

/// In-memory `BleTransport` driven by a `Clock`. Confined by an internal lock
/// (a class rather than an actor so scripts can be synchronous and the
/// `BleTransport` stream properties stay non-async).
///
/// Behaviour notes:
/// - Advertisements are delivered only between `startScan()` and `stopScan()`.
/// - Leaving `.poweredOn` drops every connection with `.bluetoothOff` and stops scanning.
/// - Notifications are delivered only to connections that subscribed to the characteristic.
/// - Replies produced by responders / replayed responses are emitted synchronously
///   inside `write` unless a delay applies.
public final class SimulatedTransport: BleTransport, @unchecked Sendable {
    public typealias Responder = @Sendable (_ write: [UInt8]) -> [[UInt8]]

    public struct ReplayOptions: Sendable {
        /// Notifications on these characteristics that directly follow a recorded
        /// write (in file order) are treated as its responses, not as timeline events.
        public var responseChars: Set<GattUUID> = [.uartTX]
        /// Delay each replayed response by its recorded offset from the write.
        public var useRecordedResponseDelays = false
        public init() {}
    }

    private struct ResponderEntry {
        var peripheral: PeripheralId?
        var characteristic: GattUUID
        var replyOn: GattUUID
        var handler: Responder
    }

    private struct Fault {
        var characteristic: GattUUID?
        var remaining: Int
    }

    private struct RecordedResponse {
        var delay: Duration
        var characteristic: GattUUID
        var bytes: [UInt8]
    }

    private struct ReplayScript {
        var responses: [String: [[RecordedResponse]]] = [:]
        var served: [String: Int] = [:]
        var options: ReplayOptions
    }

    private let clock: any Clock
    private let lock = NSLock()
    private let stateBroadcast: Broadcaster<BluetoothState>
    private let advBroadcast = Broadcaster<RawAdvertisement>()

    private var currentState: BluetoothState
    private var scanning = false
    private var connections: [PeripheralId: SimulatedConnection] = [:]
    private var responders: [ResponderEntry] = []
    private var drops: [Fault] = []
    private var duplicates: [Fault] = []
    private var responseDelay: Duration = .zero
    private var connectDelay: Duration = .zero
    private var refusals = 0
    private var refusalError: TransportError?
    private var writeLog: [SimulatedWrite] = []
    private var readValues: [String: [UInt8]] = [:]
    private var matcher: any WriteMatcher
    private var script: ReplayScript?
    private var mtuValue = 185
    private var profile: [GattService] = [
        GattService(uuid: .probeStatusService, characteristics: [.probeStatus]),
        GattService(uuid: .uartService, characteristics: [.uartRX, .uartTX]),
        GattService(uuid: .deviceInformationService,
                    characteristics: [.manufacturerName, .modelNumber, .serialNumber, .hardwareRevision, .firmwareRevision]),
    ]

    public init(clock: any Clock, state: BluetoothState = .poweredOn, matcher: any WriteMatcher = MessageTypeWriteMatcher()) {
        self.clock = clock
        self.currentState = state
        self.matcher = matcher
        self.stateBroadcast = Broadcaster(initial: state, replayLatest: true)
    }

    // MARK: BleTransport

    public var state: AsyncStream<BluetoothState> { stateBroadcast.stream() }
    public var advertisements: AsyncStream<RawAdvertisement> { advBroadcast.stream() }

    public func startScan() async { lock.withLock { scanning = currentState == .poweredOn } }
    public func stopScan() async { lock.withLock { scanning = false } }

    public func connect(_ id: PeripheralId, timeout: Duration) async throws -> any GattConnection {
        let (delay, failure): (Duration, TransportError?) = lock.withLock {
            if currentState != .poweredOn { return (.zero, .notPoweredOn(currentState)) }
            if connections[id] != nil { return (.zero, .alreadyConnected(id)) }
            if refusals > 0 {
                refusals -= 1
                return (.zero, refusalError ?? .connectionRefused(id))
            }
            return (connectDelay, nil)
        }
        if let failure { throw failure }
        if delay > .zero {
            if delay > timeout {
                try await clock.sleep(for: timeout)
                throw TransportError.timeout
            }
            try await clock.sleep(for: delay)
        }
        return try lock.withLock {
            if currentState != .poweredOn { throw TransportError.notPoweredOn(currentState) }
            if connections[id] != nil { throw TransportError.alreadyConnected(id) }
            let c = SimulatedConnection(peripheral: id, transport: self, mtu: mtuValue)
            connections[id] = c
            return c
        }
    }

    // MARK: Scripting

    public func setState(_ new: BluetoothState) {
        let dropped: [SimulatedConnection] = lock.withLock {
            currentState = new
            guard new != .poweredOn else { return [] }
            scanning = false
            let all = Array(connections.values)
            connections.removeAll()
            return all
        }
        stateBroadcast.send(new)
        for c in dropped { c.terminate(.bluetoothOff) }
    }

    public func injectAdvertisement(peripheral: PeripheralId, mfrData: [UInt8], rssi: Int = -50) {
        guard lock.withLock({ scanning }) else { return }
        advBroadcast.send(RawAdvertisement(peripheral: peripheral, mfrData: mfrData, rssi: rssi, time: clock.now()))
    }

    /// Delivers a notification to subscribers of `characteristic` on `peripheral`
    /// (subject to drop/duplicate faults).
    public func injectNotification(peripheral: PeripheralId, characteristic: GattUUID, bytes: [UInt8]) {
        let (conn, copies): (SimulatedConnection?, Int) = lock.withLock {
            if let i = drops.firstIndex(where: { $0.characteristic == nil || $0.characteristic == characteristic }) {
                consume(&drops, at: i)
                return (nil, 0)
            }
            var copies = 1
            if let i = duplicates.firstIndex(where: { $0.characteristic == nil || $0.characteristic == characteristic }) {
                consume(&duplicates, at: i)
                copies = 2
            }
            return (connections[peripheral], copies)
        }
        for _ in 0..<copies { conn?.deliver(characteristic, bytes) }
    }

    public func forceDisconnect(_ peripheral: PeripheralId, reason: DisconnectReason = .linkLost) {
        let c = lock.withLock { connections.removeValue(forKey: peripheral) }
        c?.terminate(reason)
    }

    /// Answers writes to `characteristic` with notifications on `replyOn`, one per returned element.
    /// Responders are tried in registration order; the first registered for a matching write wins.
    public func addResponder(on characteristic: GattUUID = .uartRX, replyOn: GattUUID = .uartTX,
                             peripheral: PeripheralId? = nil, _ handler: @escaping Responder) {
        lock.withLock {
            responders.append(ResponderEntry(peripheral: peripheral, characteristic: characteristic,
                                             replyOn: replyOn, handler: handler))
        }
    }

    public func removeResponders() { lock.withLock { responders.removeAll() } }

    public func setReadValue(_ bytes: [UInt8], characteristic: GattUUID, peripheral: PeripheralId) {
        lock.withLock { readValues["\(peripheral)/\(characteristic)"] = bytes }
    }

    public func setMTU(_ mtu: Int) { lock.withLock { mtuValue = mtu } }
    public func setGattProfile(_ services: [GattService]) { lock.withLock { profile = services } }
    public func setWriteMatcher(_ m: any WriteMatcher) { lock.withLock { matcher = m } }

    /// Every write the app has made, in order.
    public var writes: [SimulatedWrite] { lock.withLock { writeLog } }

    // MARK: Faults

    /// Silently drops the next `count` notifications (optionally only on one characteristic).
    public func dropNextNotifications(_ count: Int = 1, on characteristic: GattUUID? = nil) {
        lock.withLock { drops.append(Fault(characteristic: characteristic, remaining: count)) }
    }

    /// Delivers each of the next `count` notifications twice.
    public func duplicateNextNotifications(_ count: Int = 1, on characteristic: GattUUID? = nil) {
        lock.withLock { duplicates.append(Fault(characteristic: characteristic, remaining: count)) }
    }

    /// Replies to writes arrive this long (on the clock) after the write.
    public func setResponseDelay(_ delay: Duration) { lock.withLock { responseDelay = delay } }

    /// `connect` takes this long; longer than its timeout throws `.timeout`.
    public func setConnectDelay(_ delay: Duration) { lock.withLock { connectDelay = delay } }

    /// The next `count` connects throw `error` (default `.connectionRefused`).
    public func refuseConnects(_ count: Int = 1, error: TransportError? = nil) {
        lock.withLock {
            refusals = count
            refusalError = error
        }
    }

    // MARK: Replay

    /// Plays `events` on the clock, with `t` relative to now. Recorded `write`
    /// events become the response table; `connect` events are informational.
    /// Cancel the returned task to stop. On a `TestClock`, call `advance`.
    @discardableResult
    public func startReplay(_ events: [ReplayEvent], options: ReplayOptions = ReplayOptions()) -> Task<Void, Never> {
        var table = ReplayScript(options: options)
        var timeline: [ReplayEvent] = []
        let m = lock.withLock { matcher }
        var lastWrite: (key: String, event: ReplayEvent, index: Int)?
        for event in events {
            switch event.type {
            case .write:
                let key = m.key(char: GattUUID(event.char ?? ""), bytes: event.bytes)
                table.responses[key, default: []].append([])
                lastWrite = (key, event, table.responses[key]!.count - 1)
            case .notify where lastWrite != nil && options.responseChars.contains(GattUUID(event.char ?? "")):
                let w = lastWrite!
                let r = RecordedResponse(delay: .seconds(max(0, event.t - w.event.t)),
                                         characteristic: GattUUID(event.char ?? ""), bytes: event.bytes)
                table.responses[w.key]![w.index].append(r)
            case .connect:
                lastWrite = nil
            default:
                lastWrite = nil
                timeline.append(event)
            }
        }
        lock.withLock { script = table }
        let origin = clock.monotonic()
        let clock = self.clock
        return Task { [weak self] in
            for event in timeline {
                let wait = origin + .seconds(event.t) - clock.monotonic()
                if wait > .zero {
                    do { try await clock.sleep(for: wait) } catch { return }
                }
                if Task.isCancelled { return }
                self?.play(event)
            }
        }
    }

    private func play(_ event: ReplayEvent) {
        let peripheral = PeripheralId(event.peripheral ?? "")
        switch event.type {
        case .adv: injectAdvertisement(peripheral: peripheral, mfrData: event.bytes, rssi: event.rssi ?? -50)
        case .notify: injectNotification(peripheral: peripheral, characteristic: GattUUID(event.char ?? ""), bytes: event.bytes)
        case .disconnect: forceDisconnect(peripheral)
        case .state: setState(event.state.flatMap(BluetoothState.init(rawValue:)) ?? .poweredOn)
        case .write, .connect: break
        }
    }

    // MARK: Internals used by SimulatedConnection

    private func consume(_ faults: inout [Fault], at i: Int) {
        faults[i].remaining -= 1
        if faults[i].remaining <= 0 { faults.remove(at: i) }
    }

    func connectionClosed(_ id: PeripheralId, _ connection: SimulatedConnection) {
        lock.withLock {
            if connections[id] === connection { connections.removeValue(forKey: id) }
        }
    }

    func readValue(peripheral: PeripheralId, characteristic: GattUUID) -> [UInt8]? {
        lock.withLock { readValues["\(peripheral)/\(characteristic)"] }
    }

    func gattProfile() -> [GattService] { lock.withLock { profile } }

    func handleWrite(peripheral: PeripheralId, characteristic: GattUUID, bytes: [UInt8]) {
        struct Reply { var delay: Duration; var characteristic: GattUUID; var bytes: [UInt8] }
        let replies: [Reply] = lock.withLock {
            writeLog.append(SimulatedWrite(peripheral: peripheral, characteristic: characteristic, bytes: bytes))
            let extra = responseDelay
            if let r = responders.first(where: {
                $0.characteristic == characteristic && ($0.peripheral == nil || $0.peripheral == peripheral)
            }) {
                return r.handler(bytes).map { Reply(delay: extra, characteristic: r.replyOn, bytes: $0) }
            }
            guard var s = script else { return [] }
            let key = matcher.key(char: characteristic, bytes: bytes)
            guard let recorded = s.responses[key], !recorded.isEmpty else { return [] }
            let n = s.served[key, default: 0]
            s.served[key] = n + 1
            script = s
            // Serve recordings in order; the last one repeats.
            return recorded[min(n, recorded.count - 1)].map {
                Reply(delay: extra + (s.options.useRecordedResponseDelays ? $0.delay : .zero),
                      characteristic: $0.characteristic, bytes: $0.bytes)
            }
        }
        guard !replies.isEmpty else { return }
        let immediate = replies.filter { $0.delay <= .zero }
        let later = replies.filter { $0.delay > .zero }
        for r in immediate { injectNotification(peripheral: peripheral, characteristic: r.characteristic, bytes: r.bytes) }
        guard !later.isEmpty else { return }
        let clock = self.clock
        Task { [weak self] in
            var elapsed = Duration.zero
            for r in later {
                if r.delay > elapsed {
                    do { try await clock.sleep(for: r.delay - elapsed) } catch { return }
                    elapsed = r.delay
                }
                self?.injectNotification(peripheral: peripheral, characteristic: r.characteristic, bytes: r.bytes)
            }
        }
    }
}

final class SimulatedConnection: GattConnection, @unchecked Sendable {
    let peripheral: PeripheralId
    let mtu: Int
    private weak var transport: SimulatedTransport?
    private let lock = NSLock()
    private var subscribers: [GattUUID: Broadcaster<[UInt8]>] = [:]
    private var open = true
    private let disconnectBroadcast = Broadcaster<DisconnectReason>(replayLatest: true)

    init(peripheral: PeripheralId, transport: SimulatedTransport, mtu: Int) {
        self.peripheral = peripheral
        self.transport = transport
        self.mtu = mtu
    }

    var disconnected: AsyncStream<DisconnectReason> { disconnectBroadcast.stream() }

    private func requireOpen() throws {
        guard lock.withLock({ open }) else { throw TransportError.disconnected }
    }

    func discover() async throws -> [GattService] {
        try requireOpen()
        return transport?.gattProfile() ?? []
    }

    func read(_ characteristic: GattUUID) async throws -> [UInt8] {
        try requireOpen()
        guard let v = transport?.readValue(peripheral: peripheral, characteristic: characteristic) else {
            throw TransportError.characteristicNotFound(characteristic)
        }
        return v
    }

    func write(_ characteristic: GattUUID, _ bytes: [UInt8], withResponse: Bool) async throws {
        try requireOpen()
        transport?.handleWrite(peripheral: peripheral, characteristic: characteristic, bytes: bytes)
    }

    func subscribe(_ characteristic: GattUUID) async throws -> AsyncStream<[UInt8]> {
        try requireOpen()
        return lock.withLock {
            if subscribers[characteristic] == nil { subscribers[characteristic] = Broadcaster() }
            return subscribers[characteristic]!.stream()
        }
    }

    func deliver(_ characteristic: GattUUID, _ bytes: [UInt8]) {
        let b = lock.withLock { open ? subscribers[characteristic] : nil }
        b?.send(bytes)
    }

    func close() async {
        transport?.connectionClosed(peripheral, self)
        terminate(.requested)
    }

    func terminate(_ reason: DisconnectReason) {
        let all: [Broadcaster<[UInt8]>]? = lock.withLock {
            guard open else { return nil }
            open = false
            return Array(subscribers.values)
        }
        guard let all else { return }
        for b in all { b.finish() }
        disconnectBroadcast.send(reason)
        disconnectBroadcast.finish()
    }
}
