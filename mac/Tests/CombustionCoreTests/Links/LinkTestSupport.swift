import CombustionCodec
import CombustionCore
import CombustionSim
import Foundation
import Testing

/// Thread-safe counter handing out request IDs 100, 101, ...
final class LinkIdSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt32
    init(start: UInt32 = 100) { value = start }
    func next() -> UInt32 {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}

let linkPeripheral: PeripheralId = "PROBE-1"
let linkProbe = ProbeSerial(0x1000_5A3F)
let otherProbe = ProbeSerial(0x2000_0001)

/// A connected `SimulatedTransport` + `TestClock` pair.
struct LinkRig {
    let clock: TestClock
    let transport: SimulatedTransport
    let connection: any GattConnection

    init(mtu: Int? = nil) async throws {
        clock = TestClock()
        transport = SimulatedTransport(clock: clock)
        if let mtu { transport.setMTU(mtu) }
        connection = try await transport.connect(linkPeripheral, timeout: .seconds(5))
    }

    func makeUart(_ variant: UartVariant, ids: LinkIdSequence = LinkIdSequence()) async throws -> UartClient {
        let uart = UartClient(variant: variant, connection: connection, clock: clock, requestIds: { ids.next() })
        try await uart.start()
        return uart
    }

    /// Lets the code under test run until it has made `count` writes (scheduler turns only, no time).
    func waitForWrites(_ count: Int) async {
        var spins = 0
        while transport.writes.count < count && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        #expect(transport.writes.count >= count, "expected \(count) writes, saw \(transport.writes.count)")
    }

    func notify(_ bytes: [UInt8], on char: GattUUID = .uartTX) {
        transport.injectNotification(peripheral: linkPeripheral, characteristic: char, bytes: bytes)
    }
}

// MARK: Frame builders

func linkRecord(_ seq: UInt32) -> LogRecord {
    LogRecord(
        sequence: seq,
        temperatures: try! ProbeTemperatures(celsius: (0..<8).map { 20 + Double($0) + Double(seq) * 0.05 }),
        prediction: PredictionLog(
            virtualSensors: try! VirtualSensors(core: .t1, surface: .t4, ambient: .t8),
            state: .predicting, mode: .timeToRemoval, type: .removal,
            setpoint: 60, rawSecondsRemaining: 100, estimatedCore: 50))
}

func probeReply(_ type: UInt8, success: Bool = true, body: UartResponse.Body = .ack) -> [UInt8] {
    try! encodeResponse(UartResponse(messageType: type, success: success, body: body), variant: .probe)
}

func probeLogReply(_ seq: UInt32) -> [UInt8] {
    probeReply(UartMessageType.readLogs, body: .logRecord(probe: nil, linkRecord(seq)))
}

let linkSession = SessionInfo(sessionId: 0xABCD, samplePeriodMs: 5000)

func nodeReply(
    _ type: UInt8, requestId: UInt32, responseId: UInt32, success: Bool = true, body: UartResponse.Body = .ack
) -> [UInt8] {
    try! encodeResponse(
        UartResponse(messageType: type, success: success, requestId: requestId, responseId: responseId, body: body),
        variant: .node)
}

func nodeLogReply(_ seq: UInt32, probe: ProbeSerial = linkProbe, requestId: UInt32, responseId: UInt32) -> [UInt8] {
    nodeReply(UartMessageType.readLogs, requestId: requestId, responseId: responseId,
              body: .logRecord(probe: probe, linkRecord(seq)))
}

/// Reads a request the client wrote to UART RX.
func decodeWritten(_ bytes: [UInt8], variant: UartVariant) throws -> UartRequestMessage {
    var framer = UartFramer(variant: variant, direction: .request)
    for case .frame(let frame) in framer.push(bytes) {
        return try decodeRequest(frame)
    }
    throw CodecError.badSync
}

/// Collects a stream to the end.
func collectLogs(_ stream: AsyncThrowingStream<LogRecord, any Error>) async throws -> [LogRecord] {
    var out: [LogRecord] = []
    for try await r in stream { out.append(r) }
    return out
}

func firstValue<T: Sendable>(_ stream: AsyncStream<T>) async -> T? {
    var it = stream.makeAsyncIterator()
    return await it.next()
}

/// Reads exactly `count` records, which also proves the client has processed them (and re-armed its timer).
func takeLogs(_ count: Int, from it: inout AsyncThrowingStream<LogRecord, any Error>.Iterator) async throws -> [UInt32] {
    var out: [UInt32] = []
    for _ in 0..<count {
        if let r = try await it.next() { out.append(r.sequence) }
    }
    return out
}
