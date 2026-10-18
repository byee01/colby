#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
import CombustionCore
import Foundation

/// macOS `BleTransport` on CoreBluetooth (docs/02 §5.1).
///
/// Concurrency: every CoreBluetooth object (the central, peripherals,
/// characteristics) is created, used and destroyed only on `queue`, a
/// dedicated serial DispatchQueue that is also the delegate queue. All mutable
/// state in this class is read and written only on `queue`, which is why the
/// `@unchecked Sendable` is sound. Async entry points hop onto the queue with
/// continuations; results come back through streams (`Broadcaster`).
///
/// Semantics mirror `SimulatedTransport`:
/// - Advertisements are delivered only between `startScan()` and `stopScan()`.
/// - Leaving `.poweredOn` stops scanning (it is NOT resumed automatically),
///   drops every connection with `.bluetoothOff` and fails pending connects.
/// - A second `connect` to an already connected (or connecting) peripheral
///   throws `.alreadyConnected`.
///
/// Manufacturer data: `RawAdvertisement.mfrData` includes the 2-byte company
/// ID (C7 09), exactly as CoreBluetooth's `CBAdvertisementDataManufacturerDataKey`
/// delivers it, and as `decodeAdvertisement` in CombustionCodec expects.
///
/// State mapping: poweredOn/poweredOff/unauthorized/unsupported map directly.
/// `.resetting` is reported as `.poweredOff` (all connections are lost and
/// the radio comes back with a fresh state callback). `.unknown` (the initial
/// state before the first callback) is not published, so `state` yields
/// nothing until the system knows; if it occurs after poweredOn the
/// connections are dropped as for any other non-poweredOn state.
public final class CoreBluetoothTransport: NSObject, BleTransport, CBCentralManagerDelegate, @unchecked Sendable {
    private struct PendingConnect {
        var token: UUID
        var continuation: CheckedContinuation<CoreBluetoothGattConnection, any Error>
    }

    private let clock: any Clock
    private let queue = DispatchQueue(label: "colby.CoreBluetoothTransport")
    private let stateBroadcast = Broadcaster<BluetoothState>(initial: nil, replayLatest: true)
    private let advBroadcast = Broadcaster<RawAdvertisement>()

    // Everything below: touched only on `queue`.
    private var central: CBCentralManager!
    private var lastState: BluetoothState?
    private var scanning = false
    private var peripherals: [PeripheralId: CBPeripheral] = [:]
    private var pending: [PeripheralId: PendingConnect] = [:]
    private var connections: [PeripheralId: CoreBluetoothGattConnection] = [:]

    public init(clock: any Clock) {
        self.clock = clock
        super.init()
        // Created on the queue so no delegate callback can observe `central` unset.
        queue.sync {
            self.central = CBCentralManager(delegate: self, queue: self.queue, options: nil)
        }
    }

    // MARK: BleTransport

    public var state: AsyncStream<BluetoothState> { stateBroadcast.stream() }
    public var advertisements: AsyncStream<RawAdvertisement> { advBroadcast.stream() }

    public func startScan() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.central.state == .poweredOn && !self.scanning {
                    self.scanning = true
                    self.central.scanForPeripherals(
                        withServices: nil,
                        options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
                }
                c.resume()
            }
        }
    }

    public func stopScan() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                if self.scanning {
                    self.scanning = false
                    self.central.stopScan()
                }
                c.resume()
            }
        }
    }

    public func connect(_ id: PeripheralId, timeout: Duration) async throws -> any GattConnection {
        let token = UUID()
        let clock = self.clock
        // The timeout races the didConnect callback; whichever reaches the queue
        // first wins (the loser finds no matching pending entry and does nothing).
        let timeoutTask = Task { [weak self] in
            do { try await clock.sleep(for: timeout) } catch { return }
            self?.queue.async { self?.failPending(id, token: token, with: TransportError.timeout) }
        }
        defer { timeoutTask.cancel() }
        let connection: CoreBluetoothGattConnection = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<CoreBluetoothGattConnection, any Error>) in
                queue.async { self.beginConnect(id, token: token, continuation: c) }
            }
        } onCancel: {
            queue.async { self.failPending(id, token: token, with: CancellationError()) }
        }
        return connection
    }

    // MARK: Queue-confined helpers

    private func beginConnect(_ id: PeripheralId, token: UUID,
                              continuation: CheckedContinuation<CoreBluetoothGattConnection, any Error>) {
        guard central.state == .poweredOn else {
            continuation.resume(throwing: TransportError.notPoweredOn(Self.map(central.state) ?? .poweredOff))
            return
        }
        if connections[id] != nil || pending[id] != nil {
            continuation.resume(throwing: TransportError.alreadyConnected(id))
            return
        }
        var target = peripherals[id]
        if target == nil, let uuid = UUID(uuidString: id.rawValue) {
            target = central.retrievePeripherals(withIdentifiers: [uuid]).first
            if let target { peripherals[id] = target }
        }
        guard let target else {
            continuation.resume(throwing: TransportError.connectionRefused(id))
            return
        }
        pending[id] = PendingConnect(token: token, continuation: continuation)
        central.connect(target, options: nil)
    }

    /// Fails the pending connect if `token` still owns it, and cancels the link attempt.
    private func failPending(_ id: PeripheralId, token: UUID, with error: any Error) {
        guard let p = pending[id], p.token == token else { return }
        pending[id] = nil
        if let peripheral = peripherals[id] { central.cancelPeripheralConnection(peripheral) }
        p.continuation.resume(throwing: error)
    }

    private static func map(_ s: CBManagerState) -> BluetoothState? {
        switch s {
        case .poweredOn: return .poweredOn
        case .poweredOff: return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported: return .unsupported
        case .resetting: return .poweredOff
        case .unknown: return nil
        @unknown default: return nil
        }
    }

    // MARK: CBCentralManagerDelegate (all called on `queue`)

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let mapped = Self.map(central.state)
        if central.state != .poweredOn {
            scanning = false
            let dropped = Array(connections.values)
            connections.removeAll()
            let failed = pending
            pending.removeAll()
            for p in failed.values {
                p.continuation.resume(throwing: TransportError.notPoweredOn(mapped ?? .poweredOff))
            }
            for c in dropped { c.terminate(.bluetoothOff) }
        }
        if let mapped, mapped != lastState {
            lastState = mapped
            stateBroadcast.send(mapped)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard scanning,
              let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              data.count >= 2, data[data.startIndex] == 0xC7, data[data.startIndex + 1] == 0x09
        else { return }
        let rssi = RSSI.intValue
        guard rssi != 127 else { return }  // 127 = "RSSI not available"
        let id = PeripheralId(peripheral.identifier.uuidString)
        peripherals[id] = peripheral  // CBPeripheral must be retained by us to be connectable
        advBroadcast.send(RawAdvertisement(peripheral: id, mfrData: [UInt8](data), rssi: rssi, time: clock.now()))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = PeripheralId(peripheral.identifier.uuidString)
        guard let p = pending.removeValue(forKey: id) else {
            // Connected after a timeout/cancel already gave up: undo it.
            central.cancelPeripheralConnection(peripheral)
            return
        }
        let connection = CoreBluetoothGattConnection(
            id: id, peripheral: peripheral, central: central, queue: queue,
            onTerminated: { [weak self] conn in
                if self?.connections[conn.peripheral] === conn { self?.connections[conn.peripheral] = nil }
            })
        connections[id] = connection
        p.continuation.resume(returning: connection)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        let id = PeripheralId(peripheral.identifier.uuidString)
        guard let p = pending.removeValue(forKey: id) else { return }
        p.continuation.resume(throwing: TransportError.connectionRefused(id))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        let id = PeripheralId(peripheral.identifier.uuidString)
        if let p = pending.removeValue(forKey: id) {
            p.continuation.resume(throwing: TransportError.connectionRefused(id))
        }
        // Local close() terminates (and unregisters) the connection first, so a
        // callback that finds a live connection here is a remote/link-level drop.
        guard let conn = connections[id] else { return }
        let reason: DisconnectReason = (error as? CBError)?.code == .connectionTimeout ? .timeout : .linkLost
        conn.terminate(reason)
    }
}
#endif
