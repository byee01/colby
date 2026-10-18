import CombustionCore
import Foundation

/// One line of `events.jsonl` (docs/05 §4). `t` is seconds since the start of the recording.
/// `rssi` is used by `adv`; `state` (a `BluetoothState` raw value) by `state` events.
public struct ReplayEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case adv, notify, write, connect, disconnect, state
    }

    public var t: Double
    public var type: Kind
    public var peripheral: String?
    public var char: String?
    public var hex: String?
    public var rssi: Int?
    public var state: String?

    public init(t: Double, type: Kind, peripheral: String? = nil, char: String? = nil,
                hex: String? = nil, rssi: Int? = nil, state: String? = nil) {
        self.t = t
        self.type = type
        self.peripheral = peripheral
        self.char = char
        self.hex = hex
        self.rssi = rssi
        self.state = state
    }

    public var bytes: [UInt8] { hex.flatMap(HexString.decode) ?? [] }
}

/// `meta.json`: device list, firmware versions, OS, adapter, notes.
public struct ReplayMeta: Codable, Equatable, Sendable {
    public struct Device: Codable, Equatable, Sendable {
        public var peripheral: String
        public var name: String?
        public var firmware: String?
        public init(peripheral: String, name: String? = nil, firmware: String? = nil) {
            self.peripheral = peripheral
            self.name = name
            self.firmware = firmware
        }
    }

    public var formatVersion: Int
    public var name: String?
    public var devices: [Device]
    public var os: String?
    public var adapter: String?
    public var notes: String?

    public init(formatVersion: Int = 1, name: String? = nil, devices: [Device] = [],
                os: String? = nil, adapter: String? = nil, notes: String? = nil) {
        self.formatVersion = formatVersion
        self.name = name
        self.devices = devices
        self.os = os
        self.adapter = adapter
        self.notes = notes
    }
}

public enum ReplayError: Error, Equatable {
    case badLine(number: Int, text: String)
    case missingFile(String)
}

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return e
}

/// Writes a replay directory. Thread-safe; `append` never throws (see `lastError`).
public final class ReplayWriter: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    private var handle: FileHandle?
    private let encoder = makeEncoder()
    private var failure: Error?

    public init(directory: URL, meta: ReplayMeta = ReplayMeta()) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pretty = makeEncoder()
        pretty.outputFormatting.insert(.prettyPrinted)
        try pretty.encode(meta).write(to: directory.appendingPathComponent("meta.json"))
        let events = directory.appendingPathComponent("events.jsonl")
        _ = FileManager.default.createFile(atPath: events.path, contents: nil)
        handle = try FileHandle(forWritingTo: events)
    }

    public var lastError: Error? { lock.withLock { failure } }

    public func append(_ event: ReplayEvent) {
        var event = event
        event.t = (event.t * 1000).rounded() / 1000
        lock.withLock {
            guard let handle else { return }
            do {
                var data = try encoder.encode(event)
                data.append(0x0A)
                try handle.write(contentsOf: data)
            } catch {
                failure = error
            }
        }
    }

    public func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

public struct ReplayReader: Sendable {
    public let meta: ReplayMeta
    public let events: [ReplayEvent]

    public init(directory: URL) throws {
        let metaURL = directory.appendingPathComponent("meta.json")
        let eventsURL = directory.appendingPathComponent("events.jsonl")
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { throw ReplayError.missingFile("events.jsonl") }
        if FileManager.default.fileExists(atPath: metaURL.path) {
            meta = try JSONDecoder().decode(ReplayMeta.self, from: Data(contentsOf: metaURL))
        } else {
            meta = ReplayMeta()
        }
        let text = try String(contentsOf: eventsURL, encoding: .utf8)
        let decoder = JSONDecoder()
        var parsed: [ReplayEvent] = []
        for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            guard let event = try? decoder.decode(ReplayEvent.self, from: Data(line.utf8)) else {
                throw ReplayError.badLine(number: i + 1, text: String(line))
            }
            parsed.append(event)
        }
        events = parsed
    }
}
