#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import CombustionCore
import Foundation

/// `GattConnection` over a connected `CBPeripheral`.
///
/// Concurrency: the peripheral and every piece of mutable state here are
/// touched only on `queue` (the transport's serial queue, which is also the
/// delegate queue), hence `@unchecked Sendable`. Public async methods hop onto
/// the queue with continuations.
///
/// Serialization: discover, read, write-with-response and subscribe run one at
/// a time through a FIFO gate (`acquire`/`release`), so each CoreBluetooth
/// callback maps to exactly one waiter. Write-without-response does not take
/// the gate; it waits on `canSendWriteWithoutResponse` in FIFO order.
/// `discover()` must complete before the other calls (characteristics are
/// looked up by UUID from its result). Operations have no timeout of their own
/// (callers such as UartClient time out); all of them fail with
/// `.disconnected` when the link goes down.
///
/// A value delivered by `didUpdateValueFor` completes a pending read of that
/// characteristic and is also yielded to its subscriber, so a real
/// notification racing a read is never dropped.
public final class CoreBluetoothGattConnection: NSObject, GattConnection, CBPeripheralDelegate, @unchecked Sendable {
    public let peripheral: PeripheralId
    public let mtu: Int

    private let queue: DispatchQueue
    private let cbPeripheral: CBPeripheral
    private let central: CBCentralManager
    private let onTerminated: @Sendable (CoreBluetoothGattConnection) -> Void
    private let disconnectBroadcast = Broadcaster<DisconnectReason>(initial: nil, replayLatest: true)

    private struct Subscription {
        var token: UUID
        var continuation: AsyncStream<[UInt8]>.Continuation
    }

    private struct DiscoverState {
        var continuation: CheckedContinuation<[GattService], any Error>
        var remaining = 0
        var services: [GattService] = []
        var firstError: String?
    }

    private struct PendingWriteWithoutResponse {
        var characteristic: CBCharacteristic
        var data: Data
        var continuation: CheckedContinuation<Void, any Error>
    }

    // Everything below: touched only on `queue`.
    private var terminated = false
    private var characteristics: [GattUUID: CBCharacteristic] = [:]
    private var gateBusy = false
    private var gateWaiters: [CheckedContinuation<Void, any Error>] = []
    private var discoverState: DiscoverState?
    private var pendingReads: [GattUUID: CheckedContinuation<[UInt8], any Error>] = [:]
    private var pendingWrites: [GattUUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingNotify: [GattUUID: CheckedContinuation<Void, any Error>] = [:]
    private var pendingWWR: [PendingWriteWithoutResponse] = []
    private var subscriptions: [GattUUID: Subscription] = [:]

    /// Must be called on `queue` (from the central's didConnect callback).
    init(id: PeripheralId, peripheral: CBPeripheral, central: CBCentralManager, queue: DispatchQueue,
         onTerminated: @escaping @Sendable (CoreBluetoothGattConnection) -> Void) {
        self.peripheral = id
        self.cbPeripheral = peripheral
        self.central = central
        self.queue = queue
        self.onTerminated = onTerminated
        // ATT header is 3 bytes; maximumWriteValueLength is the usable payload.
        self.mtu = peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
        super.init()
        peripheral.delegate = self  // weak in CoreBluetooth; the transport retains us
    }

    // MARK: GattConnection

    public var disconnected: AsyncStream<DisconnectReason> { disconnectBroadcast.stream() }

    public func discover() async throws -> [GattService] {
        try await acquire()
        defer { release() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[GattService], any Error>) in
            queue.async {
                if self.terminated { c.resume(throwing: TransportError.disconnected); return }
                self.discoverState = DiscoverState(continuation: c)
                self.cbPeripheral.discoverServices(nil)
            }
        }
    }

    public func read(_ characteristic: GattUUID) async throws -> [UInt8] {
        try await acquire()
        defer { release() }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<[UInt8], any Error>) in
            queue.async {
                if self.terminated { c.resume(throwing: TransportError.disconnected); return }
                guard let ch = self.characteristics[characteristic] else {
                    c.resume(throwing: TransportError.characteristicNotFound(characteristic)); return
                }
                self.pendingReads[characteristic] = c
                self.cbPeripheral.readValue(for: ch)
            }
        }
    }

    public func write(_ characteristic: GattUUID, _ bytes: [UInt8], withResponse: Bool) async throws {
        if withResponse {
            try await acquire()
            defer { release() }
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                queue.async {
                    if self.terminated { c.resume(throwing: TransportError.disconnected); return }
                    guard let ch = self.characteristics[characteristic] else {
                        c.resume(throwing: TransportError.characteristicNotFound(characteristic)); return
                    }
                    self.pendingWrites[characteristic] = c
                    self.cbPeripheral.writeValue(Data(bytes), for: ch, type: .withResponse)
                }
            }
        } else {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                queue.async {
                    if self.terminated { c.resume(throwing: TransportError.disconnected); return }
                    guard let ch = self.characteristics[characteristic] else {
                        c.resume(throwing: TransportError.characteristicNotFound(characteristic)); return
                    }
                    guard ch.properties.contains(.writeWithoutResponse) else {
                        c.resume(throwing: TransportError.operationFailed(
                            "\(characteristic) does not support write without response")); return
                    }
                    self.pendingWWR.append(PendingWriteWithoutResponse(
                        characteristic: ch, data: Data(bytes), continuation: c))
                    self.pumpWriteWithoutResponse()
                }
            }
        }
    }

    public func subscribe(_ characteristic: GattUUID) async throws -> AsyncStream<[UInt8]> {
        try await acquire()
        defer { release() }
        let token = UUID()
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        continuation.onTermination = { [weak self] _ in
            // Consumer stopped iterating: turn notifications off (unless already
            // disconnected or replaced by a newer subscription).
            self?.queue.async {
                guard let self, !self.terminated,
                      self.subscriptions[characteristic]?.token == token else { return }
                self.subscriptions[characteristic] = nil
                if let ch = self.characteristics[characteristic] {
                    self.cbPeripheral.setNotifyValue(false, for: ch)
                }
            }
        }
        do {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                queue.async {
                    if self.terminated { c.resume(throwing: TransportError.disconnected); return }
                    guard let ch = self.characteristics[characteristic] else {
                        c.resume(throwing: TransportError.characteristicNotFound(characteristic)); return
                    }
                    // Register before enabling so the first notification is not missed.
                    // A previous subscriber (if any) is finished; its token no longer
                    // matches, so its termination does not disable notifications.
                    self.subscriptions[characteristic]?.continuation.finish()
                    self.subscriptions[characteristic] = Subscription(token: token, continuation: continuation)
                    self.pendingNotify[characteristic] = c
                    self.cbPeripheral.setNotifyValue(true, for: ch)
                }
            }
        } catch {
            queue.async {
                if self.subscriptions[characteristic]?.token == token { self.subscriptions[characteristic] = nil }
            }
            continuation.finish()
            throw error
        }
        return stream
    }

    public func close() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if !self.terminated {
                    self.central.cancelPeripheralConnection(self.cbPeripheral)
                    self.terminate(.requested)
                }
                c.resume()
            }
        }
    }

    // MARK: Gate (FIFO mutual exclusion for request/response operations)

    private func acquire() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            queue.async {
                if self.terminated {
                    c.resume(throwing: TransportError.disconnected)
                } else if !self.gateBusy {
                    self.gateBusy = true
                    c.resume()
                } else {
                    self.gateWaiters.append(c)
                }
            }
        }
    }

    private func release() {
        queue.async {
            if self.gateWaiters.isEmpty {
                self.gateBusy = false
            } else {
                self.gateWaiters.removeFirst().resume()  // gate stays busy, handed over
            }
        }
    }

    // MARK: Queue-confined helpers

    private func pumpWriteWithoutResponse() {
        while let next = pendingWWR.first, cbPeripheral.canSendWriteWithoutResponse {
            pendingWWR.removeFirst()
            cbPeripheral.writeValue(next.data, for: next.characteristic, type: .withoutResponse)
            next.continuation.resume()
        }
    }

    /// Ends the connection (idempotent). Must be called on `queue`.
    func terminate(_ reason: DisconnectReason) {
        guard !terminated else { return }
        terminated = true
        let error = TransportError.disconnected
        discoverState?.continuation.resume(throwing: error)
        discoverState = nil
        for c in pendingReads.values { c.resume(throwing: error) }
        pendingReads.removeAll()
        for c in pendingWrites.values { c.resume(throwing: error) }
        pendingWrites.removeAll()
        for c in pendingNotify.values { c.resume(throwing: error) }
        pendingNotify.removeAll()
        for w in pendingWWR { w.continuation.resume(throwing: error) }
        pendingWWR.removeAll()
        for w in gateWaiters { w.resume(throwing: error) }
        gateWaiters.removeAll()
        gateBusy = false
        let subs = Array(subscriptions.values)
        subscriptions.removeAll()
        for s in subs { s.continuation.finish() }
        disconnectBroadcast.send(reason)
        disconnectBroadcast.finish()
        onTerminated(self)
    }

    // MARK: CBPeripheralDelegate (all called on `queue`)

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard var state = discoverState else { return }
        if let error {
            discoverState = nil
            state.continuation.resume(throwing: TransportError.operationFailed("service discovery: \(error.localizedDescription)"))
            return
        }
        let services = peripheral.services ?? []
        if services.isEmpty {
            discoverState = nil
            state.continuation.resume(returning: [])
            return
        }
        state.remaining = services.count
        discoverState = state
        for s in services { peripheral.discoverCharacteristics(nil, for: s) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        guard var state = discoverState else { return }
        let found = service.characteristics ?? []
        for ch in found { characteristics[ch.uuid.gattUUID] = ch }
        state.services.append(GattService(uuid: service.uuid.gattUUID, characteristics: found.map { $0.uuid.gattUUID }))
        if let error, state.firstError == nil { state.firstError = error.localizedDescription }
        state.remaining -= 1
        if state.remaining > 0 {
            discoverState = state
            return
        }
        discoverState = nil
        if let message = state.firstError {
            state.continuation.resume(throwing: TransportError.operationFailed("characteristic discovery: \(message)"))
        } else {
            state.continuation.resume(returning: state.services)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let uuid = characteristic.uuid.gattUUID
        if let error {
            pendingReads.removeValue(forKey: uuid)?.resume(
                throwing: TransportError.operationFailed("read \(uuid): \(error.localizedDescription)"))
            return
        }
        let bytes = [UInt8](characteristic.value ?? Data())
        pendingReads.removeValue(forKey: uuid)?.resume(returning: bytes)
        subscriptions[uuid]?.continuation.yield(bytes)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        let uuid = characteristic.uuid.gattUUID
        guard let c = pendingWrites.removeValue(forKey: uuid) else { return }
        if let error {
            c.resume(throwing: TransportError.operationFailed("write \(uuid): \(error.localizedDescription)"))
        } else {
            c.resume()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: (any Error)?) {
        let uuid = characteristic.uuid.gattUUID
        guard let c = pendingNotify.removeValue(forKey: uuid) else { return }
        if let error {
            c.resume(throwing: TransportError.operationFailed("subscribe \(uuid): \(error.localizedDescription)"))
        } else {
            c.resume()
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpWriteWithoutResponse()
    }
}
#endif
