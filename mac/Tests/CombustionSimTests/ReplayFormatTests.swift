import CombustionCore
import CombustionSim
import Foundation
import Testing

struct ReplayFormatTests {
    @Test func writesDocumentedLineFormatWithSortedKeys() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = try ReplayWriter(directory: dir, meta: ReplayMeta(name: "n", devices: [.init(peripheral: "P", firmware: "1.2")]))
        w.append(ReplayEvent(t: 0.0834, type: .adv, peripheral: "P", hex: "C709", rssi: -61))
        w.append(ReplayEvent(t: 1, type: .notify, peripheral: "P", char: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E", hex: "CAFE"))
        w.append(ReplayEvent(t: 2, type: .state, state: "poweredOff"))
        w.close()
        let lines = try String(contentsOf: dir.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(lines == [
            #"{"hex":"C709","peripheral":"P","rssi":-61,"t":0.083,"type":"adv"}"#,
            #"{"char":"6E400003-B5A3-F393-E0A9-E50E24DCCA9E","hex":"CAFE","peripheral":"P","t":1,"type":"notify"}"#,
            #"{"state":"poweredOff","t":2,"type":"state"}"#,
        ])
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
    }

    @Test func readerRoundTrip() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let meta = ReplayMeta(name: "cook", devices: [.init(peripheral: "P", name: "Predictive", firmware: "1.0")],
                              os: "macOS 14", adapter: "built-in", notes: "x")
        let events = [
            ReplayEvent(t: 0, type: .connect, peripheral: "P"),
            ReplayEvent(t: 0.5, type: .write, peripheral: "P", char: "C", hex: "00FF"),
            ReplayEvent(t: 1.25, type: .disconnect, peripheral: "P"),
        ]
        let w = try ReplayWriter(directory: dir, meta: meta)
        events.forEach(w.append)
        w.close()
        let r = try ReplayReader(directory: dir)
        #expect(r.meta == meta)
        #expect(r.events == events)
        #expect(r.events[1].bytes == [0x00, 0xFF])
    }

    @Test func readerReportsBadLineNumber() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "{\"t\":0,\"type\":\"adv\"}\nnot json\n".write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        #expect(throws: ReplayError.badLine(number: 2, text: "not json")) { try ReplayReader(directory: dir) }
    }

    @Test func readerRequiresEventsFileButMetaIsOptional() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(throws: ReplayError.missingFile("events.jsonl")) { try ReplayReader(directory: dir) }
        try "".write(to: dir.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8)
        let r = try ReplayReader(directory: dir)
        #expect(r.events.isEmpty)
        #expect(r.meta == ReplayMeta())
    }
}
