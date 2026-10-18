import CombustionCodec
import Foundation

/// Rules, probe alarms and overheat in one pipeline, with acknowledge, snooze and keep-awake. docs/02 §9.
///
/// Inputs: probe snapshots, prediction views and the followed set (`start(...)` subscribes; tests may call
/// `ingest(snapshot:)`, `ingest(prediction:)` and `setFollowed(_:)` directly). Only followed probes are evaluated.
///
/// ```
/// idle ──condition true──▶ firing ──ack──▶ acknowledged ──condition false──▶ idle
///                            │ └─snooze──▶ snoozed ──timer──▶ firing (if still true)
///                            └─condition false (auto-clear)──▶ idle
/// ```
/// - A rule fires once per crossing; it re-arms only after it clears (hysteresis keeps a reading that hovers at
///   the threshold from flapping). Rules with a sustain time (`ambientOutOfRange`, `probeOffline`) fire when the
///   condition has held that long, measured on the `Clock`.
/// - `predictionDone` and `restingDone` latch: they stay firing after the condition is gone, until acknowledged.
/// - A probe alarm (`alarming` bit) is acknowledged by sending Silence Alarms to the probe. The app mutes locally
///   at once and goes back to firing, with a `failure` on the event, if the probe could not be silenced.
///   Overheat cannot be silenced on the probe; acknowledging it only mutes the app.
/// - A probe that has no source is not evaluated for alarms or overheat (they clear); `probeOffline` covers it.
/// - Keep-awake is held while any followed probe is in a cook (`RuleEvaluator.isCooking`). A cook that goes
///   quiet counts for `cookIdleTimeout`, so the computer stays awake while the app tries to reconnect.
///
/// Sinks get events in order, one at a time, after the state change is complete.
public actor AlertEngine {
    public static let cookIdleTimeout: Duration = .seconds(600)

    private struct Tracked {
        var instance: AlertInstance
    }

    /// A condition that holds but has not held long enough.
    private struct Pending {
        var since: Date
        var sustain: TimeInterval
        var deadline: Date { since.addingTimeInterval(sustain) }
    }

    /// What one evaluation wants for one alert id.
    private struct Desired {
        var source: AlertSource
        var outcome: RuleOutcome
        var sustain: TimeInterval
        var latch: Bool
    }

    private struct CookState {
        var active = false
        var lastActive: Date?
    }

    /// Slack for comparing deadlines that went through floating-point seconds.
    private static let epsilon = 0.001
    /// Core history for the stall rule: at least this much, and a minute more than the longest window.
    private static let minHistory: TimeInterval = 3600
    private static let historyStep: TimeInterval = 4.9

    private let clock: any Clock
    private let ruleStore: any AlertRuleStore
    private let sinks: [any AlertSink]
    private let keepAwake: (any KeepAwake)?
    private let silencer: (any ProbeAlarmSilencing)?
    private let trace: (any TraceSink)?
    private let defaultRules: (@Sendable (ProbeSerial) -> [AlertRule])?
    private let cookIdle: TimeInterval

    private let eventBroadcaster = Broadcaster<AlertEvent>()
    private let activeBroadcaster = Broadcaster<[AlertInstance]>(initial: [], replayLatest: true)

    private var followedSet: Set<ProbeSerial> = []
    private var ruleSets: [ProbeSerial: [AlertRule]] = [:]
    private var snapshots: [ProbeSerial: ProbeSnapshot] = [:]
    private var views: [ProbeSerial: PredictionView] = [:]
    private var instances: [String: Tracked] = [:]
    private var pending: [String: Pending] = [:]
    private var history: [ProbeSerial: [CoreSample]] = [:]
    private var cooks: [ProbeSerial: CookState] = [:]
    private var held = false

    private enum Outgoing {
        case event(AlertEvent)
        case keepAwake(Bool)
    }

    private var outbox: [Outgoing] = []
    private var draining = false
    private var wake: Task<Void, Never>?
    private var inputs: [Task<Void, Never>] = []

    /// - Parameters:
    ///   - defaultRules: the set seeded for a probe that has never had rules; nil seeds nothing.
    public init(
        clock: any Clock, ruleStore: any AlertRuleStore = InMemoryAlertRuleStore(), sinks: [any AlertSink] = [],
        keepAwake: (any KeepAwake)? = nil, silencer: (any ProbeAlarmSilencing)? = nil,
        trace: (any TraceSink)? = nil,
        defaultRules: (@Sendable (ProbeSerial) -> [AlertRule])? = { AlertRule.defaults(for: $0) },
        cookIdleTimeout: Duration = AlertEngine.cookIdleTimeout
    ) {
        self.clock = clock
        self.ruleStore = ruleStore
        self.sinks = sinks
        self.keepAwake = keepAwake
        self.silencer = silencer
        self.trace = trace
        self.defaultRules = defaultRules
        self.cookIdle = cookIdleTimeout.totalSeconds
    }

    deinit {
        wake?.cancel()
        for t in inputs { t.cancel() }
    }

    // MARK: Observables

    /// Every state change, in order.
    public nonisolated var events: AsyncStream<AlertEvent> { eventBroadcaster.stream() }

    /// Alerts that are firing, acknowledged or snoozed, most urgent first; the latest list first, then changes.
    public nonisolated var active: AsyncStream<[AlertInstance]> { activeBroadcaster.stream() }

    /// Right now, most urgent first (overheat > probe alarms > prediction done > others; newest first within a level).
    public func activeAlerts() -> [AlertInstance] { sortedActive() }

    // MARK: Lifecycle

    /// Subscribes to the inputs. Call once; the streams are consumed until `stop()`.
    public func start(
        probes: AsyncStream<[ProbeSerial: ProbeSnapshot]>, predictions: AsyncStream<PredictionUpdate>,
        followed: AsyncStream<Set<ProbeSerial>>
    ) {
        guard inputs.isEmpty else { return }
        inputs.append(Task { [weak self] in
            for await map in probes {
                guard let self else { return }
                await self.ingest(snapshots: map)
            }
        })
        inputs.append(Task { [weak self] in
            for await u in predictions {
                guard let self else { return }
                await self.ingest(prediction: u.view)
            }
        })
        inputs.append(Task { [weak self] in
            for await set in followed {
                guard let self else { return }
                await self.setFollowed(set)
            }
        })
    }

    /// Stops listening and timing, releases keep-awake. Alerts stay as they are.
    public func stop() async {
        for t in inputs { t.cancel() }
        inputs = []
        wake?.cancel()
        wake = nil
        if held {
            held = false
            await keepAwake?.setHeld(false)
        }
    }

    // MARK: Rules

    public func rules(_ serial: ProbeSerial) async -> [AlertRule] {
        await loadRules(serial)
        return ruleSets[serial] ?? []
    }

    public func addRule(_ serial: ProbeSerial, _ rule: AlertRule) async {
        await loadRules(serial)
        var rules = ruleSets[serial] ?? []
        rules.removeAll { $0.id == rule.id }
        rules.append(rule)
        await changed(serial, rules)
    }

    /// Replaces the rule with the same id. Changing the kind or disabling it clears its alert.
    public func updateRule(_ serial: ProbeSerial, _ rule: AlertRule) async {
        await loadRules(serial)
        var rules = ruleSets[serial] ?? []
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        if rules[i].kind != rule.kind { forget(rule.id, serial: serial) }
        rules[i] = rule
        await changed(serial, rules)
    }

    public func removeRule(_ serial: ProbeSerial, id: String) async {
        await loadRules(serial)
        var rules = ruleSets[serial] ?? []
        rules.removeAll { $0.id == id }
        await changed(serial, rules)
    }

    // MARK: Acknowledge, snooze, silence

    /// Stops the sound and keeps the alert in `active` until its condition clears. A probe alarm also silences
    /// the probe (and so its Display and phone).
    public func acknowledge(_ id: String) async {
        guard let t = instances[id], t.instance.state == .firing || t.instance.state == .snoozed else { return }
        let now = clock.now()
        transition(id, to: .acknowledged, at: now)
        await drainOutbox()
        if case .probeAlarm = t.instance.source { await silenceProbe(t.instance.serial, ids: [id]) }
    }

    /// Mutes a firing alert for `duration`; it fires again then if the condition still holds. Local only: a probe
    /// alarm keeps sounding on the probe.
    public func snooze(_ id: String, duration: Duration) async {
        guard let t = instances[id], t.instance.state == .firing else { return }
        let now = clock.now()
        instances[id]?.instance.snoozedUntil = now.addingTimeInterval(duration.totalSeconds)
        transition(id, to: .snoozed, at: now)
        scheduleWake()
        await drainOutbox()
    }

    /// Acknowledges everything firing for the probe; sends one Silence Alarms if any probe alarm was among them.
    public func silenceAll(_ serial: ProbeSerial) async {
        let now = clock.now()
        let mine = instances.values.filter {
            $0.instance.serial == serial && ($0.instance.state == .firing || $0.instance.state == .snoozed)
        }.map(\.instance)
        for a in mine { transition(a.id, to: .acknowledged, at: now) }
        await drainOutbox()
        let probeAlarms = mine.filter { if case .probeAlarm = $0.source { true } else { false } }.map(\.id)
        if !probeAlarms.isEmpty { await silenceProbe(serial, ids: probeAlarms) }
    }

    private func silenceProbe(_ serial: ProbeSerial, ids: [String]) async {
        guard let silencer else { return }
        do {
            try await silencer.silenceAlarms(serial)
        } catch {
            // The probe is still alarming: the app must not stay quiet about it.
            let now = clock.now()
            for id in ids where instances[id]?.instance.state == .acknowledged {
                transition(id, to: .firing, at: now, failure: String(describing: error))
            }
            await drainOutbox()
        }
    }

    // MARK: Inputs

    public func setFollowed(_ set: Set<ProbeSerial>) async {
        let added = set.subtracting(followedSet)
        let removed = followedSet.subtracting(set)
        followedSet = set
        for serial in removed { dropProbe(serial) }
        for serial in added.sorted() { await loadRules(serial, seed: true) }
        for serial in added.sorted() { evaluate(serial) }
        finishRound()
        await drainOutbox()
    }

    public func ingest(snapshots map: [ProbeSerial: ProbeSnapshot]) async {
        for (serial, snap) in map where snapshots[serial] != snap {
            snapshots[serial] = snap
            recordCore(serial, snap)
            evaluate(serial)
        }
        finishRound()
        await drainOutbox()
    }

    public func ingest(snapshot snap: ProbeSnapshot) async {
        await ingest(snapshots: [snap.serial: snap])
    }

    public func ingest(prediction view: PredictionView) async {
        guard views[view.serial] != view else { return }
        views[view.serial] = view
        evaluate(view.serial)
        finishRound()
        await drainOutbox()
    }

    // MARK: Rule storage

    /// Makes sure the probe's rules are in memory; with `seed`, a never-configured probe gets the default set.
    private func loadRules(_ serial: ProbeSerial, seed: Bool = false) async {
        if ruleSets[serial] != nil { return }
        if let stored = await ruleStore.loadRules(for: serial) {
            ruleSets[serial] = stored
        } else if seed, let defaults = defaultRules {
            let rules = defaults(serial)
            ruleSets[serial] = rules
            await ruleStore.saveRules(rules, for: serial)
        } else if ruleSets[serial] == nil {
            ruleSets[serial] = []
        }
    }

    private func changed(_ serial: ProbeSerial, _ rules: [AlertRule]) async {
        ruleSets[serial] = rules
        await ruleStore.saveRules(rules, for: serial)
        evaluate(serial)
        finishRound()
        await drainOutbox()
    }

    private func forget(_ id: String, serial: ProbeSerial) {
        guard instances[id] != nil else { return }
        transition(id, to: .idle, at: clock.now())
        pending[id] = nil
    }

    // MARK: Evaluation

    private func recordCore(_ serial: ProbeSerial, _ snap: ProbeSnapshot) {
        guard !snap.isOffline, let core = snap.virtual.core else { return }
        let now = clock.now()
        var samples = history[serial] ?? []
        if let last = samples.last, now.timeIntervalSince(last.time) < Self.historyStep { return }
        samples.append(CoreSample(time: now, celsius: core))
        let longest = (ruleSets[serial] ?? []).compactMap { rule -> TimeInterval? in
            if case .stall(let window, _) = rule.kind { return window }
            return nil
        }.max() ?? 0
        let keep = max(Self.minHistory, longest + 60)
        // Keep one sample older than the span: it is the reference for a window that exactly fills it.
        if let firstInSpan = samples.firstIndex(where: { now.timeIntervalSince($0.time) <= keep }), firstInSpan > 1 {
            samples.removeFirst(firstInSpan - 1)
        }
        history[serial] = samples
    }

    private func evaluate(_ serial: ProbeSerial) {
        guard followedSet.contains(serial) else { return }
        let now = clock.now()
        guard let snap = snapshots[serial] else { return }
        updateCook(serial, snap, now: now)

        var desired: [String: Desired] = [:]
        var unknown: Set<String> = []

        for rule in ruleSets[serial] ?? [] where rule.enabled {
            let wasActive = instances[rule.id] != nil
            let input = RuleInput(
                snapshot: snap, prediction: views[serial], now: now, wasActive: wasActive,
                cookActive: cooks[serial]?.active ?? false, coreHistory: history[serial] ?? [])
            if let outcome = RuleEvaluator.evaluate(rule.kind, input) {
                desired[rule.id] = Desired(
                    source: .rule(rule.kind), outcome: outcome, sustain: rule.kind.sustain,
                    latch: rule.kind.latchesUntilAcknowledged)
            } else {
                unknown.insert(rule.id)
            }
        }

        // Probe alarms and overheat come from the probe's own status; without a source they say nothing current.
        let online = !snap.isOffline
        if let alarms = snap.alarms {
            for (kind, set) in [(AlarmKind.high, alarms.high), (.low, alarms.low)] {
                for channel in AlarmChannel.allCases {
                    guard online, set[channel]?.alarming == true else { continue }
                    desired[Self.alarmId(serial, kind, channel)] = Desired(
                        source: .probeAlarm(kind: kind, channel: channel),
                        outcome: RuleOutcome(met: true, value: set[channel]?.temperature), sustain: 0, latch: false)
                }
            }
        } else {
            // No full status yet: nothing to clear, nothing to fire.
            for id in instances.keys where instances[id]?.instance.serial == serial {
                if case .probeAlarm? = instances[id]?.instance.source { unknown.insert(id) }
            }
        }
        if online {
            for sensor in snap.overheating {
                desired[Self.overheatId(serial, sensor)] = Desired(
                    source: .overheat(sensor), outcome: RuleOutcome(met: true, value: snap.temperatures[Int(sensor.rawValue)]),
                    sustain: 0, latch: false)
            }
        }

        for (id, d) in desired.sorted(by: { $0.key < $1.key }) { apply(id, serial, d, now: now) }

        for (id, t) in instances where t.instance.serial == serial && desired[id] == nil {
            if unknown.contains(id) {
                // Unknown condition: keep the alert, but a snooze that ran out ends in a firing alert.
                if t.instance.state == .snoozed, let until = t.instance.snoozedUntil, now >= until { refire(id, now: now) }
            } else {
                transition(id, to: .idle, at: now)
            }
        }
        for id in Array(pending.keys) where desired[id] == nil { pending[id] = nil }
    }

    private func apply(_ id: String, _ serial: ProbeSerial, _ d: Desired, now: Date) {
        if d.outcome.met {
            if var t = instances[id] {
                t.instance.value = d.outcome.value ?? t.instance.value
                instances[id] = t
                if t.instance.state == .snoozed, let until = t.instance.snoozedUntil, now >= until { refire(id, now: now) }
                return
            }
            var p = pending[id] ?? Pending(since: d.outcome.since ?? now, sustain: d.sustain)
            p.sustain = d.sustain
            if let since = d.outcome.since { p.since = since }
            pending[id] = p
            guard now.timeIntervalSince(p.since) >= d.sustain - Self.epsilon else { return }
            pending[id] = nil
            instances[id] = Tracked(instance: AlertInstance(
                id: id, serial: serial, source: d.source, state: .idle, firedAt: now, value: d.outcome.value))
            transition(id, to: .firing, at: now)
        } else {
            pending[id] = nil
            guard let t = instances[id] else { return }
            // A latched alert outlives its condition until someone acknowledges it.
            if d.latch && (t.instance.state == .firing || t.instance.state == .snoozed) {
                if t.instance.state == .snoozed, let until = t.instance.snoozedUntil, now >= until { refire(id, now: now) }
                return
            }
            transition(id, to: .idle, at: now)
        }
    }

    private func refire(_ id: String, now: Date) {
        instances[id]?.instance.snoozedUntil = nil
        transition(id, to: .firing, at: now)
    }

    // MARK: Transitions

    /// Applies a state change and queues its event. `idle` removes the alert.
    private func transition(_ id: String, to new: AlertState, at now: Date, failure: String? = nil) {
        guard var t = instances[id] else { return }
        let from = t.instance.state
        guard from != new else { return }
        t.instance.state = new
        switch new {
        case .firing:
            if from == .idle { t.instance.firedAt = now }
            t.instance.snoozedUntil = nil
        case .acknowledged:
            t.instance.acknowledgedAt = now
            t.instance.snoozedUntil = nil
        case .snoozed, .idle:
            break
        }
        if new == .idle {
            instances[id] = nil
        } else {
            instances[id] = t
        }
        let event = AlertEvent(instance: t.instance, from: from, to: new, at: now, failure: failure)
        outbox.append(.event(event))
        eventBroadcaster.send(event)
        trace?.emit("alert", [
            "rule": .string(id), "serial": .serial(t.instance.serial.rawValue),
            "transition": .string(event.transition), "value": t.instance.value.map { .double($0) } ?? .null,
        ])
    }

    private func dropProbe(_ serial: ProbeSerial) {
        let now = clock.now()
        for (id, t) in instances where t.instance.serial == serial { transition(id, to: .idle, at: now) }
        for id in Array(pending.keys) where id.hasPrefix(serial.hex + ".") { pending[id] = nil }
        cooks[serial] = nil
        history[serial] = nil
    }

    // MARK: Cook activity and keep-awake

    private func updateCook(_ serial: ProbeSerial, _ snap: ProbeSnapshot, now: Date) {
        var c = cooks[serial] ?? CookState()
        if !snap.isOffline {
            c.active = RuleEvaluator.isCooking(snap)
            if c.active { c.lastActive = now }
        } else if c.active, let last = c.lastActive, now.timeIntervalSince(last) >= cookIdle - Self.epsilon {
            c.active = false
        }
        cooks[serial] = c
    }

    /// After a round of evaluations: publish the active list, update keep-awake, set the next wake-up.
    private func finishRound() {
        activeBroadcaster.send(sortedActive())
        scheduleWake()
        let want = followedSet.contains { cooks[$0]?.active == true }
        if want != held {
            held = want
            outbox.append(.keepAwake(want))
        }
    }

    private func sortedActive() -> [AlertInstance] {
        instances.values.map(\.instance).sorted {
            if $0.priority != $1.priority { return $0.priority > $1.priority }
            if $0.firedAt != $1.firedAt { return $0.firedAt > $1.firedAt }
            return $0.id < $1.id
        }
    }

    // MARK: Timing

    /// One sleeper for the earliest of: a sustain that is about to be met, a snooze that ends, a quiet cook that
    /// stops counting.
    private func scheduleWake() {
        wake?.cancel()
        wake = nil
        let now = clock.now()
        var times: [Date] = pending.values.map(\.deadline)
        times += instances.values.compactMap { $0.instance.state == .snoozed ? $0.instance.snoozedUntil : nil }
        for (serial, c) in cooks where c.active && snapshots[serial]?.isOffline == true {
            if let last = c.lastActive { times.append(last.addingTimeInterval(cookIdle)) }
        }
        guard let next = times.filter({ $0 > now }).min() else { return }
        let delay = max(next.timeIntervalSince(now), 0.001)
        let clock = self.clock
        wake = Task { [weak self] in
            do { try await clock.sleep(for: .seconds(delay)) } catch { return }
            await self?.wakeUp()
        }
    }

    private func wakeUp() async {
        for serial in followedSet.sorted() { evaluate(serial) }
        finishRound()
        await drainOutbox()
    }

    // MARK: Delivery

    /// Delivers queued events to the sinks in order. One drain at a time keeps the order when calls overlap.
    private func drainOutbox() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while !outbox.isEmpty {
            switch outbox.removeFirst() {
            case .event(let event):
                for sink in sinks { await sink.deliver(event) }
            case .keepAwake(let on):
                await keepAwake?.setHeld(on)
            }
        }
    }

    // MARK: Ids

    static func alarmId(_ serial: ProbeSerial, _ kind: AlarmKind, _ channel: AlarmChannel) -> String {
        "\(serial.hex).alarm.\(kind == .high ? "high" : "low").\(channel)"
    }

    static func overheatId(_ serial: ProbeSerial, _ sensor: SensorIndex) -> String {
        "\(serial.hex).overheat.t\(sensor.rawValue + 1)"
    }
}
