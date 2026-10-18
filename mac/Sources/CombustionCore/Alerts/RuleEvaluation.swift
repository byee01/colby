import CombustionCodec
import Foundation

/// Where a probe's alert rules are kept between runs (the `alert_rule` table, docs/02 §11).
public protocol AlertRuleStore: Sendable {
    /// nil if the probe has never been configured (the engine then seeds the default set).
    func loadRules(for serial: ProbeSerial) async -> [AlertRule]?
    func saveRules(_ rules: [AlertRule], for serial: ProbeSerial) async
}

public actor InMemoryAlertRuleStore: AlertRuleStore {
    private var stored: [ProbeSerial: [AlertRule]] = [:]

    public init() {}

    public func loadRules(for serial: ProbeSerial) -> [AlertRule]? { stored[serial] }
    public func saveRules(_ rules: [AlertRule], for serial: ProbeSerial) { stored[serial] = rules }
}

/// One timestamped core reading, for the stall rule.
struct CoreSample: Sendable, Equatable {
    var time: Date
    var celsius: Double
}

/// What a rule sees when evaluated.
struct RuleInput {
    var snapshot: ProbeSnapshot
    var prediction: PredictionView?
    var now: Date
    /// The alert for this rule is currently firing, acknowledged or snoozed (selects the clear side of hysteresis).
    var wasActive: Bool
    /// The probe was in a cook when it last had data.
    var cookActive: Bool
    var coreHistory: [CoreSample]
}

/// Outcome of evaluating one rule.
struct RuleOutcome: Equatable {
    /// The condition holds right now.
    var met: Bool
    var value: Double?
    /// Start of the quiet period, if the rule knows it (offline: the last data). nil: since first seen met.
    var since: Date?
}

/// Pure rule logic: snapshot (+ prediction view) in, outcome out. nil means "cannot tell right now" (missing data,
/// stale prediction): the alert keeps whatever state it has.
enum RuleEvaluator {
    /// One quantum of the prediction countdown (rounded to 15 s); keeps `predictionWithin` from flapping.
    static let predictionHysteresis = 15

    static func evaluate(_ kind: AlertRuleKind, _ i: RuleInput) -> RuleOutcome? {
        switch kind {
        case .temperatureAbove(let channel, let limit, let hysteresis):
            guard let t = temperature(channel, i.snapshot) else { return nil }
            return RuleOutcome(met: i.wasActive ? t >= limit - hysteresis : t >= limit, value: t)

        case .temperatureBelow(let channel, let limit, let hysteresis):
            guard let t = temperature(channel, i.snapshot) else { return nil }
            return RuleOutcome(met: i.wasActive ? t <= limit + hysteresis : t <= limit, value: t)

        case .predictionWithin(let seconds):
            guard let p = i.prediction, !p.isStale else { return nil }
            guard let left = p.secondsRemaining else { return RuleOutcome(met: false, value: nil) }
            let limit = i.wasActive ? seconds + predictionHysteresis : seconds
            return RuleOutcome(met: Int(left) <= limit, value: Double(left))

        case .predictionDone:
            guard let p = i.prediction else { return nil }
            return RuleOutcome(met: p.state == .removalPredictionDone && p.type != .resting, value: nil)

        case .restingDone:
            guard let p = i.prediction else { return nil }
            let done = p.type == .resting
                && (p.state == .removalPredictionDone || (p.state == .predicting && p.secondsRemaining == 0))
            return RuleOutcome(met: done, value: nil)

        case .ambientOutOfRange(let low, let high, _):
            guard i.snapshot.mode == .normal, let ambient = i.snapshot.virtual.ambient else { return nil }
            return RuleOutcome(met: ambient < low || ambient > high, value: ambient)

        case .stall(let window, let minRise):
            guard let core = i.snapshot.virtual.core else { return nil }
            let predicting = (i.prediction?.state ?? i.snapshot.prediction?.state) == .predicting
            guard predicting else { return RuleOutcome(met: false, value: nil) }
            // Compare with the newest reading that is at least `window` old; with none, the window is not covered yet.
            guard let ref = i.coreHistory.last(where: { i.now.timeIntervalSince($0.time) >= window - 1 }) else {
                return RuleOutcome(met: false, value: nil)
            }
            let rise = core - ref.celsius
            return RuleOutcome(met: rise < minRise, value: rise)

        case .probeOffline(_, let onlyDuringCook):
            guard i.snapshot.isOffline else { return RuleOutcome(met: false, value: nil) }
            return RuleOutcome(met: !onlyDuringCook || i.cookActive, value: nil, since: i.snapshot.receivedAt)

        case .batteryLow:
            return RuleOutcome(met: i.snapshot.batteryLow, value: nil)
        }
    }

    /// The reading a channel stands for. Instant Read leaves only T1 valid, so the others are nil there.
    static func temperature(_ channel: AlarmChannel, _ s: ProbeSnapshot) -> Double? {
        switch channel {
        case .core: return s.virtual.core
        case .surface: return s.virtual.surface
        case .ambient: return s.virtual.ambient
        default:
            let i = channel.rawValue
            return s.temperatures.indices.contains(i) ? s.temperatures[i] : nil
        }
    }

    /// A probe counts as cooking when it is out of Instant Read and either has a prediction under way or is clearly
    /// hot. Used for keep-awake and for `probeOffline(onlyDuringCook:)`.
    static func isCooking(_ s: ProbeSnapshot) -> Bool {
        guard s.mode == .normal else { return false }
        switch s.prediction?.state {
        case .inserted?, .warming?, .predicting?, .removalPredictionDone?: return true
        default: return (s.virtual.core ?? 0) >= hotCoreCelsius
        }
    }

    /// Without a prediction, a core above this is taken as "in food on the heat".
    static let hotCoreCelsius = 40.0
}
