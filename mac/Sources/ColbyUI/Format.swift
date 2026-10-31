import CombustionCodec
import CombustionCore
import Foundation

/// Display unit for temperatures. The core works in °C; the UI converts (docs/02 §18).
public enum TemperatureUnit: String, Sendable, CaseIterable {
    case fahrenheit, celsius

    /// °F where the locale measures in US units, °C elsewhere.
    public static func `default`(for locale: Locale = .current) -> TemperatureUnit {
        locale.measurementSystem == .us ? .fahrenheit : .celsius
    }

    public func convert(_ celsius: Double) -> Double {
        self == .fahrenheit ? celsius * 9 / 5 + 32 : celsius
    }

    public var symbol: String { self == .fahrenheit ? "°F" : "°C" }
}

/// Formatting rules from docs/design/components.md: whole degrees (one decimal for Instant Read), degree sign
/// without a unit letter, `H:MM` durations, clock times in the OS 12/24 h setting.
public struct Formatter: Sendable {
    public var unit: TemperatureUnit
    public var locale: Locale
    public var timeZone: TimeZone

    public static let missing = "—"

    public init(unit: TemperatureUnit, locale: Locale = .current, timeZone: TimeZone = .current) {
        self.unit = unit
        self.locale = locale
        self.timeZone = timeZone
    }

    /// `165°`, or `—` when there is no reading.
    public func temperature(_ celsius: Double?) -> String {
        guard let celsius else { return Self.missing }
        return "\(Int(unit.convert(celsius).rounded()))°"
    }

    /// Integer and decimal part for Instant Read (`165` and `.2°`), drawn at two sizes.
    public func instantRead(_ celsius: Double?) -> (whole: String, fraction: String) {
        guard let celsius else { return (Self.missing, "") }
        let tenths = Int((unit.convert(celsius) * 10).rounded())
        let sign = tenths < 0 ? "-" : ""
        return ("\(sign)\(abs(tenths) / 10)", ".\(abs(tenths) % 10)°")
    }

    /// `203°F`, for sentences and target labels.
    public func temperatureWithUnit(_ celsius: Double) -> String {
        "\(Int(unit.convert(celsius).rounded()))\(unit.symbol)"
    }

    /// Countdown as `H:MM`, minutes rounded up so a running countdown never reads `0:00`.
    public func countdown(_ seconds: UInt32) -> String {
        let minutes = (Int(seconds) + 59) / 60
        return "\(minutes / 60):" + String(format: "%02d", minutes % 60)
    }

    /// `17:02` or `5:02 PM`, following the OS clock setting.
    public func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f.string(from: date)
    }

    /// `3m`, `2h 5m`: how long a probe has been offline.
    public func elapsed(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int(interval) / 60)
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// What the ReadyBlock shows for a prediction (components.md, 06 §4.2).
public struct ReadyText: Equatable, Sendable {
    public enum Tone: Sendable { case normal, ready, muted }
    public var caption: String
    public var primary: String
    public var secondary: String?
    public var tone: Tone

    public init(caption: String, primary: String, secondary: String? = nil, tone: Tone = .normal) {
        self.caption = caption
        self.primary = primary
        self.secondary = secondary
        self.tone = tone
    }

    /// nil when there is nothing to show (no target, not inserted).
    public init?(_ p: PredictionView?, format: Formatter) {
        guard let p else { return nil }
        let tone: Tone = p.isStale ? .muted : .normal
        switch p.state {
        case .predicting:
            guard let s = p.secondsRemaining else {
                self.init(caption: "Predicting", primary: "…", tone: tone)
                return
            }
            self.init(caption: "Ready in", primary: format.countdown(s),
                      secondary: p.readyAt.map { "at " + format.clock($0) }, tone: tone)
        case .removalPredictionDone:
            self.init(caption: p.type == .resting ? "Rested" : "Remove now", primary: "Ready",
                      secondary: p.readySince.map { "since " + format.clock($0) }, tone: p.isStale ? .muted : .ready)
        case .warming:
            // The probe reports warming with no target too (set point 0); nothing to count toward then.
            guard p.mode != .none else { return nil }
            self.init(caption: "Warming", primary: format.temperature(p.estimatedCore),
                      secondary: "to " + format.temperature(p.setpoint), tone: tone)
        case .notInserted, .inserted, .unknown:
            return nil
        }
    }
}

/// The status text at the right of a ProbeChip (06 §4.2).
public func chipStatus(_ snap: ProbeSnapshot, _ p: PredictionView?, now: Date, format: Formatter) -> String? {
    if snap.isOffline { return "Offline " + format.elapsed(now.timeIntervalSince(snap.receivedAt)) }
    if !snap.overheating.isEmpty { return "Overheat" }
    if p?.isStale == true { return "Stale" }
    switch p?.state ?? snap.prediction?.state {
    case .notInserted?: return "Not inserted"
    case .warming?: return "Warming"
    case .predicting?: return p?.secondsRemaining.map(format.countdown)
    case .removalPredictionDone?: return "Ready"
    default: return nil
    }
}

extension ProbeSerial {
    /// Name shown until the user gives the cook a nickname.
    public var displayName: String { "Probe \(hex)" }
}

/// The last `window` seconds of Instant Read readings; cleared when the probe leaves Instant Read.
public struct InstantReadTrail: Equatable, Sendable {
    public struct Point: Equatable, Sendable {
        public var time: Date
        public var celsius: Double
    }

    public private(set) var points: [Point] = []
    public var window: TimeInterval = 30

    public init() {}

    /// `nil` (not in Instant Read) clears the trail. Repeated times are ignored.
    public mutating func add(_ celsius: Double?, at time: Date) {
        guard let celsius else {
            points.removeAll()
            return
        }
        if let last = points.last, time <= last.time { return }
        points.append(Point(time: time, celsius: celsius))
        points.removeAll { time.timeIntervalSince($0.time) > window }
    }
}

/// One probe alarm as the inspector lists it.
public struct AlarmRow: Equatable, Sendable {
    public enum State: Sendable { case armed, tripped, alarming }
    public var kind: AlarmKind
    public var channel: AlarmChannel
    public var title: String
    public var value: String
    public var state: State
}

/// The probe's set alarms: core, surface, ambient, then T1-T8; high before low. Empty when none is set.
public func alarmRows(_ config: AlarmConfig, format: Formatter) -> [AlarmRow] {
    let order: [AlarmChannel] = [.core, .surface, .ambient] + [.t1, .t2, .t3, .t4, .t5, .t6, .t7, .t8]
    func name(_ c: AlarmChannel) -> String {
        switch c {
        case .core: "Core"
        case .surface: "Surface"
        case .ambient: "Ambient"
        default: "T\(c.rawValue + 1)"
        }
    }
    var rows: [AlarmRow] = []
    for channel in order {
        for (kind, set) in [(AlarmKind.high, config.high), (.low, config.low)] {
            guard let a = set[channel], a.isSet else { continue }
            rows.append(AlarmRow(
                kind: kind, channel: channel, title: "\(name(channel)) \(kind == .high ? "high" : "low")", value: format.temperature(a.temperature),
                state: a.alarming ? .alarming : a.tripped ? .tripped : .armed))
        }
    }
    return rows
}

/// The Set target field (06 §5): typed in the user's unit, sent in °C rounded to 0.1, within what the probe takes.
public enum TargetEntry {
    public enum Problem: Error, Equatable, Sendable { case empty, notANumber, outOfRange }

    /// `203` → 95.0 °C. The probe's range is 0–102.3 °C; a value outside it by rounding alone is accepted.
    public static func parse(_ text: String, unit: TemperatureUnit) -> Result<Double, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return .failure(.empty) }
        guard let value = Double(trimmed), value.isFinite else { return .failure(.notANumber) }
        let celsius = unit == .fahrenheit ? (value - 32) * 5 / 9 : value
        let rounded = (celsius * 10).rounded() / 10
        guard rounded >= 0, rounded <= maxPredictionSetpoint + 0.05 else { return .failure(.outOfRange) }
        return .success(min(rounded, maxPredictionSetpoint))
    }

    /// `32–216°F`, the probe's range in the user's unit (whole degrees, inside the limits).
    public static func range(_ unit: TemperatureUnit) -> String {
        let lo = Int(unit.convert(0).rounded(.up)), hi = Int(unit.convert(maxPredictionSetpoint).rounded(.down))
        return "\(lo)–\(hi)\(unit.symbol)"
    }

    /// The field's starting text for a set point already on the probe: whole degrees in the user's unit.
    public static func text(_ celsius: Double, unit: TemperatureUnit) -> String {
        "\(Int(unit.convert(celsius).rounded()))"
    }

    /// Help line under the field: the range, or what is wrong.
    public static func help(_ problem: Problem?, unit: TemperatureUnit) -> String {
        switch problem {
        case .notANumber?: "Enter a number, " + range(unit) + "."
        case .outOfRange?: "The probe takes " + range(unit) + "."
        case .empty?, nil: "Range " + range(unit)
        }
    }
}

/// What the Set target sheet says when a command fails (02 §8).
public func commandFailureText(_ error: any Error) -> String {
    switch error as? CommandError {
    case .notReachable?: "The probe isn't connected. Bring it closer or wait for it to reconnect."
    case .notConfirmed?: "The probe didn't confirm."
    case .outOfRange?: "The probe doesn't take that value."
    case .alarmStateUnknown?: "Waiting for the probe's alarms."
    case .uart?, nil: "Couldn't reach the probe."
    }
}
