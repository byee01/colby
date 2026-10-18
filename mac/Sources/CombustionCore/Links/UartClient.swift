import CombustionCodec
import Foundation

/// Failures of a UART request (docs/02 §5.5).
public enum UartError: Error, Sendable, Equatable {
    /// No response within the timeout, retries exhausted (or, for `readLogs`, nothing at all arrived).
    case timeout
    /// The device answered with `success = 0`.
    case failure
    /// The connection went away (or the client was closed / never started).
    case disconnected
    /// A response arrived that the codec could not decode.
    case codec(CodecError)
    /// Probe variant: a request of the same message type is already in flight.
    case busy
}

/// Counters for the diagnostics screen. Nothing here is thrown.
public struct UartDiagnostics: Sendable, Equatable {
    /// Garbage bytes skipped or frames with a bad CRC.
    public var framingErrors = 0
    /// Response frames that matched no in-flight request (late, mismatched ID, or wrong type).
    public var ignoredFrames = 0
    /// Node responses dropped because their Response ID was already seen.
    public var duplicateResponses = 0
    /// Frames that matched a request but failed to decode (the request fails with `.codec`).
    public var codecErrors = 0
    public init() {}
}

/// UART framing, request/response correlation and timeouts over a Nordic UART connection.
/// docs/02 §5.3, §5.4, §5.5.
///
/// - Probe variant: no request IDs. One in-flight request per message type, matched by type;
///   a second request of the same type throws `.busy`.
/// - Node variant: a random u32 request ID per request, matched on Request ID. Duplicate Response IDs
///   (the repeater network can deliver copies) are dropped.
///
/// Call `start()` once before sending (it subscribes to UART TX). Timeouts run on the injected `Clock`.
public actor UartClient {
    public let variant: UartVariant

    /// Request-direction frames that are not answers to our requests: node `0x45` status, `0x49` heartbeat, ...
    /// Each access returns a new stream; subscribe before `start()` so nothing is missed.
    public nonisolated var unsolicited: AsyncStream<UartFrame> { unsolicitedBroadcast.stream() }

    public var diagnostics: UartDiagnostics { stats }

    // MARK: State

    private enum Event: Sendable {
        case response(UartResponse)
        case error(UartError)
        case timedOut
    }

    private enum Key: Hashable {
        case type(UInt8)
        case id(UInt32)
    }

    private struct Pending {
        var token: UInt64
        var messageType: UInt8
        var continuation: AsyncStream<Event>.Continuation
        /// Several responses expected (readLogs); the owner decides when it is finished.
        var multi: Bool
        var timer: Task<Void, Never>?
        var timerGeneration: UInt64 = 0
    }

    private let connection: any GattConnection
    private let clock: any Clock
    private let nextRequestId: @Sendable () -> UInt32
    private let unsolicitedBroadcast = Broadcaster<UartFrame>()

    private var framer: UartFramer
    private var started = false
    private var closed = false
    private var readerTask: Task<Void, Never>?
    private var pending: [Key: Pending] = [:]
    private var nextToken: UInt64 = 0
    private var stats = UartDiagnostics()

    private var seenResponseIds: Set<UInt32> = []
    private var seenResponseOrder: [UInt32] = []
    private static let seenResponseLimit = 512

    private var writeBusy = false
    private var writeWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter requestIds: source of node request IDs; inject a deterministic one in tests.
    public init(
        variant: UartVariant, connection: any GattConnection, clock: any Clock,
        requestIds: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }
    ) {
        self.variant = variant
        self.connection = connection
        self.clock = clock
        self.nextRequestId = requestIds
        self.framer = UartFramer(variant: variant, direction: .response)
    }

    // MARK: Lifecycle

    /// Subscribes to UART TX and starts routing frames. Idempotent. Throws the transport's error
    /// (for example `characteristicNotFound`), or `.disconnected` once closed.
    public func start() async throws {
        guard !closed else { throw UartError.disconnected }
        guard !started else { return }
        started = true
        let stream: AsyncStream<[UInt8]>
        do {
            stream = try await connection.subscribe(.uartTX)
        } catch {
            started = false
            throw error
        }
        guard !closed else { throw UartError.disconnected }
        readerTask = Task {
            for await bytes in stream {
                self.handle(bytes)
            }
            self.shutdown()
        }
    }

    /// Fails every pending request with `.disconnected` and stops routing. Does not close the connection.
    public func close() {
        readerTask?.cancel()
        shutdown()
    }

    private func shutdown() {
        closed = true
        readerTask = nil
        for (key, p) in pending {
            p.timer?.cancel()
            p.continuation.yield(.error(.disconnected))
            p.continuation.finish()
            pending[key] = nil
        }
        unsolicitedBroadcast.finish()
    }

    // MARK: send

    /// Sends one request and waits for its response. `timeout` applies per attempt; on timeout the same
    /// bytes (same request ID) are written again up to `retries` more times.
    /// For the node variant pass the `probe` the request is addressed to.
    /// A response with `success = 0` throws `.failure`.
    public func send(
        _ request: UartRequest, probe: ProbeSerial? = nil,
        timeout: Duration = .seconds(3), retries: Int = 1
    ) async throws -> UartResponse {
        let (key, bytes) = try prepare(request, probe: probe)
        let (token, events) = try register(key, messageType: request.messageType, multi: false)
        defer { complete(key, token: token) }

        var iterator = events.makeAsyncIterator()
        var attempts = 0
        while true {
            arm(key, token: token, after: timeout)
            do { try await write(bytes) } catch { throw UartError.disconnected }
            guard let event = await iterator.next() else {
                throw Task.isCancelled ? CancellationError() : UartError.disconnected
            }
            switch event {
            case .response(let r):
                guard r.success else { throw UartError.failure }
                return r
            case .error(let e):
                throw e
            case .timedOut:
                if attempts >= retries { throw UartError.timeout }
                attempts += 1
            }
        }
    }

    // MARK: readLogs

    /// Streams log records in `[start, end]`. One request, N responses. Finishes after the record with
    /// `sequence >= end`, or after `idleTimeout` with no further record (partial range: the caller sees
    /// which sequence numbers arrived). Duplicate sequence numbers are dropped; gaps are not filled.
    /// Throws `.timeout` if nothing at all arrived, `.failure` on `success = 0`, `.disconnected`, `.busy`.
    /// For the node variant pass the `probe`; records for other probes are ignored.
    public nonisolated func readLogs(
        probe: ProbeSerial? = nil, start: UInt32, end: UInt32, idleTimeout: Duration = .seconds(2)
    ) -> AsyncThrowingStream<LogRecord, any Error> {
        let (stream, out) = AsyncThrowingStream<LogRecord, any Error>.makeStream()
        let task = Task {
            await self.pumpLogs(probe: probe, start: start, end: end, idleTimeout: idleTimeout, out: out)
        }
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    private func pumpLogs(
        probe: ProbeSerial?, start: UInt32, end: UInt32, idleTimeout: Duration,
        out: AsyncThrowingStream<LogRecord, any Error>.Continuation
    ) async {
        do {
            let (key, bytes) = try prepare(.readLogs(start: start, end: end), probe: probe)
            let (token, events) = try register(key, messageType: UartMessageType.readLogs, multi: true)
            defer { complete(key, token: token) }

            arm(key, token: token, after: idleTimeout)
            do { try await write(bytes) } catch { throw UartError.disconnected }

            var seen = Set<UInt32>()
            var iterator = events.makeAsyncIterator()
            while let event = await iterator.next() {
                switch event {
                case .timedOut:
                    if seen.isEmpty { throw UartError.timeout }
                    out.finish()
                    return
                case .error(let e):
                    throw e
                case .response(let r):
                    guard r.success else { throw UartError.failure }
                    guard case .logRecord(let from, let record) = r.body else { continue }
                    if let probe, let from, from != probe { continue }
                    guard seen.insert(record.sequence).inserted else { continue }
                    arm(key, token: token, after: idleTimeout)
                    out.yield(record)
                    if record.sequence >= end {
                        out.finish()
                        return
                    }
                }
            }
            throw Task.isCancelled ? CancellationError() : UartError.disconnected
        } catch {
            out.finish(throwing: error)
        }
    }

    // MARK: Request bookkeeping

    private func prepare(_ request: UartRequest, probe: ProbeSerial?) throws -> (Key, [UInt8]) {
        guard started, !closed else { throw UartError.disconnected }
        var id: UInt32?
        if variant == .node {
            var candidate = nextRequestId()
            while pending[.id(candidate)] != nil { candidate = nextRequestId() }
            id = candidate
        }
        let bytes: [UInt8]
        do {
            bytes = try encodeRequest(variant: variant, request, probe: probe, requestId: id)
        } catch let e as CodecError {
            throw UartError.codec(e)
        }
        let key: Key = id.map { .id($0) } ?? .type(request.messageType)
        return (key, bytes)
    }

    private func register(_ key: Key, messageType: UInt8, multi: Bool) throws -> (UInt64, AsyncStream<Event>) {
        guard pending[key] == nil else { throw UartError.busy }
        nextToken += 1
        let token = nextToken
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        pending[key] = Pending(token: token, messageType: messageType, continuation: continuation, multi: multi)
        return (token, stream)
    }

    /// Removes the request (if still ours) and ends its event stream.
    private func complete(_ key: Key, token: UInt64) {
        guard let p = pending[key], p.token == token else { return }
        p.timer?.cancel()
        p.continuation.finish()
        pending[key] = nil
    }

    private func arm(_ key: Key, token: UInt64, after duration: Duration) {
        guard var p = pending[key], p.token == token else { return }
        p.timer?.cancel()
        p.timerGeneration += 1
        let generation = p.timerGeneration
        let clock = self.clock
        p.timer = Task {
            do { try await clock.sleep(for: duration) } catch { return }
            self.timerFired(key, token: token, generation: generation)
        }
        pending[key] = p
    }

    private func timerFired(_ key: Key, token: UInt64, generation: UInt64) {
        guard let p = pending[key], p.token == token, p.timerGeneration == generation else { return }
        p.continuation.yield(.timedOut)
    }

    // MARK: Writing

    private func write(_ bytes: [UInt8]) async throws {
        await lockWrite()
        defer { unlockWrite() }
        let chunk = max(connection.mtu - 3, 20)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            try await connection.write(.uartRX, Array(bytes[offset..<end]), withResponse: true)
            offset = end
        }
    }

    private func lockWrite() async {
        if writeBusy {
            await withCheckedContinuation { writeWaiters.append($0) }
        } else {
            writeBusy = true
        }
    }

    private func unlockWrite() {
        if writeWaiters.isEmpty {
            writeBusy = false
        } else {
            writeWaiters.removeFirst().resume()
        }
    }

    // MARK: Receiving

    private func handle(_ bytes: [UInt8]) {
        for output in framer.push(bytes) {
            switch output {
            case .error:
                stats.framingErrors += 1
            case .frame(let frame):
                route(frame)
            }
        }
    }

    private func route(_ frame: UartFrame) {
        if frame.direction == .request {
            unsolicitedBroadcast.send(frame)
            return
        }
        if variant == .node, let responseId = frame.responseId {
            guard rememberResponseId(responseId) else {
                stats.duplicateResponses += 1
                return
            }
        }
        let key: Key = variant == .node ? .id(frame.requestId ?? 0) : .type(frame.messageType)
        guard let p = pending[key], p.messageType == frame.messageType else {
            stats.ignoredFrames += 1
            return
        }
        do {
            let response = try decodeResponse(frame)
            p.continuation.yield(.response(response))
            if !p.multi { complete(key, token: p.token) }
        } catch let e as CodecError {
            stats.codecErrors += 1
            p.continuation.yield(.error(.codec(e)))
            complete(key, token: p.token)
        } catch {
            stats.codecErrors += 1
            complete(key, token: p.token)
        }
    }

    /// Returns false if the ID was already seen.
    private func rememberResponseId(_ id: UInt32) -> Bool {
        guard seenResponseIds.insert(id).inserted else { return false }
        seenResponseOrder.append(id)
        if seenResponseOrder.count > Self.seenResponseLimit {
            seenResponseIds.remove(seenResponseOrder.removeFirst())
        }
        return true
    }
}
