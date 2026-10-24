import CombustionCodec
import Foundation

/// One MeatNet node (Display, Booster, ...) connected over GATT (docs/02 §5.4).
///
/// Owns a node-variant `UartClient`. The node pushes `0x45` Probe Status for every probe on its network;
/// each becomes a `ProbeObservation(.status)` with source `.nodeConnection` (`via` = this node, `hopCount`
/// from the Network Information byte). `0x49` heartbeats feed the node's `NodeSnapshot`. Requests for a
/// probe (history, session info) are addressed by probe serial, so one connection serves every probe the
/// node relays.
///
/// The 94 B status inside `0x45` (probe fw v2.3.3) has no session fields. As `DirectProbeLink` does, the link
/// reads Session Info for each probe on its first such status, through this node, and fills it into later
/// statuses; a log range that goes backwards drops that probe's cached info and reads it again.
public actor NodeLink: LogFetcher {
    public nonisolated let serial: NodeSerial
    public nonisolated let productType: NodeProductType
    public nonisolated let uart: UartClient

    /// Probe statuses relayed by the node.
    public nonisolated var observations: AsyncStream<ProbeObservation> { observationBroadcast.stream() }
    /// The node's own state; current value first, then each change. The last one has `isConnected == false`.
    public nonisolated var snapshots: AsyncStream<NodeSnapshot> { snapshotBroadcast.stream() }
    /// Yields the reason once (late subscribers still get it), then finishes.
    public nonisolated var disconnected: AsyncStream<DisconnectReason> { disconnectBroadcast.stream() }

    public var snapshot: NodeSnapshot { current }
    /// `0x45` messages the codec rejected.
    public var statusDecodeErrors: Int { decodeErrors }
    /// Payload of the latest heartbeat, undecoded (the topology layout is not in our spec digest).
    public var lastHeartbeatPayload: [UInt8]? { heartbeatPayload }

    /// A probe counts as relayed by this node for this long after its last `0x45`.
    public static let coverageTTL: Duration = .seconds(10)

    private let connection: any GattConnection
    private let clock: any Clock
    private let coverage = Coverage()
    private let observationBroadcast = Broadcaster<ProbeObservation>()
    private let snapshotBroadcast: Broadcaster<NodeSnapshot>
    private let disconnectBroadcast = Broadcaster<DisconnectReason>(replayLatest: true)
    private var current: NodeSnapshot
    private var tasks: [Task<Void, Never>] = []
    private var started = false
    private var finished = false
    private var decodeErrors = 0
    private var heartbeatPayload: [UInt8]?
    private var sessions: [ProbeSerial: ProbeSession] = [:]

    private struct ProbeSession {
        var info: SessionInfo?
        var read: Task<Void, Never>?
        var refused = false
        var lastLogMax: UInt32?
    }

    /// - Parameter requestIds: source of request IDs; inject a deterministic one in tests.
    public init(
        serial: NodeSerial, productType: NodeProductType, connection: any GattConnection, clock: any Clock,
        requestIds: @escaping @Sendable () -> UInt32 = { UInt32.random(in: 0...UInt32.max) }
    ) {
        self.serial = serial
        self.productType = productType
        self.connection = connection
        self.clock = clock
        self.uart = UartClient(variant: .node, connection: connection, clock: clock, requestIds: requestIds)
        self.current = NodeSnapshot(
            serial: serial, productType: productType,
            link: LinkSource(kind: .nodeAdvertisement, lastSeen: clock.now()))
        self.snapshotBroadcast = Broadcaster(initial: current, replayLatest: true)
    }

    // MARK: Lifecycle

    /// Discovers services, starts the UART client and begins routing `0x45` / `0x49`. Device Information is
    /// read in the background (best effort). On failure the link is torn down and the error rethrown.
    public func start() async throws {
        guard !started else { return }
        started = true
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
            for needed in [GattUUID.uartRX, .uartTX] where !known.contains(needed) {
                throw TransportError.characteristicNotFound(needed)
            }
            // Subscribe before starting the client so no early frame is missed.
            let frames = uart.unsolicited
            try await uart.start()
            tasks.append(Task {
                for await frame in frames {
                    self.handle(frame)
                }
            })
        } catch {
            await connection.close()
            await finish(.requested)
            throw error
        }
        current.isConnected = true
        current.link = LinkSource(kind: .directConnection, lastSeen: clock.now())
        publish()
        tasks.append(Task { await self.loadDeviceInfo() })
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
        for s in sessions.values { s.read?.cancel() }
        sessions.removeAll()
        await uart.close()
        coverage.clear()
        current.isConnected = false
        current.link = LinkSource(kind: .nodeAdvertisement, lastSeen: clock.now())
        current.probes = []
        current.hopCounts = [:]
        snapshotBroadcast.send(current)
        snapshotBroadcast.finish()
        observationBroadcast.finish()
        disconnectBroadcast.send(reason)
        disconnectBroadcast.finish()
    }

    // MARK: Receiving

    private func handle(_ frame: UartFrame) {
        guard !finished else { return }
        switch frame.messageType {
        case UartMessageType.probeStatus: handleProbeStatus(frame.payload)
        case UartMessageType.heartbeat: handleHeartbeat(frame.payload)
        default: break
        }
    }

    private func handleProbeStatus(_ payload: [UInt8]) {
        var node: NodeProbeStatus
        do {
            node = try decodeNodeProbeStatus(payload)
        } catch {
            decodeErrors += 1
            return
        }
        if node.status.session == nil {
            var s = sessions[node.serial] ?? ProbeSession()
            if let last = s.lastLogMax, node.status.logRange.max < last {
                s.info = nil
                s.refused = false
            }
            node.status.session = s.info
            sessions[node.serial] = s
            if s.info == nil { requestSessionInfo(node.serial) }
        }
        sessions[node.serial, default: ProbeSession()].lastLogMax = node.status.logRange.max
        let now = clock.now()
        let source = LinkSource(
            kind: .nodeConnection, via: serial, hopCount: node.hopCount,
            highRadioPower: node.status.preferences?.highRadioPower, lastSeen: now)
        observationBroadcast.send(ProbeObservation(
            serial: node.serial, source: source, payload: .status(node.status), receivedAt: now))
        if coverage.note(node.serial, hops: node.hopCount, at: now) { refreshProbes(now) }
    }

    private func requestSessionInfo(_ probe: ProbeSerial) {
        guard var s = sessions[probe], s.read == nil, !s.refused else { return }
        s.read = Task {
            let info = try? await self.readSessionInfo(probe: probe)
            self.sessionInfoArrived(info, probe: probe)
        }
        sessions[probe] = s
    }

    private func sessionInfoArrived(_ info: SessionInfo?, probe: ProbeSerial) {
        guard !finished, var s = sessions[probe] else { return }
        s.read = nil
        if let info { s.info = info } else { s.refused = true }
        sessions[probe] = s
    }

    private func handleHeartbeat(_ payload: [UInt8]) {
        let now = clock.now()
        heartbeatPayload = payload
        current.heartbeatCount += 1
        current.lastHeartbeat = now
        current.link.lastSeen = now
        // Heartbeats are the only periodic event, so they also retire probes that stopped being relayed.
        refreshProbes(now)
    }

    private func refreshProbes(_ now: Date) {
        let live = coverage.live(at: now, ttl: Self.coverageTTL.totalSeconds)
        current.probes = live.keys.sorted()
        current.hopCounts = live
        publish()
    }

    private func publish() {
        guard !finished else { return }
        snapshotBroadcast.send(current)
    }

    // MARK: Device Information

    /// Reads firmware, hardware and model strings. Missing characteristics are skipped.
    public func loadDeviceInfo() async {
        func text(_ uuid: GattUUID) async -> String? {
            guard let bytes = try? await connection.read(uuid) else { return nil }
            let s = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            return s.isEmpty ? nil : s
        }
        let info = DeviceInfo(
            firmware: await text(.firmwareRevision), hardware: await text(.hardwareRevision),
            model: await text(.modelNumber))
        guard !finished, !info.isEmpty else { return }
        current.firmware = info
        publish()
    }

    // MARK: Probe access

    /// True if the node relayed a status for `probe` in the last `coverageTTL`.
    public nonisolated func covers(_ probe: ProbeSerial) -> Bool {
        coverage.covers(probe, at: clock.now(), ttl: Self.coverageTTL.totalSeconds)
    }

    /// Hop count of `probe` as last relayed, if still covered.
    public nonisolated func hops(to probe: ProbeSerial) -> Int? {
        coverage.live(at: clock.now(), ttl: Self.coverageTTL.totalSeconds)[probe]
    }

    /// Sends a request addressed to `probe` through this node.
    public func send(
        _ request: UartRequest, probe: ProbeSerial, timeout: Duration = .seconds(3), retries: Int = 1
    ) async throws -> UartResponse {
        try await uart.send(request, probe: probe, timeout: timeout, retries: retries)
    }

    public func readSessionInfo(probe: ProbeSerial) async throws -> SessionInfo {
        let response = try await uart.send(.readSessionInfo, probe: probe)
        guard case .sessionInfo(_, let info) = response.body else {
            throw UartError.codec(.unknownMessageType(response.messageType))
        }
        return info
    }

    /// Streams `probe`'s log records through the node. Node requests carry IDs, so concurrent reads (live
    /// fetch and backfill, or several probes) need no serialization here.
    public nonisolated func readLogs(
        probe: ProbeSerial, start: UInt32, end: UInt32
    ) -> AsyncThrowingStream<LogRecord, any Error> {
        uart.readLogs(probe: probe, start: start, end: end, idleTimeout: .seconds(2))
    }
}

/// Probes recently relayed by a node: last `0x45` time and hop count. Lock-protected so `covers` can be
/// called from the (synchronous) log router.
private final class Coverage: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [ProbeSerial: (at: Date, hops: Int)] = [:]

    /// Returns true if the set of probes or a hop count changed.
    func note(_ probe: ProbeSerial, hops: Int, at: Date) -> Bool {
        lock.withLock {
            defer { seen[probe] = (at, hops) }
            return seen[probe]?.hops != hops
        }
    }

    func covers(_ probe: ProbeSerial, at now: Date, ttl: TimeInterval) -> Bool {
        lock.withLock { seen[probe].map { now.timeIntervalSince($0.at) < ttl } ?? false }
    }

    func live(at now: Date, ttl: TimeInterval) -> [ProbeSerial: Int] {
        lock.withLock { seen.filter { now.timeIntervalSince($0.value.at) < ttl }.mapValues(\.hops) }
    }

    func clear() { lock.withLock { seen.removeAll() } }
}
