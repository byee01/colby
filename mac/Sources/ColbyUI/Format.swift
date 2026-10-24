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
        for (kind, set) in [("high", config.high), ("low", config.low)] {
            guard let a = set[channel], a.isSet else { continue }
            rows.append(AlarmRow(
                title: "\(name(channel)) \(kind)", value: format.temperature(a.temperature),
                state: a.alarming ? .alarming : a.tripped ? .tripped : .armed))
        }
    }
    return rows
}
