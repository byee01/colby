import CombustionCore
import Foundation

/// Decorator that writes every event crossing the transport to a `ReplayWriter` (docs/02 §16).
/// Events are recorded before they are handed to the consumer, so once a consumer
/// has seen an event it is already in the file.
///
/// It consumes the inner `state` and `advertisements` streams itself (from `init`)
/// and re-broadcasts them. Call `stop()` to end recording and close the file.
public final class RecordingTransport: BleTransport, @unchecked Sendable {
    private let inner: any BleTransport
    private let recorder: Recorder
    private let stateBroadcast = Broadcaster<BluetoothState>(replayLatest: true)
    private let advBroadcast = Broadcaster<RawAdvertisement>()
    private var tasks: [Task<Void, Never>] = []

    public init(inner: any BleTransport, writer: ReplayWriter, clock: any Clock) {
        self.inner = inner
        self.recorder = Recorder(writer: writer, clock: clock)
        let innerState = inner.state
        let innerAdv = inner.advertisements
        let recorder = self.recorder
        let stateOut = stateBroadcast
        let advOut = advBroadcast
        tasks = [
            Task {
                for await s in innerState {
                    recorder.record(.state, state: s.rawValue)
                    stateOut.send(s)
                }
                stateOut.finish()
            },
            Task {
                for await a in innerAdv {
                    recorder.record(.adv, peripheral: a.peripheral, hex: HexString.encode(a.mfrData), rssi: a.rssi)
                    advOut.send(a)
                }
                advOut.finish()
            },
        ]
    }

    public var state: AsyncStream<BluetoothState> { stateBroadcast.stream() }
    public var advertisements: AsyncStream<RawAdvertisement> { advBroadcast.stream() }

    public func startScan() async { await inner.startScan() }
    public func stopScan() async { await inner.stopScan() }

    public func connect(_ id: PeripheralId, timeout: Duration) async throws -> any GattConnection {
        let c = try await inner.connect(id, timeout: timeout)
        recorder.record(.connect, peripheral: id)
        return RecordingConnection(inner: c, recorder: recorder)
    }

    public func stop() {
        for t in tasks { t.cancel() }
        recorder.writer.close()
    }
}

final class Recorder: @unchecked Sendable {
    let writer: ReplayWriter
    private let clock: any Clock
    private let origin: Duration

    init(writer: ReplayWriter, clock: any Clock) {
        self.writer = writer
        self.clock = clock
        self.origin = clock.monotonic()
    }

    func record(_ type: ReplayEvent.Kind, peripheral: PeripheralId? = nil, char: GattUUID? = nil,
                hex: String? = nil, rssi: Int? = nil, state: String? = nil) {
        writer.append(ReplayEvent(t: (clock.monotonic() - origin).totalSeconds, type: type,
                                  peripheral: peripheral?.rawValue, char: char?.rawValue,
                                  hex: hex, rssi: rssi, state: state))
    }
}

final class RecordingConnection: GattConnection, @unchecked Sendable {
    private let inner: any GattConnection
    private let recorder: Recorder
    private let lock = NSLock()
    private var recordedDisconnect = false
    private let disconnectOut = Broadcaster<DisconnectReason>(replayLatest: true)

    var peripheral: PeripheralId { inner.peripheral }
    var mtu: Int { inner.mtu }
    var disconnected: AsyncStream<DisconnectReason> { disconnectOut.stream() }

    init(inner: any GattConnection, recorder: Recorder) {
        self.inner = inner
        self.recorder = recorder
        let innerDisc = inner.disconnected
        let out = disconnectOut
        let id = inner.peripheral
        Task { [weak self] in
            for await reason in innerDisc {
                self?.recordDisconnectOnce(id)
                out.send(reason)
            }
            out.finish()
        }
    }

    private func recordDisconnectOnce(_ id: PeripheralId) {
        let first = lock.withLock {
            defer { recordedDisconnect = true }
            return !recordedDisconnect
        }
        if first { recorder.record(.disconnect, peripheral: id) }
    }

    func discover() async throws -> [GattService] { try await inner.discover() }
    func read(_ characteristic: GattUUID) async throws -> [UInt8] { try await inner.read(characteristic) }

    func write(_ characteristic: GattUUID, _ bytes: [UInt8], withResponse: Bool) async throws {
        recorder.record(.write, peripheral: peripheral, char: characteristic, hex: HexString.encode(bytes))
        try await inner.write(characteristic, bytes, withResponse: withResponse)
    }

    func subscribe(_ characteristic: GattUUID) async throws -> AsyncStream<[UInt8]> {
        let source = try await inner.subscribe(characteristic)
        let recorder = self.recorder
        let id = peripheral
        let (stream, continuation) = AsyncStream<[UInt8]>.makeStream()
        let task = Task {
            for await bytes in source {
                recorder.record(.notify, peripheral: id, char: characteristic, hex: HexString.encode(bytes))
                continuation.yield(bytes)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    func close() async {
        await inner.close()
        recordDisconnectOnce(peripheral)
    }
}
