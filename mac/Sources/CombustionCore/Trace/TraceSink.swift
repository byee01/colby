import Foundation

/// A value in a parity trace line (docs/05 §3).
public enum TraceValue: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    /// Rendered as an 8-char uppercase hex string.
    case serial(UInt32)
}

public protocol TraceSink: Sendable {
    /// Records one observable output. The sink adds `t` and `kind`.
    func emit(_ kind: String, _ fields: [String: TraceValue])
}

/// One JSON object per line, keys sorted, floats rounded to 2 decimals
/// (trailing zeros trimmed), `t` = clock seconds since the sink was created,
/// rounded to 3 decimals (ms) as in the docs/05 example.
public final class JSONLTraceSink: TraceSink, @unchecked Sendable {
    private let clock: any Clock
    private let origin: Duration
    private let lock = NSLock()
    private var storedLines: [String] = []
    private var file: FileHandle?

    public init(clock: any Clock, fileURL: URL? = nil) throws {
        self.clock = clock
        self.origin = clock.monotonic()
        if let fileURL {
            _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            file = try FileHandle(forWritingTo: fileURL)
        }
    }

    public var lines: [String] { lock.withLock { storedLines } }

    public func close() {
        lock.withLock {
            try? file?.close()
            file = nil
        }
    }

    public func emit(_ kind: String, _ fields: [String: TraceValue]) {
        var all = fields
        all["kind"] = .string(kind)
        all["t"] = .double((clock.monotonic() - origin).totalSeconds)
        let line = Self.render(all)
        lock.withLock {
            storedLines.append(line)
            try? file?.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    static func render(_ fields: [String: TraceValue]) -> String {
        let parts = fields.keys.sorted().map { key in
            let value = fields[key]!
            let decimals = key == "t" ? 3 : 2
            return "\(quote(key)):\(render(value, decimals: decimals))"
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    static func render(_ v: TraceValue, decimals: Int) -> String {
        switch v {
        case .string(let s): return quote(s)
        case .int(let i): return String(i)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .serial(let s): return quote(String(format: "%08X", s))
        case .double(let d): return number(d, decimals: decimals)
        }
    }

    static func number(_ d: Double, decimals: Int) -> String {
        guard d.isFinite else { return "null" }
        var s = String(format: "%.\(decimals)f", d)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }
}
