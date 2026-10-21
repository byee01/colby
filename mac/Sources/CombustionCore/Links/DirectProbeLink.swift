import CombustionCodec
import Foundation

/// One probe connected directly over GATT (docs/02 §5.3).
///
/// Subscribes to Probe Status and publishes `ProbeObservation(.status)` with source `.directConnection`,
/// and owns a probe-variant `UartClient` on the UART characteristics. The GATT status payload does not carry
/// the probe serial, so the caller supplies it (from the advertisement that led to the connection).
///
/// The 94 B status (fw v2.3.3 and older) has no session fields. On the first such status the link reads Session
/// Info over UART and fills it into every later status, so history can tell cooks apart (docs/07). Statuses before
/// the answer go out without it (`SessionTracker` adopts the id). If the log range goes backwards on the same
/// link, the cached info is dropped and read again. Firmware that refuses the read keeps sending none.
public actor DirectProbeLink: LogFetcher {
    public nonisolated let serial: ProbeSerial
    public nonisolated let uart: UartClient

    public nonisolated var observations: AsyncStream<ProbeObservation> { observationBroadcast.stream() }
    /// Yields the reason once (late subscribers still get it), then finishes.
    public nonisolated var disconnected: AsyncStream<DisconnectReason> { disconnectBroadcast.stream() }

    /// Probe Status notifications the codec rejected.
    public var statusDecodeErrors: Int { decodeErrors }

    private let connection: any GattConnection
    private let clock: any Clock
    private let observationBroadcast = Broadcaster<ProbeObservation>()
    private let disconnectBroadcast = Broadcaster<DisconnectReason>(replayLatest: true)
    private var tasks: [Task<Void, Never>] = []
    private var started = false
    private var finished = false
    private var decodeErrors = 0
    private var sessionInfo: SessionInfo?
    private var sessionRead: Task<Void, Never>?
    private var sessionReadRefused = false
    private var lastLogMax: UInt32?

    public init(serial: ProbeSerial, connection: any GattConnection, clock: any Clock) {
        self.serial = serial
        self.connection = connection
        self.clock = clock
        self.uart = UartClient(variant: .probe, connection: connection, clock: clock)
    }

    /// Discovers services, starts the UART client and subscribes to Probe Status.
    /// On failure the link is torn down and the error rethrown.
    public func start() async throws {
        guard !started else { return }
        started = true
        // Watch for disconnects first so nothing is missed while setting up.
        let drops = connection.disconnected
        tasks.append(Task {
            for await reason in drops {
                await self.finish(reason)
                return
            }
            await self.finish(.linkLost)
        })
        do {
            let services = try await connection.discover()
            let known = Set(services.flatMap(\.characteristics))
            for needed in [GattUUID.probeStatus, .uartRX, .uartTX] where !known.contains(needed) {
                throw TransportError.characteristicNotFound(needed)
            }
            try await uart.start()
            let status = try await connection.subscribe(.probeStatus)
            tasks.append(Task {
                for await bytes in status {
                    self.handleStatus(bytes)
                }
            })
        } catch {
            // Tear down fully, including the connection: a half-started link must not hold a probe slot.
            await connection.close()
            await finish(.requested)
            throw error
        }
    }

    /// Closes the connection and ends all streams.
    public func close() async {
        await connection.close()
        await finish(.requested)
    }

    private func finish(_ reason: DisconnectReason) async {
        guard !finished else { return }
        finished = true
        for t in tasks { t.cancel() }
        tasks.removeAll()
        sessionRead?.cancel()
        await uart.close()
        observationBroadcast.finish()
        disconnectBroadcast.send(reason)
        disconnectBroadcast.finish()
    }

    private func handleStatus(_ bytes: [UInt8]) {
        guard !finished else { return }
        var payload: ProbeStatusPayload
        do {
            payload = try decodeProbeStatus(bytes)
        } catch {
            decodeErrors += 1
            return
        }
        if payload.session == nil {
            if let last = lastLogMax, payload.logRange.max < last {
                sessionInfo = nil
                sessionReadRefused = false
            }
            if sessionInfo == nil { requestSessionInfo() }
            payload.session = sessionInfo
        }
        lastLogMax = payload.logRange.max
        let now = clock.now()
        let source = LinkSource(
            kind: .directConnection, highRadioPower: payload.preferences?.highRadioPower, lastSeen: now)
        observationBroadcast.send(ProbeObservation(
            serial: serial, source: source, payload: .status(payload), receivedAt: now))
    }

    private func requestSessionInfo() {
        guard sessionRead == nil, !sessionReadRefused else { return }
        sessionRead = Task {
            let info = try? await self.readSessionInfo()
            self.sessionInfoArrived(info)
        }
    }

    private func sessionInfoArrived(_ info: SessionInfo?) {
        sessionRead = nil
        if let info { sessionInfo = info } else { sessionReadRefused = true }
    }

    // MARK: UART

    /// Sends any request over the probe UART. Used by commands later.
    public func send(
        _ request: UartRequest, timeout: Duration = .seconds(3), retries: Int = 1
    ) async throws -> UartResponse {
        try await uart.send(request, timeout: timeout, retries: retries)
    }

    public func readSessionInfo() async throws -> SessionInfo {
        let response = try await uart.send(.readSessionInfo)
        guard case .sessionInfo(_, let info) = response.body else {
            throw UartError.codec(.unknownMessageType(response.messageType))
        }
        return info
    }

    /// `probe` must be this link's probe; anything else fails with `UartError.failure` (a mismatch would
    /// file another probe's history under the wrong serial).
    ///
    /// Reads are serialized per link: the probe UART allows one Read Logs in flight, and live fetches and
    /// backfill run concurrently, so a second caller waits for its turn instead of failing with `.busy`.
    public nonisolated func readLogs(
        probe: ProbeSerial, start: UInt32, end: UInt32
    ) -> AsyncThrowingStream<LogRecord, any Error> {
        guard probe == serial else {
            return AsyncThrowingStream { $0.finish(throwing: UartError.failure) }
        }
        let (stream, out) = AsyncThrowingStream<LogRecord, any Error>.makeStream()
        let task = Task {
            await self.acquireReadTurn()
            defer { Task { await self.releaseReadTurn() } }
            if Task.isCancelled {
                out.finish(throwing: CancellationError())
                return
            }
            do {
                for try await r in self.uart.readLogs(probe: nil, start: start, end: end, idleTimeout: .seconds(2)) {
                    out.yield(r)
                }
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
        }
        out.onTermination = { _ in task.cancel() }
        return stream
    }

    private var readBusy = false
    private var readWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireReadTurn() async {
        if readBusy {
            await withCheckedContinuation { readWaiters.append($0) }
        } else {
            readBusy = true
        }
    }

    private func releaseReadTurn() {
        if readWaiters.isEmpty {
            readBusy = false
        } else {
            readWaiters.removeFirst().resume()
        }
    }
}
