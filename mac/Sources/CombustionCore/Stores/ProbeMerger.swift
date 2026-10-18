import CombustionCodec
import Foundation

/// Merge state of one probe: many sources in, one `ProbeSnapshot` out. docs/02 §6.1. Pure (no clock, no I/O);
/// `ProbeStore` supplies arrival times.
///
/// - Live fields (temperatures, mode, color, probe number, battery, virtual sensors, overheating) come from the
///   freshest observation of any kind. An absent overheating byte keeps the previous value.
/// - Status-only fields (prediction, alarms, food safe, session/log range) come from the freshest full status.
///   Advertisements never touch them, and they survive loss of every source (the probe is shown offline).
/// - Freshness is `ProbeObservation.receivedAt`; ties go to the later arrival.
struct ProbeMerger {
    struct Entry {
        var source: LinkSource
        var arrivedAt: Date
    }

    private struct Live {
        var temperatures: ProbeTemperatures
        var mode: ProbeMode
        var color: ProbeColor
        var probeNumber: Int
        var batteryLow: Bool
        var virtualSensors: VirtualSensors
        var overheating: Set<SensorIndex>
        var receivedAt: Date
    }

    private struct StatusPart {
        var prediction: PredictionStatus
        var alarms: AlarmConfig?
        var foodSafe: FoodSafe?
        var session: ProbeSessionState
        var receivedAt: Date
    }

    let serial: ProbeSerial
    private(set) var sources: [LinkSource.PathKey: Entry] = [:]
    private var live: Live?
    private var status: StatusPart?
    private var filter = InstantReadFilter()

    init(serial: ProbeSerial) { self.serial = serial }

    /// Returns true if the observation was an accepted (freshest) full status.
    @discardableResult
    mutating func ingest(_ o: ProbeObservation, arrivedAt: Date) -> Bool {
        sources[o.source.pathKey] = Entry(source: o.source, arrivedAt: arrivedAt)

        switch o.payload {
        case .advertisement(let ad):
            acceptLive(receivedAt: o.receivedAt, temperatures: ad.temperatures, mode: ad.mode, color: ad.color,
                       probeNumber: ad.probeNumber, batteryLow: ad.batteryLow, virtualSensors: ad.virtualSensors,
                       overheating: ad.overheating)
            return false
        case .status(let s):
            acceptLive(receivedAt: o.receivedAt, temperatures: s.temperatures, mode: s.mode, color: s.color,
                       probeNumber: s.probeNumber, batteryLow: s.batteryLow, virtualSensors: s.virtualSensors,
                       overheating: s.overheating)
            if let cur = status, o.receivedAt < cur.receivedAt { return false }
            status = StatusPart(
                prediction: s.prediction,
                alarms: s.alarms ?? status?.alarms,
                foodSafe: s.foodSafe ?? status?.foodSafe,
                session: ProbeSessionState(info: s.session, logRange: s.logRange),
                receivedAt: o.receivedAt)
            return true
        }
    }

    private mutating func acceptLive(
        receivedAt: Date, temperatures: ProbeTemperatures, mode: ProbeMode, color: ProbeColor, probeNumber: Int,
        batteryLow: Bool, virtualSensors: VirtualSensors, overheating: Set<SensorIndex>?
    ) {
        if let cur = live, receivedAt < cur.receivedAt { return }
        live = Live(temperatures: temperatures, mode: mode, color: color, probeNumber: probeNumber,
                    batteryLow: batteryLow, virtualSensors: virtualSensors,
                    overheating: overheating ?? live?.overheating ?? [], receivedAt: receivedAt)
        // Instant Read: only T1 is meaningful; filter it. Any other mode resets the filter.
        filter.addReading(mode == .instantRead ? temperatures[.t1] : nil)
    }

    /// Drops sources with no data for `ttl` seconds. Returns true if any was dropped.
    mutating func expire(now: Date, ttl: TimeInterval) -> Bool {
        let before = sources.count
        sources = sources.filter { now.timeIntervalSince($0.value.arrivedAt) < ttl }
        return sources.count != before
    }

    var hasData: Bool { live != nil }

    func snapshot() -> ProbeSnapshot? {
        guard let live else { return nil }
        let instant = live.mode == .instantRead
        let temps: [Double?] = live.temperatures.celsius.enumerated().map { i, c in
            instant && i != 0 ? nil : c
        }
        let vs = live.virtualSensors
        let virtual = VirtualTemps(
            coreSensor: vs.core, surfaceSensor: vs.surface, ambientSensor: vs.ambient,
            core: temps[Int(vs.core.rawValue)], surface: temps[Int(vs.surface.rawValue)],
            ambient: temps[Int(vs.ambient.rawValue)])
        let ordered = sources.values.map(\.source).sorted(by: Self.precedes)
        return ProbeSnapshot(
            serial: serial, probeNumber: live.probeNumber, color: live.color, mode: live.mode,
            temperatures: temps,
            instantRead: instant ? filter.celsius : nil,
            instantReadFahrenheit: instant ? filter.fahrenheit : nil,
            virtual: virtual, batteryLow: live.batteryLow, overheating: live.overheating,
            prediction: status?.prediction, alarms: status?.alarms, foodSafe: status?.foodSafe,
            session: status?.session,
            link: LinkInfo(sources: ordered, primary: ordered.first),
            receivedAt: live.receivedAt)
    }

    // MARK: Source precedence

    /// directConnection > nodeConnection (lowest hop) > advertisement > nodeAdvertisement;
    /// then lowest hop count, freshest, and a stable tiebreak.
    static func precedes(_ a: LinkSource, _ b: LinkSource) -> Bool {
        if rank(a.kind) != rank(b.kind) { return rank(a.kind) < rank(b.kind) }
        let ha = a.hopCount ?? Int.max, hb = b.hopCount ?? Int.max
        if ha != hb { return ha < hb }
        if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
        return (a.via ?? "") < (b.via ?? "")
    }

    private static func rank(_ k: LinkSource.Kind) -> Int {
        switch k {
        case .directConnection: return 0
        case .nodeConnection: return 1
        case .advertisement: return 2
        case .nodeAdvertisement: return 3
        }
    }
}
