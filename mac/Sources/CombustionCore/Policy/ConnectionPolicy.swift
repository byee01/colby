import CombustionCodec
import Foundation

/// Where one followed probe stands in the connection lifecycle (diagnostics and tests).
public enum ProbeConnectionState: Sendable, Equatable {
    /// Followed, but its own advertisement has not been heard yet.
    case waitingForAdvertisement
    case connecting(attempt: Int)
    case connected
    /// A connect failed or the link dropped; the next attempt is at `retryAt` (clock monotonic time).
    case backoff(attempt: Int, retryAt: Duration)
    /// Absent from advertisements for the give-up interval. Resumes when it advertises again.
    case gaveUp
}

/// Receives the links a policy creates. All calls for one probe are sequential.
public protocol ConnectionPolicyDelegate: Sendable {
    /// A link object exists but has not started. Subscribe to its streams here so nothing is missed.
    func linkCreated(_ link: DirectProbeLink) async
    /// The link is started (discovered, UART ready, subscribed to Probe Status).
    func linkEstablished(_ link: DirectProbeLink) async
    /// The link is gone (dropped, closed on unfollow, or closed by `stop`).
    func linkEnded(serial: ProbeSerial, reason: DisconnectReason) async
}

/// Everything a policy needs from the app.
public struct ConnectionPolicyInput: Sendable {
    public var transport: any BleTransport
    public var clock: any Clock
    /// Probes heard on their own peripheral (`AdvertisementSource.probeSightings`).
    public var sightings: AsyncStream<ProbeSighting>
    /// The followed set; current value first (`ProbeStore.followed`).
    public var followed: AsyncStream<Set<ProbeSerial>>
    public var delegate: any ConnectionPolicyDelegate

    public init(transport: any BleTransport, clock: any Clock, sightings: AsyncStream<ProbeSighting>,
                followed: AsyncStream<Set<ProbeSerial>>, delegate: any ConnectionPolicyDelegate) {
        self.transport = transport
        self.clock = clock
        self.sightings = sightings
        self.followed = followed
        self.delegate = delegate
    }
}

/// Decides what to connect to (docs/02 §5.6). Replaceable so it can be tuned without touching links.
public protocol ConnectionPolicy: Sendable {
    func start(_ input: ConnectionPolicyInput) async
    /// Closes every link and ends all work.
    func stop() async
    func states() async -> [ProbeSerial: ProbeConnectionState]
}

/// Direct-only version of the default policy:
/// 1. Scanning is the app's job (always on); this policy reacts to what the scan hears.
/// 2. MeatNet node step: TODO(M4) prefer one connection to a node when one is in range, and connect
///    directly only to followed probes the node does not cover.
/// 3. Connect directly to each followed probe once its own advertisement has been heard.
/// 4. Reconnect with backoff 1, 2, 4 ... 30 s. Give up when the probe has been absent from advertisements
///    for 5 min (absence counts from the later of the last advertisement and the end of the last link);
///    resume as soon as it advertises again.
/// 5. At most one connection per probe: one supervisor task per followed probe.
public actor DirectConnectionPolicy: ConnectionPolicy {
    public struct Timing: Sendable {
        public var initialBackoff: Duration = .seconds(1)
        public var maxBackoff: Duration = .seconds(30)
        public var absentLimit: Duration = .seconds(300)
        public var connectTimeout: Duration = .seconds(10)
        /// A link that lasted this long counts as healthy: the next reconnect starts from `initialBackoff`.
        public var stableAfter: Duration = .seconds(10)
        public init() {}
    }

    private let timing: Timing
    private var input: ConnectionPolicyInput?
    private var background: [Task<Void, Never>] = []
    private var supervisors: [ProbeSerial: Task<Void, Never>] = [:]
    private var peripherals: [ProbeSerial: PeripheralId] = [:]
    private var lastSeen: [ProbeSerial: Duration] = [:]
    private var stateByProbe: [ProbeSerial: ProbeConnectionState] = [:]
    private var waiters: [ProbeSerial: [UInt64: CheckedContinuation<Void, Never>]] = [:]
    private var nextWaiter: UInt64 = 0

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    public func states() -> [ProbeSerial: ProbeConnectionState] { stateByProbe }

    public func start(_ input: ConnectionPolicyInput) async {
        guard self.input == nil else { return }
        self.input = input
        background.append(Task { [sightings = input.sightings] in
            for await s in sightings { self.noteSighting(s) }
        })
        background.append(Task { [followed = input.followed] in
            for await set in followed { self.reconcile(set) }
        })
    }

    public func stop() async {
        let all = background + Array(supervisors.values)
        background = []
        supervisors = [:]
        input = nil
        for t in all { t.cancel() }
        for t in all { await t.value }
        stateByProbe = [:]
    }

    // MARK: Inputs

    private func noteSighting(_ s: ProbeSighting) {
        guard let input else { return }
        peripherals[s.serial] = s.peripheral
        lastSeen[s.serial] = input.clock.monotonic()
        if let ws = waiters.removeValue(forKey: s.serial) {
            for c in ws.values { c.resume() }
        }
    }

    private func reconcile(_ followed: Set<ProbeSerial>) {
        guard input != nil else { return }
        for serial in followed where supervisors[serial] == nil {
            stateByProbe[serial] = .waitingForAdvertisement
            supervisors[serial] = Task { await self.supervise(serial) }
        }
        for serial in Array(supervisors.keys) where !followed.contains(serial) {
            supervisors.removeValue(forKey: serial)?.cancel()
            stateByProbe[serial] = nil
        }
    }

    /// Suspends until the next sighting of `serial` (or cancellation).
    private func waitForSighting(_ serial: ProbeSerial) async {
        nextWaiter += 1
        let id = nextWaiter
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    c.resume()
                } else {
                    waiters[serial, default: [:]][id] = c
                }
            }
        } onCancel: {
            Task { await self.cancelWaiter(serial, id) }
        }
    }

    private func cancelWaiter(_ serial: ProbeSerial, _ id: UInt64) {
        waiters[serial]?.removeValue(forKey: id)?.resume()
    }

    private func set(_ serial: ProbeSerial, _ state: ProbeConnectionState) {
        if supervisors[serial] != nil { stateByProbe[serial] = state }
    }

    // MARK: Per-probe supervisor

    private func supervise(_ serial: ProbeSerial) async {
        guard let input else { return }
        let clock = input.clock
        var attempt = 0
        var backoff = timing.initialBackoff

        while !Task.isCancelled {
            guard let peripheral = peripherals[serial], let seen = lastSeen[serial] else {
                set(serial, .waitingForAdvertisement)
                await waitForSighting(serial)
                attempt = 0
                backoff = timing.initialBackoff
                continue
            }
            if clock.monotonic() - seen >= timing.absentLimit {
                set(serial, .gaveUp)
                await waitForSighting(serial)
                attempt = 0
                backoff = timing.initialBackoff
                continue
            }

            attempt += 1
            set(serial, .connecting(attempt: attempt))
            let startedAt = clock.monotonic()
            if let ended = await connectAndRun(serial, peripheral, input) {
                lastSeen[serial] = max(lastSeen[serial] ?? ended, ended)
                if ended - startedAt >= timing.stableAfter {
                    attempt = 0
                    backoff = timing.initialBackoff
                }
            }
            guard !Task.isCancelled else { return }

            // Wait out the backoff, but never past the give-up deadline.
            let now = clock.monotonic()
            let deadline = (lastSeen[serial] ?? now) + timing.absentLimit
            let wait = min(backoff, deadline - now)
            backoff = min(backoff * 2, timing.maxBackoff)
            guard wait > .zero else { continue }
            set(serial, .backoff(attempt: attempt, retryAt: now + wait))
            do { try await clock.sleep(for: wait) } catch { return }
        }
    }

    /// One connection attempt and, if it succeeds, the life of the link. Returns the monotonic time the
    /// link ended, or nil if no link was established.
    private func connectAndRun(_ serial: ProbeSerial, _ peripheral: PeripheralId,
                               _ input: ConnectionPolicyInput) async -> Duration? {
        let connection: any GattConnection
        do {
            connection = try await input.transport.connect(peripheral, timeout: timing.connectTimeout)
        } catch {
            return nil
        }
        let link = DirectProbeLink(serial: serial, connection: connection, clock: input.clock)
        await input.delegate.linkCreated(link)
        let drops = link.disconnected
        do {
            try await link.start()
        } catch {
            await link.close()
            await input.delegate.linkEnded(serial: serial, reason: .requested)
            return nil
        }
        set(serial, .connected)
        await input.delegate.linkEstablished(link)
        var reason = DisconnectReason.linkLost
        for await r in drops {
            reason = r
            break
        }
        await link.close()
        if Task.isCancelled { reason = .requested }
        await input.delegate.linkEnded(serial: serial, reason: reason)
        return input.clock.monotonic()
    }
}
