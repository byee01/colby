import CombustionCodec
import Foundation

/// What the UI shows for one probe's prediction. docs/02 §3, §7, §18.
public struct PredictionView: Sendable, Equatable {
    public var serial: ProbeSerial
    public var state: PredictionState
    public var mode: PredictionMode
    public var type: PredictionType
    public var setpoint: Double
    public var estimatedCore: Double
    /// 0...100; nil when the set point is not above the heat-start temperature.
    public var percentToRemoval: Double?
    /// Smoothed and rounded; nil unless predicting with at most 4 h to go.
    public var secondsRemaining: UInt32?
    /// No status for 15 s. The numbers are the last known ones.
    public var isStale: Bool
    /// Completion time shown beside the countdown. Anchored to the status that last moved the countdown,
    /// so it does not creep while the (held) countdown stands still.
    public var readyAt: Date?
    /// When the state became `removalPredictionDone` ("Ready since 13:18"); nil in any other state.
    public var readySince: Date?

    public init(
        serial: ProbeSerial, state: PredictionState, mode: PredictionMode, type: PredictionType,
        setpoint: Double, estimatedCore: Double, percentToRemoval: Double? = nil, secondsRemaining: UInt32? = nil,
        isStale: Bool = false, readyAt: Date? = nil, readySince: Date? = nil
    ) {
        self.serial = serial
        self.state = state
        self.mode = mode
        self.type = type
        self.setpoint = setpoint
        self.estimatedCore = estimatedCore
        self.percentToRemoval = percentToRemoval
        self.secondsRemaining = secondsRemaining
        self.isStale = isStale
        self.readyAt = readyAt
        self.readySince = readySince
    }
}

/// Pure countdown logic for one probe: a port of the iOS SDK `PredictionManager` so the numbers match the
/// Display and the phone app. Times are passed in; nothing here reads a clock. docs/02 §7.
///
/// - Seconds remaining exist only while `predicting` with a raw value of at most 4 h.
/// - Above 300 s: rounded to the nearest 15 s, and replaced only when the status `seq % 3 == 0` (or there is no
///   value yet). The Display and phone round the same way, so the three agree.
/// - At 300 s and below: a linear countdown, advanced by `tick(at:)`, aiming at `raw - statusPeriod` by the time
///   the next status is due.
struct PredictionSmoother {
    static let maxSeconds: UInt32 = 4 * 3600
    static let countdownLimit: UInt32 = 300
    static let roundTo = 15.0

    let statusPeriod: TimeInterval
    private(set) var status: PredictionStatus?
    private(set) var lastStatusAt: Date?
    private(set) var readySince: Date?
    private var displayed: Double?
    private var readyAt: Date?
    private var ramp: (from: Double, to: Double, start: Date)?

    init(statusPeriod: TimeInterval = 5) { self.statusPeriod = statusPeriod }

    /// True while the countdown still has to move between statuses (needs 200 ms ticks).
    var isRamping: Bool { ramp != nil }

    mutating func ingest(_ s: PredictionStatus, seq: UInt32, at now: Date) {
        status = s
        lastStatusAt = now
        if s.state == .removalPredictionDone {
            if readySince == nil { readySince = now }
        } else {
            readySince = nil
        }
        guard s.state == .predicting, s.rawSecondsRemaining <= Self.maxSeconds else {
            displayed = nil
            readyAt = nil
            ramp = nil
            return
        }
        let raw = Double(s.rawSecondsRemaining)
        if s.rawSecondsRemaining > Self.countdownLimit {
            ramp = nil
            if displayed == nil || seq % 3 == 0 {
                let rounded = (raw / Self.roundTo).rounded() * Self.roundTo
                displayed = rounded
                readyAt = now.addingTimeInterval(rounded)
            }
        } else {
            let from = displayed ?? raw
            displayed = from
            ramp = (from, max(raw - statusPeriod, 0), now)
            readyAt = now.addingTimeInterval(raw)
        }
    }

    mutating func tick(at now: Date) {
        guard let r = ramp else { return }
        let fraction = min(1, max(0, now.timeIntervalSince(r.start) / statusPeriod))
        displayed = r.from + (r.to - r.from) * fraction
        if fraction >= 1 { ramp = nil }
    }

    func isStale(at now: Date, after limit: TimeInterval) -> Bool {
        guard let last = lastStatusAt else { return false }
        return now.timeIntervalSince(last) >= limit
    }

    func view(serial: ProbeSerial, at now: Date, staleAfter: TimeInterval) -> PredictionView? {
        guard let s = status else { return nil }
        return PredictionView(
            serial: serial, state: s.state, mode: s.mode, type: s.type, setpoint: s.setpoint,
            estimatedCore: s.estimatedCore, percentToRemoval: s.percentToRemoval,
            secondsRemaining: displayed.map { UInt32(max(0, $0.rounded())) },
            isStale: isStale(at: now, after: staleAfter), readyAt: readyAt, readySince: readySince)
    }
}

/// A view change for one probe (all probes on one stream, for the alert engine and widgets).
public struct PredictionUpdate: Sendable, Equatable {
    public var serial: ProbeSerial
    public var view: PredictionView
}

/// Turns each probe's raw `PredictionStatus` into a `PredictionView` stream. docs/02 §7.
///
/// Input: `ProbeStore.statusEvents` (every accepted full status; `logRange.max` is the status sequence).
/// Output: `predictions(_:)` per probe (latest value first, only changes after) and `updates` for all probes.
///
/// Timing runs on the injected `Clock`: a single wake-up task sleeps until the next thing that can change a
/// view, either the next 200 ms tick while a countdown is moving, or the earliest stale deadline (15 s after
/// a probe's last status). With nothing counting down, a probe costs one sleeper, not a 5 Hz timer.
public actor PredictionPresenter {
    public static let tickInterval: Duration = .milliseconds(200)
    public static let staleAfter: Duration = .seconds(15)

    private let probes: ProbeStore
    private let clock: any Clock
    private let tick: Duration
    private let stale: Duration
    private let statusPeriod: TimeInterval

    private let hub = ViewHub()
    private let updateBroadcaster = Broadcaster<PredictionUpdate>()
    private var smoothers: [ProbeSerial: PredictionSmoother] = [:]
    private var last: [ProbeSerial: PredictionView] = [:]
    private var task: Task<Void, Never>?
    private var wake: Task<Void, Never>?

    public init(
        probes: ProbeStore, clock: any Clock, tickInterval: Duration = PredictionPresenter.tickInterval,
        staleAfter: Duration = PredictionPresenter.staleAfter, statusPeriod: TimeInterval = 5
    ) {
        self.probes = probes
        self.clock = clock
        self.tick = tickInterval
        self.stale = staleAfter
        self.statusPeriod = statusPeriod
    }

    deinit {
        task?.cancel()
        wake?.cancel()
    }

    // MARK: Observables

    /// One probe's view: the latest value first (if any), then every change.
    public nonisolated func predictions(_ serial: ProbeSerial) -> AsyncStream<PredictionView> {
        hub.stream(for: serial)
    }

    /// Every probe's changes, no replay.
    public nonisolated var updates: AsyncStream<PredictionUpdate> { updateBroadcaster.stream() }

    public func view(for serial: ProbeSerial) -> PredictionView? { last[serial] }

    // MARK: Lifecycle

    /// Subscribes to the store's status events. Idempotent.
    public func start() {
        guard task == nil else { return }
        let statuses = probes.statusEvents
        task = Task { [weak self] in
            for await e in statuses {
                guard let self else { return }
                await self.ingest(e)
            }
        }
    }

    /// Stops listening and timing. Streams stay open.
    public func stop() {
        task?.cancel()
        task = nil
        wake?.cancel()
        wake = nil
    }

    // MARK: Input

    public func ingest(_ event: ProbeStatusEvent) {
        let now = clock.now()
        var s = smoothers[event.serial] ?? PredictionSmoother(statusPeriod: statusPeriod)
        s.ingest(event.status.prediction, seq: event.status.logRange.max, at: now)
        smoothers[event.serial] = s
        publish(event.serial, now: now)
        reschedule()
    }

    // MARK: Timing

    private func publish(_ serial: ProbeSerial, now: Date) {
        guard let v = smoothers[serial]?.view(serial: serial, at: now, staleAfter: stale.totalSeconds),
              last[serial] != v else { return }
        last[serial] = v
        hub.send(v)
        updateBroadcaster.send(PredictionUpdate(serial: serial, view: v))
    }

    /// Sleeps until the next tick (a countdown is moving) or the next stale deadline, whichever is first.
    private func reschedule() {
        wake?.cancel()
        wake = nil
        let now = clock.now()
        var next: Date?
        for s in smoothers.values {
            var candidate: Date?
            if s.isRamping {
                candidate = now.addingTimeInterval(tick.totalSeconds)
            } else if let lastAt = s.lastStatusAt, !s.isStale(at: now, after: stale.totalSeconds) {
                candidate = lastAt.addingTimeInterval(stale.totalSeconds)
            }
            if let c = candidate, next.map({ c < $0 }) ?? true { next = c }
        }
        guard let next else { return }
        let delay = max(next.timeIntervalSince(now), 0.001)
        let clock = self.clock
        wake = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(delay)) } catch { return }
            await self?.wakeUp()
        }
    }

    private func wakeUp() {
        let now = clock.now()
        for serial in Array(smoothers.keys) {
            smoothers[serial]?.tick(at: now)
            publish(serial, now: now)
        }
        reschedule()
    }
}

/// Per-probe broadcasters behind a lock, so `predictions(_:)` can be `nonisolated`.
private final class ViewHub: @unchecked Sendable {
    private let lock = NSLock()
    private var casters: [ProbeSerial: Broadcaster<PredictionView>] = [:]

    private func caster(_ serial: ProbeSerial) -> Broadcaster<PredictionView> {
        lock.withLock {
            if let b = casters[serial] { return b }
            let b = Broadcaster<PredictionView>(replayLatest: true)
            casters[serial] = b
            return b
        }
    }

    func stream(for serial: ProbeSerial) -> AsyncStream<PredictionView> { caster(serial).stream() }
    func send(_ view: PredictionView) { caster(view.serial).send(view) }
}
