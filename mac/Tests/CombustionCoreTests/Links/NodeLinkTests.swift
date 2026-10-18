import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

private func status(core: Double = 54.35, logMax: UInt32 = 10, session: SessionInfo? = nil) -> ProbeStatusPayload {
    ProbeStatusPayload(
        logRange: LogRange(min: 0, max: logMax),
        temperatures: try! ProbeTemperatures(celsius: (0..<8).map { _ in core }),
        mode: .normal, color: .yellow, probeNumber: 1, batteryLow: false,
        virtualSensors: try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8),
        prediction: PredictionStatus(
            state: .predicting, mode: .timeToRemoval, type: .removal,
            setpoint: 60, heatStart: 20, rawSecondsRemaining: 1800, estimatedCore: 50),
        foodSafe: FoodSafe(mode: .simplified, product: 1, serving: .servedImmediately, state: .notSafe),
        overheating: [], preferences: ThermometerPreferences(powerMode: .normal, highRadioPower: true),
        alarms: AlarmConfig(), session: session)
}

/// A node `0x45` notification for `probe`.
private func probeStatusFrame(
    _ probe: ProbeSerial = linkProbe, hops: Int = 1, core: Double = 54.35, session: SessionInfo? = nil
) -> [UInt8] {
    let payload = try! encodeNodeProbeStatus(NodeProbeStatus(serial: probe, status: status(core: core, session: session), hopCount: hops))
    return try! UartFrame(variant: .node, direction: .request, messageType: UartMessageType.probeStatus,
                          requestId: 0, payload: payload).encoded()
}

private func heartbeatFrame(_ payload: [UInt8] = [1, 2, 3]) -> [UInt8] {
    try! UartFrame(variant: .node, direction: .request, messageType: UartMessageType.heartbeat,
                   requestId: 0, payload: payload).encoded()
}

private let nodeSerial: NodeSerial = "DISPLAY001"

struct NodeLinkTests {
    private func makeLink(_ rig: LinkRig, ids: LinkIdSequence = LinkIdSequence()) -> NodeLink {
        NodeLink(serial: nodeSerial, productType: .display, connection: rig.connection, clock: rig.clock,
                 requestIds: { ids.next() })
    }

    @Test func probeStatusBecomesNodeConnectionObservation() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        try await link.start()
        let session = SessionInfo(sessionId: 42, samplePeriodMs: 5000)
        rig.notify(probeStatusFrame(hops: 3, session: session))
        let o = try #require(await firstValue(obs))
        #expect(o.serial == linkProbe)
        #expect(o.source.kind == .nodeConnection)
        #expect(o.source.via == nodeSerial)
        #expect(o.source.hopCount == 3)
        #expect(o.source.highRadioPower == true)
        #expect(o.source.lastSeen == rig.clock.now())
        #expect(o.receivedAt == rig.clock.now())
        guard case .status(let s) = o.payload else { Issue.record("expected status"); return }
        #expect(s.session == session)
        #expect(s.logRange == LogRange(min: 0, max: 10))
        #expect(abs(s.temperatures[.t1] - 54.35) < 0.05)
    }

    @Test func routesEachProbeSeparatelyAndTracksHops() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        let snaps = link.snapshots
        try await link.start()
        rig.notify(probeStatusFrame(linkProbe, hops: 1, core: 50) + probeStatusFrame(otherProbe, hops: 2, core: 70))
        var it = obs.makeAsyncIterator()
        let a = try #require(await it.next())
        let b = try #require(await it.next())
        #expect([a.serial, b.serial] == [linkProbe, otherProbe])
        #expect([a.source.hopCount, b.source.hopCount] == [1, 2])
        guard case .status(let sa) = a.payload, case .status(let sb) = b.payload else { Issue.record("status"); return }
        #expect(abs(sa.temperatures[.t1] - 50) < 0.05 && abs(sb.temperatures[.t1] - 70) < 0.05)

        // The node's snapshot lists both, ascending, with hop info.
        var latest: NodeSnapshot?
        for await s in snaps where s.probes.count == 2 {
            latest = s
            break
        }
        let snapshot = try #require(latest)
        #expect(snapshot.probes == [linkProbe, otherProbe].sorted())
        #expect(snapshot.hopCounts == [linkProbe: 1, otherProbe: 2])
        #expect(snapshot.isConnected)
        #expect(snapshot.link.kind == .directConnection)
        #expect(snapshot.serial == nodeSerial)
        #expect(snapshot.productType == .display)
    }

    @Test func coverageExpiresAfterTenSeconds() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        try await link.start()
        #expect(!link.covers(linkProbe))
        rig.notify(probeStatusFrame(hops: 2))
        _ = await firstValue(obs)
        #expect(link.covers(linkProbe))
        #expect(!link.covers(otherProbe))
        #expect(link.hops(to: linkProbe) == 2)
        await rig.clock.advance(by: .seconds(9))
        #expect(link.covers(linkProbe))
        await rig.clock.advance(by: .seconds(2))
        #expect(!link.covers(linkProbe))
        #expect(link.hops(to: linkProbe) == nil)
    }

    @Test func heartbeatsAreCountedAndRetireStaleProbes() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        let snaps = link.snapshots
        try await link.start()
        rig.notify(probeStatusFrame())
        _ = await firstValue(obs)
        await rig.clock.advance(by: .seconds(12))
        rig.notify(heartbeatFrame([7, 7]))
        var it = snaps.makeAsyncIterator()
        var last: NodeSnapshot?
        while let s = await it.next() {
            last = s
            if s.heartbeatCount == 1 { break }
        }
        let snapshot = try #require(last)
        #expect(snapshot.heartbeatCount == 1)
        #expect(snapshot.lastHeartbeat == rig.clock.now())
        #expect(snapshot.probes.isEmpty, "the probe has not been relayed for 12 s")
        #expect(await link.lastHeartbeatPayload == [7, 7])
        #expect(await link.snapshot.heartbeatCount == 1)
        // Neither message disturbs the request machinery.
        #expect(await link.uart.diagnostics.ignoredFrames == 0)
    }

    @Test func undecodableStatusIsCounted() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        try await link.start()
        let junk = try UartFrame(variant: .node, direction: .request, messageType: UartMessageType.probeStatus,
                                 requestId: 0, payload: [1, 2, 3, 4]).encoded()
        rig.notify(junk + probeStatusFrame())
        _ = await firstValue(obs)
        #expect(await link.statusDecodeErrors == 1)
    }

    @Test func unknownNotificationsAreIgnored() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        try await link.start()
        let other = try UartFrame(variant: .node, direction: .request, messageType: 0x4A, requestId: 0, payload: [1]).encoded()
        rig.notify(other + probeStatusFrame())
        let o = try #require(await firstValue(obs))
        #expect(o.serial == linkProbe)
        #expect(await link.statusDecodeErrors == 0)
    }

    @Test func readLogsAreAddressedToTheProbeAndOtherProbesRecordsIgnored() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        try await link.start()
        let responseIds = LinkIdSequence(start: 9000)
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .node), case .readLogs(let s, let e) = msg.request,
                  let id = msg.requestId, msg.probe == linkProbe else { return [] }
            var out = (s...e).map { nodeLogReply($0, probe: linkProbe, requestId: id, responseId: responseIds.next()) }
            // Another probe's record on the same request ID must not be filed under this probe.
            out.insert(nodeLogReply(s, probe: otherProbe, requestId: id, responseId: responseIds.next()), at: 1)
            return out
        }
        let fetcher: any LogFetcher = link
        let records = try await collectLogs(fetcher.readLogs(probe: linkProbe, start: 5, end: 9))
        #expect(records == (5...9).map(linkRecord))
        let written = try decodeWritten(rig.transport.writes[0].bytes, variant: .node)
        #expect(written.probe == linkProbe)
        #expect(written.request == .readLogs(start: 5, end: 9))
    }

    @Test func readSessionInfoGoesThroughTheNode() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        try await link.start()
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .node), msg.request == .readSessionInfo,
                  let id = msg.requestId, let probe = msg.probe else { return [] }
            return [nodeReply(UartMessageType.readSessionInfo, requestId: id, responseId: 1,
                              body: .sessionInfo(probe: probe, linkSession))]
        }
        #expect(try await link.readSessionInfo(probe: otherProbe) == linkSession)
        let written = try decodeWritten(rig.transport.writes[0].bytes, variant: .node)
        #expect(written.probe == otherProbe)
    }

    @Test func missingUartCharacteristicFailsStartAndClosesTheConnection() async throws {
        let rig = try await LinkRig()
        rig.transport.setGattProfile([GattService(uuid: .uartService, characteristics: [.uartRX])])
        let link = makeLink(rig)
        let drops = link.disconnected
        await #expect(throws: TransportError.characteristicNotFound(.uartTX)) { try await link.start() }
        #expect(await firstValue(drops) == .requested)
        let final = await link.snapshot
        #expect(!final.isConnected)
    }

    @Test func linkLossEndsStreamsWithAFinalDisconnectedSnapshot() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        let obs = link.observations
        let snaps = link.snapshots
        let drops = link.disconnected
        try await link.start()
        rig.notify(probeStatusFrame())
        _ = await firstValue(obs)
        #expect(link.covers(linkProbe))

        rig.transport.forceDisconnect(linkPeripheral, reason: .linkLost)
        #expect(await firstValue(drops) == .linkLost)
        var last: NodeSnapshot?
        for await s in snaps { last = s }
        let final = try #require(last)
        #expect(!final.isConnected)
        #expect(final.link.kind == .nodeAdvertisement)
        #expect(final.probes.isEmpty)
        #expect(!link.covers(linkProbe))
        // Streams are finished, and late subscribers still learn the reason.
        var it = obs.makeAsyncIterator()
        #expect(await it.next() == nil)
        #expect(await firstValue(link.disconnected) == .linkLost)
    }

    @Test func deviceInformationIsReadBestEffort() async throws {
        let rig = try await LinkRig()
        rig.transport.setReadValue(Array("v2.0.1".utf8) + [0, 0], characteristic: .firmwareRevision, peripheral: linkPeripheral)
        rig.transport.setReadValue(Array("Display".utf8), characteristic: .modelNumber, peripheral: linkPeripheral)
        let link = makeLink(rig)
        try await link.start()
        await link.loadDeviceInfo()
        #expect(await link.snapshot.firmware == DeviceInfo(firmware: "v2.0.1", hardware: nil, model: "Display"))
    }

    @Test func deviceInformationAbsentLeavesNil() async throws {
        let rig = try await LinkRig()
        let link = makeLink(rig)
        try await link.start()
        await link.loadDeviceInfo()
        #expect(await link.snapshot.firmware == nil)
    }
}

struct NodeStoreTests {
    private func sighting(_ t: Date, rssi: Int = -60) -> NodeSighting {
        NodeSighting(serial: nodeSerial, productType: .display, peripheral: "NODE-1", rssi: rssi, time: t)
    }

    private func connected(_ clock: TestClock) -> NodeSnapshot {
        NodeSnapshot(serial: nodeSerial, productType: .display, probes: [linkProbe], hopCounts: [linkProbe: 1],
                     link: LinkSource(kind: .directConnection, lastSeen: clock.now()), isConnected: true,
                     firmware: DeviceInfo(firmware: "1"), heartbeatCount: 3)
    }

    @Test func sightingCreatesAnAdvertisementOnlyNode() async throws {
        let clock = TestClock()
        let store = ProbeStore(clock: clock)
        await store.ingest(sighting: sighting(clock.now()))
        let n = try #require(await store.nodeSnapshots()[nodeSerial])
        #expect(!n.isConnected)
        #expect(n.link.kind == .nodeAdvertisement)
        #expect(n.link.rssi == -60)
        #expect(n.probes.isEmpty)
    }

    @Test func linkSnapshotReplacesAndASightingNeverDowngradesIt() async throws {
        let clock = TestClock()
        let store = ProbeStore(clock: clock)
        await store.ingest(sighting: sighting(clock.now()))
        await store.ingest(node: connected(clock))
        await store.ingest(sighting: sighting(clock.now(), rssi: -40))
        let n = try #require(await store.nodeSnapshots()[nodeSerial])
        #expect(n.isConnected)
        #expect(n.probes == [linkProbe])
        #expect(n.link.kind == .directConnection)
        #expect(n.link.rssi == nil)
    }

    @Test func firmwareSurvivesDisconnectAndNodesStreamReplaysLatest() async throws {
        let clock = TestClock()
        let store = ProbeStore(clock: clock)
        await store.ingest(node: connected(clock))
        var ended = connected(clock)
        ended.isConnected = false
        ended.firmware = nil
        ended.probes = []
        ended.link.kind = .nodeAdvertisement
        await store.ingest(node: ended)
        var it = store.nodes.makeAsyncIterator()
        let all = try #require(await it.next())
        #expect(all[nodeSerial]?.firmware == DeviceInfo(firmware: "1"))
        #expect(all[nodeSerial]?.isConnected == false)
    }

    @Test func disconnectedNodeNotHeardForTenSecondsIsDropped() async throws {
        let clock = TestClock()
        let store = ProbeStore(clock: clock)
        await store.ingest(sighting: sighting(clock.now()))
        await clock.advance(by: .seconds(5))
        await clock.settle()
        #expect(await store.nodeSnapshots().count == 1)
        await clock.advance(by: .seconds(6))
        await clock.settle()
        #expect(await store.nodeSnapshots().isEmpty)

        // A connected node stays however long it has been quiet.
        await store.ingest(node: connected(clock))
        await clock.advance(by: .seconds(60))
        await clock.settle()
        #expect(await store.nodeSnapshots().count == 1)
        await store.stop()
    }

    @Test func nodeObservationsMergeWithDirectAndRankBelowIt() async throws {
        let clock = TestClock()
        let store = ProbeStore(clock: clock)
        let st = status()
        func obs(_ kind: LinkSource.Kind, via: NodeSerial?, hops: Int?) -> ProbeObservation {
            ProbeObservation(serial: linkProbe, source: LinkSource(kind: kind, via: via, hopCount: hops, lastSeen: clock.now()),
                             payload: .status(st), receivedAt: clock.now())
        }
        await store.ingest(obs(.nodeConnection, via: "N2", hops: 3))
        await store.ingest(obs(.nodeConnection, via: "N1", hops: 1))
        await store.ingest(obs(.nodeAdvertisement, via: "N1", hops: 1))
        var snap = try #require(await store.snapshot(of: linkProbe))
        #expect(snap.link.primary?.via == "N1")
        #expect(snap.link.primary?.kind == .nodeConnection)
        await store.ingest(obs(.directConnection, via: nil, hops: nil))
        snap = try #require(await store.snapshot(of: linkProbe))
        #expect(snap.link.primary?.kind == .directConnection)
        #expect(snap.link.sources.count == 4)
    }
}
