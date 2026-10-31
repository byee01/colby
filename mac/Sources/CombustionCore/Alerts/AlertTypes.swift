import CombustionCodec
import Foundation

/// The app-side alert rules of v1. docs/02 §9.
public enum AlertRuleKind: Sendable, Equatable {
    /// Fires when the channel reaches `celsius`; clears below `celsius - hysteresis`.
    case temperatureAbove(channel: AlarmChannel, celsius: Double, hysteresis: Double = 1)
    /// Fires when the channel falls to `celsius`; clears above `celsius + hysteresis`.
    case temperatureBelow(channel: AlarmChannel, celsius: Double, hysteresis: Double = 1)
    /// Fires when the countdown is at or under `seconds`.
    case predictionWithin(seconds: Int)
    /// Fires when the removal prediction is done. Stays firing until acknowledged.
    case predictionDone
    /// Fires when the resting prediction reaches 0. Stays firing until acknowledged.
    case restingDone
    /// Ambient outside `min...max` for `sustain` seconds.
    case ambientOutOfRange(min: Double, max: Double, sustain: TimeInterval)
    /// While predicting, the core rose by less than `minRise` °C over `window` seconds.
    case stall(window: TimeInterval = 1800, minRise: Double)
    /// No source delivered data for `seconds`. With `onlyDuringCook` it fires only if the probe was in a cook
    /// when it went quiet (the default alert set uses this, 06 §6).
    case probeOffline(seconds: TimeInterval = 60, onlyDuringCook: Bool = false)
    case batteryLow

    /// How long the condition must hold, uninterrupted, before the alert fires.
    var sustain: TimeInterval {
        switch self {
        case .ambientOutOfRange(_, _, let s): return s
        case .probeOffline(let s, _): return s
        default: return 0
        }
    }

    /// Event-like rules: once fired they stay until acknowledged, even if the condition goes away
    /// ("Ready" repeats until acknowledged, 06 §6).
    var latchesUntilAcknowledged: Bool {
        switch self {
        case .predictionDone, .restingDone: return true
        default: return false
        }
    }
}

public struct AlertRule: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: AlertRuleKind
    public var enabled: Bool

    public init(id: String = UUID().uuidString, kind: AlertRuleKind, enabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
    }

    /// The alert set a probe gets when first followed (06 §6): Ready, 5-minute warning, Disconnected (only during
    /// a cook), Low battery. Overheat and probe alarms are always on and are not rules.
    public static func defaults(for serial: ProbeSerial) -> [AlertRule] {
        [
            AlertRule(id: "\(serial.hex).ready", kind: .predictionDone),
            AlertRule(id: "\(serial.hex).fiveMinutes", kind: .predictionWithin(seconds: 300)),
            AlertRule(id: "\(serial.hex).offline", kind: .probeOffline(seconds: 60, onlyDuringCook: true)),
            AlertRule(id: "\(serial.hex).battery", kind: .batteryLow),
        ]
    }
}

/// Where an alert comes from.
public enum AlertSource: Sendable, Equatable {
    case rule(AlertRuleKind)
    /// A probe alarm whose `alarming` bit is set. Acknowledging it silences the probe (0x0C).
    case probeAlarm(kind: AlarmKind, channel: AlarmChannel)
    /// The probe's overheat bit for a sensor. Cannot be silenced on the probe.
    case overheat(SensorIndex)
}

/// Sort order when several fire: overheat > probe alarms > prediction done > everything else (06 §7).
public enum AlertPriority: Int, Sendable, Comparable {
    case other, predictionDone, probeAlarm, overheat

    public static func < (a: AlertPriority, b: AlertPriority) -> Bool { a.rawValue < b.rawValue }
}

/// docs/02 §9 state machine. `idle` is never stored in `active`; it appears as the start or end of an event.
public enum AlertState: Sendable, Equatable {
    case idle, firing, acknowledged, snoozed

    var name: String {
        switch self {
        case .idle: return "idle"
        case .firing: return "firing"
        case .acknowledged: return "acknowledged"
        case .snoozed: return "snoozed"
        }
    }
}

/// The sound a sink should play for an alert (06 §17.3). Ready, Overheat and probe alarms loop until
/// acknowledged; the rest play once each time the alert fires.
public enum AlertSound: Sendable, Equatable, CaseIterable {
    case ready, overheat, probeAlarm
    /// A countdown rule (`predictionWithin`), e.g. the default 5-minute warning.
    case countdown
    /// Probe offline or battery low.
    case problem
    /// Any other rule: temperature, ambient range, stall.
    case custom

    public init(for source: AlertSource) {
        switch source {
        case .overheat: self = .overheat
        case .probeAlarm: self = .probeAlarm
        case .rule(.predictionDone), .rule(.restingDone): self = .ready
        case .rule(.predictionWithin): self = .countdown
        case .rule(.probeOffline), .rule(.batteryLow): self = .problem
        case .rule: self = .custom
        }
    }

    public var loops: Bool {
        switch self {
        case .ready, .overheat, .probeAlarm: return true
        case .countdown, .problem, .custom: return false
        }
    }
}

public struct AlertInstance: Sendable, Equatable, Identifiable {
    /// A rule's id for rule alerts; `<serial>.alarm.<high|low>.<channel>` and `<serial>.overheat.<sensor>` otherwise.
    public var id: String
    public var serial: ProbeSerial
    public var source: AlertSource
    public var state: AlertState
    public var firedAt: Date
    public var acknowledgedAt: Date?
    public var snoozedUntil: Date?
    /// The reading that tripped it (°C for temperatures, seconds for countdowns), latest while firing.
    public var value: Double?

    public var priority: AlertPriority {
        switch source {
        case .overheat: return .overheat
        case .probeAlarm: return .probeAlarm
        case .rule(.predictionDone), .rule(.restingDone): return .predictionDone
        case .rule: return .other
        }
    }

    public var sound: AlertSound { AlertSound(for: source) }
}

/// One state change of an alert. `instance` is the alert after the change (state `idle` when it cleared).
public struct AlertEvent: Sendable, Equatable {
    public var instance: AlertInstance
    public var from: AlertState
    public var to: AlertState
    public var at: Date
    /// Set when a probe silence failed and the alert went back to firing.
    public var failure: String?

    /// `"idle->firing"`, as in the parity trace (docs/05 §3).
    public var transition: String { "\(from.name)->\(to.name)" }
}
