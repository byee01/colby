import CombustionCodec
import Foundation

/// Virtual sensor selection plus the temperatures it resolves to. docs/02 §3 `virtual`.
/// Temperatures are nil when the underlying sensor has no value (Instant Read except T1).
public struct VirtualTemps: Sendable, Equatable {
    public var coreSensor: SensorIndex
    public var surfaceSensor: SensorIndex
    public var ambientSensor: SensorIndex
    public var core: Double?
    public var surface: Double?
    public var ambient: Double?

    public init(coreSensor: SensorIndex, surfaceSensor: SensorIndex, ambientSensor: SensorIndex,
                core: Double?, surface: Double?, ambient: Double?) {
        self.coreSensor = coreSensor
        self.surfaceSensor = surfaceSensor
        self.ambientSensor = ambientSensor
        self.core = core
        self.surface = surface
        self.ambient = ambient
    }
}

/// Session fields of a full status: the (optional) session identity and the probe's log range.
/// `info` is nil when the probe reports session ID 0 (old firmware or old node).
public struct ProbeSessionState: Sendable, Equatable {
    public var info: SessionInfo?
    public var logRange: LogRange
    public init(info: SessionInfo?, logRange: LogRange) {
        self.info = info
        self.logRange = logRange
    }
}

/// Everything the UI knows about one probe, merged from all sources. docs/02 §3.
public struct ProbeSnapshot: Sendable, Equatable {
    public var serial: ProbeSerial
    public var probeNumber: Int
    public var color: ProbeColor
    public var mode: ProbeMode
    /// T1...T8 in °C. In Instant Read mode only T1 is non-nil.
    public var temperatures: [Double?]
    /// Filtered Instant Read temperature (°C); only in `instantRead` mode.
    public var instantRead: Double?
    /// The same reading filtered on a whole-°F deadband (Android SDK computes both); for °F displays.
    public var instantReadFahrenheit: Double?
    public var virtual: VirtualTemps
    public var batteryLow: Bool
    public var overheating: Set<SensorIndex>
    /// nil if only advertisement data has been seen.
    public var prediction: PredictionStatus?
    /// nil until a full status has been received.
    public var alarms: AlarmConfig?
    public var foodSafe: FoodSafe?
    /// nil until a full status has been received.
    public var session: ProbeSessionState?
    public var link: LinkInfo
    public var receivedAt: Date

    public init(
        serial: ProbeSerial, probeNumber: Int, color: ProbeColor, mode: ProbeMode,
        temperatures: [Double?], instantRead: Double? = nil, instantReadFahrenheit: Double? = nil,
        virtual: VirtualTemps, batteryLow: Bool, overheating: Set<SensorIndex> = [],
        prediction: PredictionStatus? = nil, alarms: AlarmConfig? = nil, foodSafe: FoodSafe? = nil,
        session: ProbeSessionState? = nil, link: LinkInfo, receivedAt: Date
    ) {
        self.serial = serial
        self.probeNumber = probeNumber
        self.color = color
        self.mode = mode
        self.temperatures = temperatures
        self.instantRead = instantRead
        self.instantReadFahrenheit = instantReadFahrenheit
        self.virtual = virtual
        self.batteryLow = batteryLow
        self.overheating = overheating
        self.prediction = prediction
        self.alarms = alarms
        self.foodSafe = foodSafe
        self.session = session
        self.link = link
        self.receivedAt = receivedAt
    }

    /// True when no source is currently delivering data.
    public var isOffline: Bool { link.sources.isEmpty }
}

/// A full status accepted by `ProbeStore`, for `HistoryStore` and session detection.
public struct ProbeStatusEvent: Sendable, Equatable {
    public var serial: ProbeSerial
    public var status: ProbeStatusPayload
    public var receivedAt: Date
    public init(serial: ProbeSerial, status: ProbeStatusPayload, receivedAt: Date) {
        self.serial = serial
        self.status = status
        self.receivedAt = receivedAt
    }
}
