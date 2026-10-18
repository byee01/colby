/// Which UART dialect: a probe's own UART (no request IDs) or a MeatNet node's (request/response IDs).
public enum UartVariant: Sendable, Hashable {
    case probe, node
}

public enum UartDirection: Sendable, Hashable {
    case request, response
}

/// One framed UART message with a verified CRC.
///
/// Probe header: sync `CA FE`, CRC u16, type, [success], length. Node header: sync, CRC, type
/// (MSB 1 for responses), request ID u32, [response ID u32, success], length. The CRC covers every
/// byte after itself. Node notifications such as `0x45` arrive as `request`-direction frames.
public struct UartFrame: Sendable, Equatable {
    public var variant: UartVariant
    public var direction: UartDirection
    /// Message type with the node response flag (MSB) removed.
    public var messageType: UInt8
    /// Node only.
    public var requestId: UInt32?
    /// Node responses only.
    public var responseId: UInt32?
    /// Responses only.
    public var success: Bool?
    public var payload: [UInt8]

    public init(
        variant: UartVariant, direction: UartDirection, messageType: UInt8,
        requestId: UInt32? = nil, responseId: UInt32? = nil, success: Bool? = nil, payload: [UInt8] = []
    ) {
        self.variant = variant
        self.direction = direction
        self.messageType = messageType
        self.requestId = requestId
        self.responseId = responseId
        self.success = success
        self.payload = payload
    }

    /// Serializes with sync bytes and CRC. Throws if a header field this variant needs is nil.
    public func encoded() throws -> [UInt8] {
        guard payload.count <= 255 else {
            throw CodecError.outOfRange(field: "payload.length", value: Double(payload.count))
        }
        guard messageType < 0x80 else {
            throw CodecError.outOfRange(field: "messageType", value: Double(messageType))
        }
        let isResponse = direction == .response
        var body = [UInt8]()
        body.append(variant == .node && isResponse ? messageType | 0x80 : messageType)
        if variant == .node {
            guard let requestId else { throw CodecError.missingField("requestId") }
            body.appendU32(requestId)
            if isResponse {
                guard let responseId else { throw CodecError.missingField("responseId") }
                body.appendU32(responseId)
            }
        }
        if isResponse {
            guard let success else { throw CodecError.missingField("success") }
            body.append(success ? 1 : 0)
        }
        body.append(UInt8(payload.count))
        body += payload

        var out: [UInt8] = [0xCA, 0xFE]
        out.appendU16(crc16Ccitt(body))
        return out + body
    }
}

/// What `UartFramer.push` yields: a good frame or a framing problem (`badSync` for skipped garbage,
/// `badCrc` for a frame that failed its CRC).
public enum UartFramerOutput: Sendable, Equatable {
    case frame(UartFrame)
    case error(CodecError)
}

/// Reassembles UART frames from BLE notifications, which may split a frame across several
/// notifications or merge several frames into one. Resynchronizes on `CA FE` after garbage or a bad CRC.
///
/// A probe's UART carries one direction per stream, chosen with `direction` (responses by default).
/// A node's frames say which they are in the type byte, so `direction` is ignored for `.node`.
public struct UartFramer: Sendable {
    public let variant: UartVariant
    public let direction: UartDirection
    private var buffer: [UInt8] = []

    public init(variant: UartVariant, direction: UartDirection = .response) {
        self.variant = variant
        self.direction = direction
    }

    /// Bytes held while waiting for the rest of a frame.
    public var bufferedByteCount: Int { buffer.count }

    public mutating func reset() {
        buffer.removeAll()
    }

    public mutating func push(_ bytes: some Sequence<UInt8>) -> [UartFramerOutput] {
        buffer.append(contentsOf: bytes)
        var out = [UartFramerOutput]()
        while true {
            guard let sync = findSync(from: 0) else {
                dropGarbage(keepingPartialSync: true, into: &out)
                return out
            }
            if sync > 0 { drop(sync, into: &out) }
            switch parse(at: 0) {
            case .frame(let frame, let length):
                out.append(.frame(frame))
                buffer.removeFirst(length)
            case .invalid(let error):
                out.append(.error(error))
                buffer.removeFirst(2)
            case .incomplete:
                // A false sync inside garbage can claim a length that swallows real frames.
                // If a complete valid frame follows, the pending candidate was not a frame.
                guard let later = laterValidFrame() else { return out }
                drop(later, into: &out)
            }
        }
    }

    private enum Parse {
        case frame(UartFrame, length: Int)
        case incomplete
        case invalid(CodecError)
    }

    private func findSync(from start: Int) -> Int? {
        guard buffer.count >= start + 2 else { return nil }
        return (start..<(buffer.count - 1)).first { buffer[$0] == 0xCA && buffer[$0 + 1] == 0xFE }
    }

    private mutating func drop(_ count: Int, into out: inout [UartFramerOutput]) {
        buffer.removeFirst(count)
        out.append(.error(.badSync))
    }

    private mutating func dropGarbage(keepingPartialSync: Bool, into out: inout [UartFramerOutput]) {
        let keep = keepingPartialSync && buffer.last == 0xCA ? 1 : 0
        let count = buffer.count - keep
        if count > 0 { drop(count, into: &out) }
    }

    private func laterValidFrame() -> Int? {
        var from = 1
        while let sync = findSync(from: from) {
            if case .frame = parse(at: sync) { return sync }
            from = sync + 1
        }
        return nil
    }

    private func parse(at start: Int) -> Parse {
        let available = buffer.count - start
        let isResponse: Bool
        let headerLength: Int
        switch variant {
        case .probe:
            isResponse = direction == .response
            headerLength = isResponse ? 7 : 6
        case .node:
            guard available >= 5 else { return .incomplete }
            isResponse = buffer[start + 4] & 0x80 != 0
            headerLength = isResponse ? 15 : 10
        }
        guard available >= headerLength else { return .incomplete }
        let total = headerLength + Int(buffer[start + headerLength - 1])
        guard available >= total else { return .incomplete }

        let frameBytes = Array(buffer[start..<(start + total)])
        let expected = crc16Ccitt(frameBytes[4...])
        let actual = frameBytes.u16(at: 2)
        guard expected == actual else { return .invalid(.badCrc(expected: expected, actual: actual)) }

        var frame = UartFrame(
            variant: variant, direction: isResponse ? .response : .request,
            messageType: variant == .node && isResponse ? frameBytes[4] & 0x7F : frameBytes[4],
            payload: Array(frameBytes[headerLength...]))
        if variant == .node {
            frame.requestId = frameBytes.u32(at: 5)
            if isResponse { frame.responseId = frameBytes.u32(at: 9) }
        }
        if isResponse { frame.success = frameBytes[headerLength - 2] != 0 }
        return .frame(frame, length: total)
    }
}
