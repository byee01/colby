// colby-sim: runs CombustionApp against simulated probes and prints a live table.
//
//   swift run colby-sim [--probes 3] [--speed 120] [--minutes 60] [--preload 300] [--no-wander]
//
// Time is a TestClock advanced in 5 s steps; `--speed` is virtual seconds per real second. Probe 2 leaves
// radio range for a stretch (unless --no-wander) so you can watch it reconnect and backfill.
import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation

struct Options {
    var probes = 3
    var speed = 120.0
    var minutes = 60
    var preload = 300
    var wander = true

    init(_ args: [String]) {
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--probes": probes = it.next().flatMap(Int.init) ?? probes
            case "--speed": speed = it.next().flatMap(Double.init) ?? speed
            case "--minutes": minutes = it.next().flatMap(Int.init) ?? minutes
            case "--preload": preload = it.next().flatMap(Int.init) ?? preload
            case "--no-wander": wander = false
            default:
                print("usage: colby-sim [--probes N] [--speed X] [--minutes M] [--preload RECORDS] [--no-wander]")
                exit(a == "--help" ? 0 : 2)
            }
        }
        probes = min(max(probes, 1), 8)
        speed = max(speed, 1)
    }
}

func describe(_ state: ProbeConnectionState?) -> String {
    switch state {
    case nil: "advert only"
    case .waitingForAdvertisement?: "waiting"
    case .connecting(let n)?: "connecting #\(n)"
    case .connected?: "connected"
    case .backoff(let n, _)?: "backoff #\(n)"
    case .gaveUp?: "gave up"
    }
}

func run(_ options: Options) async throws {
    let clock = TestClock(wakeGrace: .microseconds(200))
    let transport = SimulatedTransport(clock: clock)
    let app = try CombustionApp(transport: transport, clock: clock)

    var probes: [SimulatedProbe] = []
    for i in 0..<options.probes {
        let serial = ProbeSerial(0x1000_0001 + UInt32(i))
        let probe = SimulatedProbe(
            serial: serial, transport: transport, clock: clock, sessionId: UInt32(100 + i),
            probeNumber: i + 1, curve: SimulatedProbe.cookCurve(offset: Double(i) * 3))
        probe.preload(records: options.preload + i * 40)
        probe.start()
        probes.append(probe)
    }

    await app.start()
    // Follow all but the last, so the table shows both advertisement-only and connected probes.
    for probe in probes.dropLast(options.probes > 1 ? 1 : 0) { await app.follow(probe.serial) }

    let total = options.minutes * 60
    let step = 5
    let wander = options.wander && options.probes >= 2 ? (from: total / 5, to: total * 3 / 10) : nil
    var elapsed = 0
    var firstRow = true
    print("colby-sim: \(options.probes) probes, \(options.minutes) virtual minutes at \(options.speed)x")

    while elapsed < total {
        if let wander, elapsed == wander.from - wander.from % step { probes[1].setInRange(false) }
        if let wander, elapsed == wander.to - wander.to % step { probes[1].setInRange(true) }
        await clock.advance(by: .seconds(step))
        await clock.settle()
        elapsed += step
        try await Task.sleep(for: .seconds(Double(step) / options.speed))

        guard elapsed % 60 == 0 else { continue }
        let diagnostics = await app.diagnostics()
        let snapshots = await app.probes.snapshots()
        if firstRow || elapsed % 600 == 0 {
            print(String(format: "\n%-7@ %-9@ %-6@ %-7@ %-7@ %-7@ %-8@ %-8@ %-16@ %@",
                         "t(min)" as NSString, "probe" as NSString, "src" as NSString, "T1" as NSString, "T4" as NSString,
                         "T8" as NSString, "log max" as NSString, "stored" as NSString, "link" as NSString, "session" as NSString))
            firstRow = false
        }
        for probe in probes {
            let snap = snapshots[probe.serial]
            let sessions = (try? await app.history.sessions(serial: probe.serial)) ?? []
            let stored = sessions.first?.sampleCount ?? 0
            func t(_ i: Int) -> String { snap?.temperatures[i].map { String(format: "%.1f", $0) } ?? "-" }
            let source = snap.map { $0.isOffline ? "off" : ($0.link.primary?.kind == .directConnection ? "direct" : "adv") } ?? "-"
            print(String(format: "%-7d %-9@ %-6@ %-7@ %-7@ %-7@ %-8d %-8d %-16@ %@",
                         elapsed / 60, probe.serial.hex as NSString, source as NSString, t(0) as NSString, t(3) as NSString,
                         t(7) as NSString, Int(probe.logRange.max), stored,
                         describe(diagnostics.links[probe.serial]) as NSString,
                         "\(sessions.count) (id \(probe.sessionId))" as NSString))
        }
    }
    await app.stop()
    for probe in probes { probe.stop() }
    print("\ndone")
}

try await run(Options(Array(CommandLine.arguments.dropFirst())))
