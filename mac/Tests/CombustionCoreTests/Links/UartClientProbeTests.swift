import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

struct UartClientProbeTests {
    /// Answers session-info requests like a probe would.
    private func answerSessionInfo(_ rig: LinkRig) {
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .probe), msg.request == .readSessionInfo else { return [] }
            return [probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession))]
        }
    }

    @Test func successReturnsDecodedResponse() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        answerSessionInfo(rig)
        let r = try await uart.send(.readSessionInfo)
        #expect(r.body == .sessionInfo(probe: nil, linkSession))
        #expect(rig.transport.writes.count == 1)
        #expect(rig.transport.writes[0].characteristic == .uartRX)
        #expect(try decodeWritten(rig.transport.writes[0].bytes, variant: .probe).request == .readSessionInfo)
    }

    @Test func successZeroThrowsFailure() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        rig.transport.addResponder { _ in [probeReply(UartMessageType.silenceAlarms, success: false)] }
        await #expect(throws: UartError.failure) { try await uart.send(.silenceAlarms) }
    }

    @Test func timeoutThenRetrySucceeds() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .seconds(3))
        await rig.waitForWrites(2)
        #expect(rig.transport.writes[0].bytes == rig.transport.writes[1].bytes)
        rig.notify(probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession)))
        let r = try await task.value
        #expect(r.body == .sessionInfo(probe: nil, linkSession))
    }

    @Test func timeoutExhaustedThrowsTimeout() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .seconds(3))
        await rig.waitForWrites(2)
        await rig.clock.advance(by: .seconds(3))
        await #expect(throws: UartError.timeout) { try await task.value }
        #expect(rig.transport.writes.count == 2)
        // The slot is free again.
        answerSessionInfo(rig)
        _ = try await uart.send(.readSessionInfo)
    }

    @Test func customTimeoutAndNoRetries() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.silenceAlarms, timeout: .milliseconds(500), retries: 0) }
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .milliseconds(499))
        await rig.clock.advance(by: .milliseconds(1))
        await #expect(throws: UartError.timeout) { try await task.value }
        #expect(rig.transport.writes.count == 1)
    }

    @Test func splitNotificationsAreReassembled() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        let reply = probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession))
        rig.notify(Array(reply[0..<3]))
        rig.notify(Array(reply[3..<9]))
        rig.notify(Array(reply[9...]))
        #expect(try await task.value.body == .sessionInfo(probe: nil, linkSession))
    }

    @Test func mergedNotificationsRouteBothResponses() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let a = Task { try await uart.send(.readSessionInfo) }
        let b = Task { try await uart.send(.silenceAlarms) }
        await rig.waitForWrites(2)
        rig.notify(probeReply(UartMessageType.silenceAlarms)
            + probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession)))
        #expect(try await a.value.body == .sessionInfo(probe: nil, linkSession))
        #expect(try await b.value.body == .ack)
    }

    @Test func secondRequestOfSameTypeIsBusy() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let first = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        await #expect(throws: UartError.busy) { try await uart.send(.readSessionInfo) }
        // A different type is allowed alongside.
        let other = Task { try await uart.send(.silenceAlarms) }
        await rig.waitForWrites(2)
        rig.notify(probeReply(UartMessageType.silenceAlarms))
        _ = try await other.value
        rig.notify(probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession)))
        _ = try await first.value
        #expect(rig.transport.writes.count == 2)
    }

    @Test func responseOfUnexpectedTypeIsIgnored() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        rig.notify(probeReply(UartMessageType.silenceAlarms))
        rig.notify(probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession)))
        _ = try await task.value
        #expect(await uart.diagnostics.ignoredFrames == 1)
    }

    @Test func garbageIsCountedAndSkipped() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        rig.notify([0x01, 0x02, 0x03])
        rig.notify(probeReply(UartMessageType.readSessionInfo, body: .sessionInfo(probe: nil, linkSession)))
        _ = try await task.value
        #expect(await uart.diagnostics.framingErrors >= 1)
    }

    @Test func malformedMatchingResponseFailsWithCodecError() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        // Session info needs 6 payload bytes; send 2.
        let short = try UartFrame(variant: .probe, direction: .response, messageType: UartMessageType.readSessionInfo,
                                  success: true, payload: [1, 2]).encoded()
        rig.notify(short)
        await #expect(throws: UartError.codec(.tooShort(expected: 6, actual: 2))) { try await task.value }
        #expect(await uart.diagnostics.codecErrors == 1)
    }

    @Test func disconnectFailsPendingRequests() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        rig.transport.forceDisconnect(linkPeripheral)
        await #expect(throws: UartError.disconnected) { try await task.value }
        await #expect(throws: UartError.disconnected) { try await uart.send(.silenceAlarms) }
    }

    @Test func cancellationReleasesTheSlot() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await uart.send(.readSessionInfo) }
        await rig.waitForWrites(1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        answerSessionInfo(rig)
        _ = try await uart.send(.readSessionInfo)
    }

    @Test func largeRequestIsChunkedToMtuMinusThree() async throws {
        let rig = try await LinkRig(mtu: 23)
        let uart = try await rig.makeUart(.probe)
        rig.transport.addResponder { _ in [probeReply(UartMessageType.setAlarms)] }
        let config = AlarmConfig(high: [.t1: Alarm(isSet: true, temperature: 90)])
        _ = try await uart.send(.setAlarms(config))
        let writes = rig.transport.writes
        #expect(writes.count > 1)
        #expect(writes.allSatisfy { $0.bytes.count <= 20 })
        let whole = writes.flatMap(\.bytes)
        #expect(whole == (try encodeRequest(variant: .probe, .setAlarms(config))))
    }

    // MARK: readLogs

    private func answerLogs(_ rig: LinkRig, upTo limit: UInt32? = nil) {
        rig.transport.addResponder { bytes in
            guard let msg = try? decodeWritten(bytes, variant: .probe),
                  case .readLogs(let start, let end) = msg.request else { return [] }
            return (start...min(end, limit ?? end)).map(probeLogReply)
        }
    }

    @Test func readLogsCompleteRangeFinishesAtEnd() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        answerLogs(rig)
        let records = try await collectLogs(uart.readLogs(start: 10, end: 14))
        #expect(records.map(\.sequence) == [10, 11, 12, 13, 14])
        #expect(records[0] == linkRecord(10))
        // Finished on the sequence number, not on a timer.
        #expect(rig.clock.sleeperCount == 0)
        let write = try decodeWritten(rig.transport.writes[0].bytes, variant: .probe)
        #expect(write.request == .readLogs(start: 10, end: 14))
    }

    @Test func readLogsIdleTimeoutEndsPartialRange() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        answerLogs(rig, upTo: 12)
        var it = uart.readLogs(start: 10, end: 20).makeAsyncIterator()
        #expect(try await takeLogs(3, from: &it) == [10, 11, 12])
        await rig.clock.advance(by: .milliseconds(1999))
        await rig.clock.advance(by: .milliseconds(1))
        #expect(try await it.next() == nil)
    }

    @Test func readLogsIdleTimerRestartsOnEachRecord() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        var it = uart.readLogs(start: 1, end: 3, idleTimeout: .seconds(2)).makeAsyncIterator()
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .milliseconds(1500))
        rig.notify(probeLogReply(1))
        #expect(try await it.next()?.sequence == 1)
        await rig.clock.advance(by: .milliseconds(1500))
        rig.notify(probeLogReply(2))
        #expect(try await it.next()?.sequence == 2)
        await rig.clock.advance(by: .milliseconds(1500))
        rig.notify(probeLogReply(3))
        #expect(try await it.next()?.sequence == 3)
        #expect(try await it.next() == nil)
    }

    @Test func readLogsContinuesPastDroppedNotification() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await collectLogs(uart.readLogs(start: 1, end: 5)) }
        await rig.waitForWrites(1)
        rig.notify(probeLogReply(1))
        rig.notify(probeLogReply(2))
        rig.transport.dropNextNotifications(1)
        rig.notify(probeLogReply(3))
        rig.notify(probeLogReply(4))
        rig.notify(probeLogReply(5))
        #expect(try await task.value.map(\.sequence) == [1, 2, 4, 5])
    }

    @Test func readLogsDroppedLastRecordEndsOnIdleTimeout() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        var it = uart.readLogs(start: 1, end: 3).makeAsyncIterator()
        await rig.waitForWrites(1)
        rig.notify(probeLogReply(1))
        rig.notify(probeLogReply(2))
        rig.transport.dropNextNotifications(1)
        rig.notify(probeLogReply(3))
        #expect(try await takeLogs(2, from: &it) == [1, 2])
        await rig.clock.advance(by: .seconds(2))
        #expect(try await it.next() == nil)
    }

    @Test func readLogsDropsDuplicateNotifications() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await collectLogs(uart.readLogs(start: 1, end: 3)) }
        await rig.waitForWrites(1)
        rig.transport.duplicateNextNotifications(2)
        rig.notify(probeLogReply(1))
        rig.notify(probeLogReply(2))
        rig.notify(probeLogReply(3))
        #expect(try await task.value.map(\.sequence) == [1, 2, 3])
    }

    @Test func readLogsWithNoRecordsTimesOut() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await collectLogs(uart.readLogs(start: 1, end: 3)) }
        await rig.waitForWrites(1)
        await rig.clock.advance(by: .seconds(2))
        await #expect(throws: UartError.timeout) { try await task.value }
    }

    @Test func readLogsFailureResponseThrows() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        rig.transport.addResponder { _ in [probeReply(UartMessageType.readLogs, success: false)] }
        await #expect(throws: UartError.failure) { try await collectLogs(uart.readLogs(start: 1, end: 3)) }
    }

    @Test func readLogsSecondConcurrentRequestIsBusy() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let first = Task { try await collectLogs(uart.readLogs(start: 1, end: 2)) }
        await rig.waitForWrites(1)
        await #expect(throws: UartError.busy) { try await collectLogs(uart.readLogs(start: 5, end: 6)) }
        rig.notify(probeLogReply(1))
        rig.notify(probeLogReply(2))
        #expect(try await first.value.count == 2)
    }

    @Test func readLogsDisconnectMidDownloadThrows() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let stream = uart.readLogs(start: 1, end: 5)
        await rig.waitForWrites(1)
        rig.notify(probeLogReply(1))
        rig.transport.forceDisconnect(linkPeripheral)
        var got: [UInt32] = []
        do {
            for try await r in stream { got.append(r.sequence) }
            Issue.record("expected an error")
        } catch {
            #expect(error as? UartError == .disconnected)
        }
        #expect(got == [1])
    }

    @Test func cancellingTheLogConsumerReleasesTheSlot() async throws {
        let rig = try await LinkRig()
        let uart = try await rig.makeUart(.probe)
        let task = Task { try await collectLogs(uart.readLogs(start: 1, end: 5)) }
        await rig.waitForWrites(1)
        task.cancel()
        _ = await task.result
        await rig.clock.settle()
        answerLogs(rig)
        #expect(try await collectLogs(uart.readLogs(start: 1, end: 2)).map(\.sequence) == [1, 2])
    }
}
