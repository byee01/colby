import CombustionCodec
import Foundation

/// Merge state of one probe: many sources in, one `ProbeSnapshot` out. docs/02 §6.1. Pure (no clock, no I/O);
/// `ProbeStore` supplies arrival times.
///
/// - Live fields (color, probe number, battery, overheating) come from the freshest observation of any kind.
///   An absent overheating byte keeps the previous value.
/// - Mode: a probe out of the charger interleaves Instant Read and Normal packets several times a second
///   (fw v2.3.3, docs/07). As in the iOS SDK, Normal packets set T1-T8 and virtual sensors, Instant Read packets
///   set only the filtered Instant Read value, and the probe counts as in Instant Read until
///   `instantReadStale` passes without an Instant Read packet.
/// - Status-only fields (prediction, alarms, food safe, session/log range) come from the freshest full status.
///   Advertisements never touch them, and they survive loss of every source (the probe is shown offline).
/// - Freshness is `ProbeObservation.receivedAt`; ties go to the later arrival.
struct ProbeMerger {
    struct Entry {
        var source: LinkSource
        var arrivedAt: Date
    }

    private struct Live {
        var color: ProbeColor
        var probeNumber: Int
        var batteryLow: Bool
        var virtualSensors: VirtualSensors
        var overheating: Set<SensorIndex>
        var receivedAt: Date
    }

    /// Latest Normal (or Error) mode packet: the only source of T1-T8.
    private struct Normal {
        var temperatures: ProbeTemperatures
        var mode: ProbeMode
        var virtualSensors: VirtualSensors
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
    private var normal: Normal?
    private var status: StatusPart?
    private var filter = InstantReadFilter()
    /// Last Instant Read packet: its time and raw T1.
    private var instant: (at: Date, t1: Double?)?

    /// The iOS SDK uses 5 s, but while a link is up the probe advertises far less (~0.8/s instead of ~4/s) and
    /// Instant Read packets come 5-10 s apart, so 5 s made the mode (and the app's Instant Read view) flip every
    /// few seconds on hardware (2026-10-23). 15 s covers the gaps seen; leaving Instant Read shows 15 s late.
    static let instantReadStale: TimeInterval = 15

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
        live = Live(color: color, probeNumber: probeNumber, batteryLow: batteryLow, virtualSensors: virtualSensors,
                    overheating: overheating ?? live?.overheating ?? [], receivedAt: receivedAt)
        if mode == .instantRead {
            // Only T1 is meaningful. The filter restarts after Instant Read went stale.
            if !instantActive(at: receivedAt) { filter = InstantReadFilter() }
            filter.addReading(temperatures[.t1])
            instant = (receivedAt, temperatures[.t1])
        } else {
            normal = Normal(temperatures: temperatures, mode: mode, virtualSensors: virtualSensors,
                            receivedAt: receivedAt)
        }
    }

    private func instantActive(at time: Date) -> Bool {
        guard let instant else { return false }
        return time.timeIntervalSince(instant.at) < Self.instantReadStale
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
        let instantOn = instantActive(at: live.receivedAt)
        // T1-T8 from the last Normal packet, however old (Normal packets can be 18 s apart in Instant Read, see
        // spec/replays/instant-read; the iOS SDK keeps them too). Before the first one, T1 from Instant Read alone.
        let temps: [Double?] = normal.map { $0.temperatures.celsius.map { $0 } }
            ?? [instant?.t1] + Array(repeating: nil, count: 7)
        let vs = normal?.virtualSensors ?? live.virtualSensors
        let virtual = VirtualTemps(
            coreSensor: vs.core, surfaceSensor: vs.surface, ambientSensor: vs.ambient,
            core: temps[Int(vs.core.rawValue)], surface: temps[Int(vs.surface.rawValue)],
            ambient: temps[Int(vs.ambient.rawValue)])
        let ordered = sources.values.map(\.source).sorted(by: Self.precedes)
        return ProbeSnapshot(
            serial: serial, probeNumber: live.probeNumber, color: live.color,
            mode: instantOn ? .instantRead : normal?.mode ?? .normal,
            temperatures: temps,
            instantRead: instantOn ? filter.celsius : nil,
            instantReadFahrenheit: instantOn ? filter.fahrenheit : nil,
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
