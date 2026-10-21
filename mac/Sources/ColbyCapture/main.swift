// colby-capture: records real Combustion devices into a replay directory (docs/07 §2, docs/05 §4).
//
//   swift run colby-capture --name <replay> [--serial HEX]... [--minutes M] [--adv-only] [--direct-only]
//                           [--notes TEXT] [--out DIR]
//
// CoreBluetoothTransport is wrapped in RecordingTransport and driven by a normal CombustionApp, so the default
// policy decides what to connect to. Every probe heard (or only the --serial ones) is followed. With --adv-only
// nothing is followed, so nothing connects. No commands are sent. Ctrl-C ends the capture and writes meta.json.
import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
#if canImport(CoreBluetooth)
import CombustionCoreBluetooth
#endif

struct Options {
    var name = ""
    var serials: Set<String> = []
    var minutes: Int?
    var advOnly = false
    var directOnly = false
    var notes: String?
    var out: URL?

    static let usage = """
        usage: colby-capture --name REPLAY [--serial HEX]... [--minutes M] [--adv-only] [--direct-only]
                             [--notes TEXT] [--out DIR]
        """

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--name": name = it.next() ?? ""
            case "--serial": if let s = it.next() { serials.insert(s.uppercased()) }
            case "--minutes": minutes = it.next().flatMap(Int.init)
            case "--adv-only": advOnly = true
            case "--direct-only": directOnly = true
            case "--notes": notes = it.next()
            case "--out": out = it.next().map { URL(fileURLWithPath: $0) }
            default:
                print(Options.usage)
                exit(a == "--help" ? 0 : 2)
            }
        }
        if name.isEmpty || name.contains("/") {
            print(Options.usage)
            exit(2)
        }
    }
}

func log(_ line: String) {
    FileHandle.standardError.write(Data("\(line)\n".utf8))
}

/// `spec/replays` of the enclosing repository: the first parent of the working directory that has `spec/`.
func defaultReplayRoot() -> URL {
    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    for _ in 0..<4 {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("spec").path) {
            return dir.appendingPathComponent("spec/replays")
        }
        dir.deleteLastPathComponent()
    }
    return URL(fileURLWithPath: "spec/replays")
}

/// `DirectConnectionPolicy` without the MeatNet node step: node sightings never reach it.
actor DirectOnlyPolicy: ConnectionPolicy {
    private let inner = DirectConnectionPolicy()

    func start(_ input: ConnectionPolicyInput) async {
        await inner.start(ConnectionPolicyInput(
            transport: input.transport, clock: input.clock, sightings: input.sightings,
            followed: input.followed, delegate: input.delegate))
    }

    func stop() async { await inner.stop() }
    func states() async -> [ProbeSerial: ProbeConnectionState] { await inner.states() }
    func nodeStates() async -> [NodeSerial: ProbeConnectionState] { await inner.nodeStates() }
}

/// Devices heard, for meta.json and the live table. Peripheral ids are per-Mac CoreBluetooth UUIDs.
actor Sightings {
    struct Device {
        var name: String
        var adverts = 0
        var rssi: Int?
    }

    private(set) var devices: [PeripheralId: Device] = [:]
    private(set) var probes: [ProbeSerial: PeripheralId] = [:]
    private(set) var undecoded = 0

    /// Returns the probe serial when this advert came from a probe itself.
    func ingest(_ adv: RawAdvertisement) -> ProbeSerial? {
        guard let packet = try? decodeAdvertisement(adv.mfrData) else {
            undecoded += 1
            return nil
        }
        let name: String
        var probe: ProbeSerial?
        switch packet {
        case .probe(let p):
            name = "probe \(p.serial.hex)"
            probe = p.serial
            probes[p.serial] = adv.peripheral
        case .repeated(let p, _):
            // A node repeating a probe: the peripheral is the node, named by its own advert.
            name = devices[adv.peripheral]?.name ?? "node (repeating \(p.serial.hex))"
        case .node(let n):
            name = "\(n.productType) \(n.serial)"
        case .unknown(let type):
            name = "unknown product \(type)"
        }
        var d = devices[adv.peripheral] ?? Device(name: name)
        if case .repeated = packet {} else { d.name = name }
        d.adverts += 1
        d.rssi = adv.rssi
        devices[adv.peripheral] = d
        return probe
    }
}

func connectionName(_ state: ProbeConnectionState?) -> String {
    switch state {
    case nil: "-"
    case .waitingForAdvertisement?: "waiting"
    case .connecting(let n)?: "connecting #\(n)"
    case .connected?: "connected"
    case .backoff(let n, _)?: "backoff #\(n)"
    case .gaveUp?: "gave up"
    case .viaNode(let node)?: "via \(node)"
    }
}

func sourceName(_ kind: LinkSource.Kind?) -> String {
    switch kind {
    case .directConnection?: "direct"
    case .nodeConnection?: "node"
    case .nodeAdvertisement?: "n-adv"
    default: "adv"
    }
}

func predictionText(_ p: PredictionStatus?) -> String {
    guard let p else { return "-" }
    switch p.state {
    case .predicting:
        let s = Int(p.rawSecondsRemaining)
        return String(format: "%d:%02d left", s / 60, s % 60)
    case .removalPredictionDone: return "done"
    case .notInserted: return "not inserted"
    case .inserted: return "inserted"
    case .warming: return "warming"
    case .unknown: return "unknown"
    }
}

func temp(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "-" }

/// Left-aligned columns; the last one is not padded.
func row(_ cells: [String]) -> String {
    let widths = [6, 9, 9, 6, 5, 7, 7, 7, 13, 4]
    return zip(cells, widths).map { $0.padding(toLength: max($1, $0.count), withPad: " ", startingAt: 0) }
        .joined(separator: " ") + " " + cells.dropFirst(widths.count).joined(separator: " ")
}

/// Ends on Ctrl-C or after `minutes`.
func waitForEnd(minutes: Int?) async {
    signal(SIGINT, SIG_IGN)
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { continuation.yield() }
    source.resume()
    if let minutes {
        Task {
            try? await Task.sleep(for: .seconds(minutes * 60))
            continuation.yield()
        }
    }
    for await _ in stream { break }
    source.cancel()
}

#if canImport(CoreBluetooth)
func run(_ options: Options) async throws {
    let directory = (options.out ?? defaultReplayRoot()).appendingPathComponent(options.name)
    if FileManager.default.fileExists(atPath: directory.path) {
        log("colby-capture: \(directory.path) exists; pick another --name")
        exit(1)
    }

    let os = ProcessInfo.processInfo.operatingSystemVersionString
    var meta = ReplayMeta(name: options.name, os: "macOS \(os)", adapter: "CoreBluetooth", notes: options.notes)
    let clock = SystemClock()
    let writer = try ReplayWriter(directory: directory, meta: meta)
    let transport = RecordingTransport(inner: CoreBluetoothTransport(clock: clock), writer: writer, clock: clock)
    let app = try CombustionApp(
        transport: transport, clock: clock, policy: options.directOnly ? DirectOnlyPolicy() : nil)
    let sightings = Sightings()

    let states = transport.state
    let stateTask = Task {
        for await s in states {
            log("bluetooth: \(s.rawValue)")
            switch s {
            case .unauthorized:
                log("  allow your terminal app in System Settings > Privacy & Security > Bluetooth, then reopen it")
            case .poweredOff: log("  turn Bluetooth on")
            case .unsupported: log("  this Mac has no Bluetooth LE")
            case .poweredOn: break
            }
        }
    }

    let adverts = transport.advertisements
    let follow = !options.advOnly
    let serialFilter = options.serials
    let advertTask = Task {
        for await adv in adverts {
            guard let serial = await sightings.ingest(adv), follow else { continue }
            if serialFilter.isEmpty || serialFilter.contains(serial.hex.uppercased()) {
                await app.follow(serial)
            }
        }
    }

    await app.start()
    let mode = options.advOnly ? "advertisements only" : options.directOnly ? "direct links only" : "direct + MeatNet"
    print("colby-capture: recording to \(directory.path) (\(mode)). Ctrl-C to stop.")

    let started = Date()
    let tableTask = Task {
        var rows = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { break }
            let snapshots = await app.probes.snapshots()
            let diagnostics = await app.diagnostics()
            let devices = await sightings.devices
            let probes = await sightings.probes
            let elapsed = Int(Date().timeIntervalSince(started))
            if rows % 12 == 0 {
                print("\n" + row(["t", "probe", "id", "src", "rssi", "core", "surface", "ambient", "prediction",
                                  "batt", "link"]))
            }
            rows += 1
            let time = String(format: "%d:%02d", elapsed / 60, elapsed % 60)
            if snapshots.isEmpty {
                print("\(time)   no probes yet (\(devices.count) Combustion devices heard)")
                continue
            }
            for (serial, snap) in snapshots.sorted(by: { $0.key < $1.key }) {
                let rssi = probes[serial].flatMap { devices[$0]?.rssi }.map(String.init) ?? "-"
                let source = snap.isOffline ? "off" : sourceName(snap.link.primary?.kind)
                print(row([time, serial.hex, "\(snap.probeNumber) \(snap.color)", source, rssi, temp(snap.virtual.core),
                           temp(snap.virtual.surface), temp(snap.virtual.ambient), predictionText(snap.prediction),
                           snap.batteryLow ? "low" : "ok", connectionName(diagnostics.links[serial])]))
            }
        }
    }

    await waitForEnd(minutes: options.minutes)
    tableTask.cancel()
    print("\nstopping")
    advertTask.cancel()
    stateTask.cancel()
    let nodes = await app.probes.nodeSnapshots()
    await app.stop()
    transport.stop()

    let devices = await sightings.devices
    meta.devices = devices.sorted(by: { $0.key.rawValue < $1.key.rawValue }).map { peripheral, d in
        let firmware = nodes.values.first { d.name.hasSuffix(" \($0.serial)") }?.firmware?.firmware
        return ReplayMeta.Device(peripheral: peripheral.rawValue, name: d.name, firmware: firmware)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(meta).write(to: directory.appendingPathComponent("meta.json"))
    if let error = writer.lastError { log("colby-capture: write error: \(error)") }

    let events = try ReplayReader(directory: directory).events
    let counts = Dictionary(grouping: events, by: \.type.rawValue).mapValues(\.count)
    print("wrote \(events.count) events to \(directory.path)")
    for (type, n) in counts.sorted(by: { $0.key < $1.key }) { print("  \(type): \(n)") }
    let undecoded = await sightings.undecoded
    if undecoded > 0 { print("  adverts that did not decode: \(undecoded)") }
    print("devices:")
    for d in meta.devices { print("  \(d.name ?? "?")  \(d.peripheral)\(d.firmware.map { "  fw \($0)" } ?? "")") }
    print("add firmware versions for probes to meta.json by hand (from the Combustion phone app)")
}

try await run(Options(Array(CommandLine.arguments.dropFirst())))
#else
log("colby-capture needs CoreBluetooth (macOS)")
exit(1)
#endif
