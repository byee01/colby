@testable import CombustionCore
import Foundation
import Testing

struct TraceSinkTests {
    @Test func formatsKeysSortedFloatsRoundedSerialUppercaseHex() async throws {
        let clock = TestClock()
        let sink = try JSONLTraceSink(clock: clock)
        await clock.advance(by: .milliseconds(12500))
        sink.emit("probe", ["serial": .serial(0x10005A3F), "core": .double(54.3456), "state": .string("predicting")])
        #expect(sink.lines == [#"{"core":54.35,"kind":"probe","serial":"10005A3F","state":"predicting","t":12.5}"#])
    }

    @Test func timeIsRelativeToSinkCreation() async throws {
        let clock = TestClock()
        await clock.advance(by: .seconds(100))
        let sink = try JSONLTraceSink(clock: clock)
        await clock.advance(by: .milliseconds(61_000))
        sink.emit("alert", ["rule": .string("r1"), "transition": .string("idle->firing"), "value": .double(57.1)])
        #expect(sink.lines == [#"{"kind":"alert","rule":"r1","t":61,"transition":"idle->firing","value":57.1}"#])
    }

    @Test func numberFormatting() {
        func f(_ d: Double) -> String { JSONLTraceSink.number(d, decimals: 2) }
        #expect(f(1815) == "1815")
        #expect(f(57.10) == "57.1")
        #expect(f(0.004) == "0")
        #expect(f(-0.001) == "0")
        #expect(f(-3.456) == "-3.46")
        #expect(f(99.999) == "100")
        #expect(f(.nan) == "null")
        #expect(f(.infinity) == "null")
        #expect(JSONLTraceSink.number(0.0834, decimals: 3) == "0.083")
    }

    @Test func serialsArePaddedToEightDigits() throws {
        let sink = try JSONLTraceSink(clock: TestClock())
        sink.emit("probe", ["serial": .serial(0xABC)])
        #expect(sink.lines[0].contains(#""serial":"00000ABC""#))
    }

    @Test func allValueTypesAndEscaping() throws {
        let sink = try JSONLTraceSink(clock: TestClock())
        sink.emit("x", ["b": .bool(true), "i": .int(-4), "n": .null, "s": .string("a\"b\\c\nd\u{01}")])
        #expect(sink.lines == [#"{"b":true,"i":-4,"kind":"x","n":null,"s":"a\"b\\c\nd\u0001","t":0}"#])
        // Every line must be valid JSON.
        let obj = try JSONSerialization.jsonObject(with: Data(sink.lines[0].utf8)) as? [String: Any]
        #expect(obj?["s"] as? String == "a\"b\\c\nd\u{01}")
    }

    @Test func writesOneLinePerEventToFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = TestClock()
        let sink = try JSONLTraceSink(clock: clock, fileURL: url)
        sink.emit("a", [:])
        await clock.advance(by: .seconds(1))
        sink.emit("b", [:])
        sink.close()
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text == "{\"kind\":\"a\",\"t\":0}\n{\"kind\":\"b\",\"t\":1}\n")
    }

    @Test func hexStringRoundTrip() {
        #expect(HexString.encode([0xCA, 0xFE, 0x00, 0x0F]) == "CAFE000F")
        #expect(HexString.decode("cafe000F") == [0xCA, 0xFE, 0x00, 0x0F])
        #expect(HexString.decode("abc") == nil)
        #expect(HexString.decode("zz") == nil)
        #expect(HexString.decode("") == [])
    }
}
