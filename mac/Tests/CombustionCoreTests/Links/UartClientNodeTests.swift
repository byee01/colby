import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

struct UartClientNodeTests {
    /// Echoes the request ID, with Response IDs 9000, 9001, ...
    private func answerSessionInfo(_ rig: LinkRig) {
        let responseIds = LinkIdSequence(start: 9000)
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .node), msg.request == .readSessionInfo,
                  let id = msg.requestId, let probe = msg.probe else { return [] }
            return [nodeReply(UartMessageType.readSessionInfo, requestId: id, responseId: responseIds.next(),
                              body: .sessionInfo(probe: probe, linkSession))]
        }
    }

    @Test func successMatchesOnRequestId() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        answerSessionInfo(rig)
        let r = try await uart.send(.readSessionInfo, probe: linkProbe)
        #expect(r.requestId == 100)
        #expect(r.responseId == 9000)
        #expect(r.body == .sessionInfo(probe: linkProbe, linkSession))
        let written = try decodeWritten(rig.transport.writes[0].bytes, variant: .node)
        #expect(written.requestId == 100)
        #expect(written.probe == linkProbe)
    }

    @Test func eachRequestGetsItsOwnId() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        answerSessionInfo(rig)
        _ = try await uart.send(.readSessionInfo, probe: linkProbe)
        _ = try await uart.send(.readSessionInfo, probe: otherProbe)
        let ids = try rig.transport.writes.map { try decodeWritten($0.bytes, variant: .node).requestId }
        #expect(ids == [100, 101])
    }

    @Test func sameTypeRequestsMayOverlapOnNode() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let a = Task { try await uart.send(.readSessionInfo, probe: linkProbe) }
        let b = Task { try await uart.send(.readSessionInfo, probe: otherProbe) }
        await rig.waitForWrites(2)
        let written = try rig.transport.writes.map { try decodeWritten($0.bytes, variant: .node) }
        #expect(Set(written.compactMap(\.requestId)).count == 2)
        // Answer in reverse write order; each caller still gets its own answer (matched by ID).
        for (n, msg) in written.enumerated().reversed() {
            rig.notify(nodeReply(UartMessageType.readSessionInfo, requestId: try #require(msg.requestId),
                                 responseId: 500 + UInt32(n),
                                 body: .sessionInfo(probe: try #require(msg.probe), linkSession)))
        }
        #expect(try await a.value.body == .sessionInfo(probe: linkProbe, linkSession))
        #expect(try await b.value.body == .sessionInfo(probe: otherProbe, linkSession))
    }

    @Test func failureResponseThrows() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        rig.transport.addResponder { bytes in
            guard let id = try? decodeWritten(bytes, variant: .node).requestId else { return [] }
            return [nodeReply(UartMessageType.silenceAlarms, requestId: id, responseId: 1, success: false)]
        }
        await #expect(throws: UartError.failure) { try await uart.send(.silenceAlarms, probe: linkProbe) }
    }

    @Test func mismatchedRequestIdIsIgnored() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await uart.send(.readSessionInfo, probe: linkProbe) }
        await rig.waitForWrites(1)
        rig.notify(nodeReply(UartMessageType.readSessionInfo, requestId: 7, responseId: 1,
                             body: .sessionInfo(probe: linkProbe, SessionInfo(sessionId: 1, samplePeriodMs: 1))))
        rig.notify(nodeReply(UartMessageType.readSessionInfo, requestId: 100, responseId: 2,
                             body: .sessionInfo(probe: linkProbe, linkSession)))
        #expect(try await task.value.body == .sessionInfo(probe: linkProbe, linkSession))
        #expect(await uart.diagnostics.ignoredFrames == 1)
    }

    @Test func duplicateResponseIdsAreDropped() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        answerSessionInfo(rig)
        rig.transport.duplicateNextNotifications(1)
        _ = try await uart.send(.readSessionInfo, probe: linkProbe)
        await rig.clock.settle()
        let d = await uart.diagnostics
        #expect(d.duplicateResponses == 1)
        #expect(d.ignoredFrames == 0)
    }

    @Test func staleCopyOfAnOldResponseIsDroppedNotMatched() async throws {
        // A late copy of an old response (same Response ID) is dropped even while another request is open.
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node, ids: LinkIdSequence(start: 5))
        let first = nodeReply(UartMessageType.silenceAlarms, requestId: 5, responseId: 77)
        let t1 = Task { try await uart.send(.silenceAlarms, probe: linkProbe) }
        await rig.waitForWrites(1)
        rig.notify(first)
        _ = try await t1.value
        let t2 = Task { try await uart.send(.silenceAlarms, probe: linkProbe) }
        await rig.waitForWrites(2)
        rig.notify(first)
        await rig.clock.settle()
        rig.notify(nodeReply(UartMessageType.silenceAlarms, requestId: 6, responseId: 78))
        #expect(try await t2.value.responseId == 78)
    }

    @Test func timeoutRetryReusesRequestId() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await uart.send(.readSessionInfo, probe: linkProbe) }
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .seconds(3))
        await rig.waitForWrites(2)
        #expect(rig.transport.writes[0].bytes == rig.transport.writes[1].bytes)
        rig.notify(nodeReply(UartMessageType.readSessionInfo, requestId: 100, responseId: 1,
                             body: .sessionInfo(probe: linkProbe, linkSession)))
        _ = try await task.value
    }

    @Test func timeoutExhausted() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await uart.send(.readSessionInfo, probe: linkProbe) }
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .seconds(3))
        await rig.waitForWrites(2)
        await rig.clock.advance(by: .seconds(3))
        await #expect(throws: UartError.timeout) { try await task.value }
    }

    @Test func nodeRequestWithoutProbeIsACodecError() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        await #expect(throws: UartError.codec(.missingField("probe"))) { try await uart.send(.readSessionInfo) }
        #expect(rig.transport.writes.isEmpty)
    }

    @Test func splitNodeResponseIsReassembled() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await uart.send(.readSessionInfo, probe: linkProbe) }
        await rig.waitForWrites(1)
        let reply = nodeReply(UartMessageType.readSessionInfo, requestId: 100, responseId: 1,
                              body: .sessionInfo(probe: linkProbe, linkSession))
        for chunk in stride(from: 0, to: reply.count, by: 4) {
            rig.notify(Array(reply[chunk..<min(chunk + 4, reply.count)]))
        }
        #expect(try await task.value.body == .sessionInfo(probe: linkProbe, linkSession))
    }

    @Test func unsolicitedNodeFramesAreExposed() async throws {
        let rig = try await LinkRig()
        let uart = UartClient(variant: .node, connection: rig.connection, clock: rig.clock)
        let frames = uart.unsolicited
        try await uart.start()
        let status = try UartFrame(variant: .node, direction: .request, messageType: UartMessageType.probeStatus,
                                   requestId: 0, payload: [1, 2, 3, 4]).encoded()
        let heartbeat = try UartFrame(variant: .node, direction: .request, messageType: 0x49,
                                      requestId: 0, payload: [9, 9]).encoded()
        rig.notify(status + heartbeat)
        var it = frames.makeAsyncIterator()
        let a = await it.next()
        let b = await it.next()
        #expect(a?.messageType == 0x45)
        #expect(a?.payload == [1, 2, 3, 4])
        #expect(b?.messageType == 0x49)
        // They never disturb a request.
        #expect(await uart.diagnostics.ignoredFrames == 0)
        await uart.close()
        #expect(await it.next() == nil)
    }

    @Test func disconnectFailsPending() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await uart.send(.readSessionInfo, probe: linkProbe) }
        await rig.waitForWrites(1)
        rig.transport.forceDisconnect(linkPeripheral)
        await #expect(throws: UartError.disconnected) { try await task.value }
    }

    // MARK: readLogs

    @Test func readLogsMatchesOnRequestIdAndFinishesAtEnd() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let responseIds = LinkIdSequence(start: 1)
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .node), case .readLogs(let s, let e) = msg.request,
                  let id = msg.requestId else { return [] }
            // A record for another request interleaved, then ours.
            var out = [nodeLogReply(999, requestId: id &+ 50, responseId: responseIds.next())]
            out += (s...e).map { nodeLogReply($0, requestId: id, responseId: responseIds.next()) }
            return out
        }
        let records = try await collectLogs(uart.readLogs(probe: linkProbe, start: 3, end: 6))
        #expect(records.map(\.sequence) == [3, 4, 5, 6])
    }

    @Test func readLogsIgnoresOtherProbesAndDuplicateCopies() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await collectLogs(uart.readLogs(probe: linkProbe, start: 1, end: 3)) }
        await rig.waitForWrites(1)
        rig.transport.duplicateNextNotifications(3)
        rig.notify(nodeLogReply(1, requestId: 100, responseId: 1))
        rig.notify(nodeLogReply(2, probe: otherProbe, requestId: 100, responseId: 2))
        rig.notify(nodeLogReply(2, requestId: 100, responseId: 3))
        rig.notify(nodeLogReply(3, requestId: 100, responseId: 4))
        #expect(try await task.value.map(\.sequence) == [1, 2, 3])
        #expect(await uart.diagnostics.duplicateResponses == 3)
    }

    @Test func readLogsIdleTimeoutEndsPartialRange() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        var it = uart.readLogs(probe: linkProbe, start: 1, end: 9).makeAsyncIterator()
        await rig.waitForWrites(1)
        rig.notify(nodeLogReply(1, requestId: 100, responseId: 1))
        rig.notify(nodeLogReply(2, requestId: 100, responseId: 2))
        #expect(try await takeLogs(2, from: &it) == [1, 2])
        await rig.clock.advance(by: .seconds(2))
        #expect(try await it.next() == nil)
    }

    @Test func readLogsContinuesPastDroppedNotification() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.node)
        let task = Task { try await collectLogs(uart.readLogs(probe: linkProbe, start: 1, end: 4)) }
        await rig.waitForWrites(1)
        rig.notify(nodeLogReply(1, requestId: 100, responseId: 1))
        rig.transport.dropNextNotifications(1)
        rig.notify(nodeLogReply(2, requestId: 100, responseId: 2))
        rig.notify(nodeLogReply(3, requestId: 100, responseId: 3))
        rig.notify(nodeLogReply(4, requestId: 100, responseId: 4))
        #expect(try await task.value.map(\.sequence) == [1, 3, 4])
    }
}
