import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

struct TraceAndDiagnosticsE2ETests {
    @Test func traceRecordsLinkProbeAndSessionEventsInParityFormat() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 10, sessionId: 3)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(10))
        probe.setInRange(false)
        await rig.run(.seconds(10))
        probe.newSession()
        probe.setInRange(true)
        #expect(await rig.run(until: { await rig.connected(serialA) }, limit: .seconds(30)))
        await rig.run(.seconds(10))

        let lines = rig.trace.lines
        func kinds(_ k: String) -> [String] { lines.filter { $0.contains("\"kind\":\"\(k)\"") } }
        #expect(kinds("link").count == 3) // connected, disconnected, connected
        #expect(kinds("link")[0].contains("\"state\":\"connected\""))
        #expect(kinds("link")[1].contains("\"reason\":\"linkLost\""))
        let sessions = kinds("session")
        #expect(sessions.count == 3) // started 3, ended 3, started 4
        #expect(sessions[0].contains("\"sessionId\":3") && sessions[0].contains("\"transition\":\"started\""))
        #expect(sessions[1].contains("\"sessionId\":3") && sessions[1].contains("\"transition\":\"ended\""))
        #expect(sessions[2].contains("\"sessionId\":4") && sessions[2].contains("\"transition\":\"started\""))
        let probes = kinds("probe")
        #expect(!probes.isEmpty)
        // Keys sorted, serial uppercase hex, floats at most 2 decimals, state named.
        #expect(probes[0].hasPrefix("{\"core\":"))
        #expect(probes[0].contains("\"serial\":\"1000000A\""))
        #expect(probes[0].contains("\"state\":\"notInserted\""))
        await rig.app.stop()
    }

    @Test func diagnosticsReportCountersAndLinkStates() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 300)
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(15))

        var d = await rig.app.diagnostics()
        #expect(d.bluetooth == .poweredOn)
        #expect(d.links == [serialA: .connected])
        #expect(d.advertisements.probePackets > 40)
        #expect(d.advertisements.codecErrors == 0)
        #expect(d.statusDecodeErrors[serialA] == 0)
        #expect(d.uart[serialA] == UartDiagnostics())
        #expect(d.logFetchesInFlight == 0)

        // Counters outlive the link.
        probe.setInRange(false)
        await rig.drain()
        d = await rig.app.diagnostics()
        #expect(d.uart[serialA] != nil)
        #expect(d.links[serialA] != .connected)
        await rig.app.stop()
    }

    @Test func startAndStopAreIdempotentAndStopClosesEverything() async throws {
        let rig = try E2ERig()
        let probe = rig.probe(serialA, preload: 5)
        await rig.app.start()
        await rig.app.start()
        await rig.app.follow(serialA)
        await rig.run(.seconds(10))
        #expect(rig.transport.isConnected(probe.peripheral))
        await rig.app.stop()
        await rig.app.stop()
        #expect(!rig.transport.isConnected(probe.peripheral))
        let attempts = rig.spy.attempts.count
        await rig.run(.seconds(30))
        #expect(rig.spy.attempts.count == attempts)
        // Can start again.
        await rig.app.start()
        await rig.run(.seconds(20))
        #expect(rig.transport.isConnected(probe.peripheral))
        await rig.app.stop()
    }
}
