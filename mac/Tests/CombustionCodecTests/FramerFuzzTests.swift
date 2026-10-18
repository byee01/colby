import Testing
@testable import CombustionCodec

/// Random streams of valid frames, garbage and damaged frames, cut into random notifications:
/// every valid frame must come out exactly once and in order.
@Suite("Framer fuzz")
struct FramerFuzzTests {
    static let seeds = Array(UInt64(100)...UInt64(399))

    private static func randomFrame(_ r: inout SeededRNG, variant: UartVariant, direction: UartDirection) -> UartFrame {
        let isResponse = variant == .node ? Bool.random(using: &r) : direction == .response
        let length = Bool.random(using: &r) ? Int.random(in: 0...12, using: &r) : Int.random(in: 0...255, using: &r)
        // Payloads often contain sync bytes on purpose.
        let payload = (0..<length).map { _ in [0xCA, 0xFE, UInt8.random(in: 0...255, using: &r)].randomElement(using: &r)! }
        return UartFrame(
            variant: variant, direction: isResponse ? .response : .request,
            messageType: .random(in: 0...0x7F, using: &r),
            requestId: variant == .node ? .random(in: 0...UInt32.max, using: &r) : nil,
            responseId: variant == .node && isResponse ? .random(in: 0...UInt32.max, using: &r) : nil,
            success: isResponse ? Bool.random(using: &r) : nil, payload: payload)
    }

    private static func garbage(_ r: inout SeededRNG) -> [UInt8] {
        (0..<Int.random(in: 1...40, using: &r)).map { _ in
            // Bias toward bytes that look like frame starts.
            [0xCA, 0xFE, 0x00, UInt8.random(in: 0...255, using: &r)].randomElement(using: &r)!
        }
    }

    private static func damaged(_ bytes: [UInt8], _ r: inout SeededRNG) -> [UInt8] {
        var out = bytes
        switch Int.random(in: 0..<3, using: &r) {
        case 0:   // flip one bit anywhere after the sync
            out[Int.random(in: 2..<out.count, using: &r)] ^= 1 << UInt8.random(in: 0..<8, using: &r)
        case 1:   // break the sync
            out[Int.random(in: 0..<2, using: &r)] ^= 0x01
        default:  // cut off the tail
            out.removeLast(Int.random(in: 1..<out.count, using: &r))
        }
        return out
    }

    @Test("valid frames survive garbage, damage and arbitrary chunking", arguments: seeds)
    func fuzz(seed: UInt64) throws {
        var rng = SeededRNG(seed: seed)
        let variant: UartVariant = Bool.random(using: &rng) ? .node : .probe
        let direction: UartDirection = Bool.random(using: &rng) ? .request : .response

        var stream = [UInt8]()
        var expected = [UartFrame]()
        for _ in 0..<Int.random(in: 1...25, using: &rng) {
            if Int.random(in: 0..<3, using: &rng) == 0 { stream += Self.garbage(&rng) }
            let frame = Self.randomFrame(&rng, variant: variant, direction: direction)
            let bytes = try frame.encoded()
            if Int.random(in: 0..<4, using: &rng) == 0 { stream += Self.damaged(bytes, &rng) }
            stream += bytes
            expected.append(frame)
        }

        var framer = UartFramer(variant: variant, direction: direction)
        var received = [UartFrame]()
        var index = 0
        while index < stream.count {
            let size = Int.random(in: 0...Int.random(in: 1...60, using: &rng), using: &rng)
            for case .frame(let frame) in framer.push(stream[index..<min(stream.count, index + size)]) { received.append(frame) }
            index += size
        }
        #expect(received == expected, "seed \(seed): got \(received.count) frames, expected \(expected.count)")
    }

    @Test("a cut-off tail stays buffered until the rest arrives")
    func tailBuffered() throws {
        let frame = UartFrame(variant: .probe, direction: .response, messageType: 3, success: true, payload: Array(1...20))
        let bytes = try frame.encoded()
        var framer = UartFramer(variant: .probe)
        for cut in 1..<bytes.count {
            framer.reset()
            #expect(framer.push(bytes[..<cut]).filter { if case .frame = $0 { true } else { false } }.isEmpty)
            #expect(framer.bufferedByteCount == cut)
            #expect(framer.push(bytes[cut...]) == [.frame(frame)])
            #expect(framer.bufferedByteCount == 0)
        }
    }

    @Test("reset drops buffered bytes")
    func reset() {
        var framer = UartFramer(variant: .node)
        _ = framer.push([0xCA, 0xFE, 0x00])
        #expect(framer.bufferedByteCount == 3)
        framer.reset()
        #expect(framer.bufferedByteCount == 0)
    }
}
