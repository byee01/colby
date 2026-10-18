import Foundation
import Testing
@testable import CombustionCodec

/// A JSON document as a plain value, so expected fixtures and rendered decoder output compare structurally.
enum JSONValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    var description: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return "\(v)"
        case .number(let v): return "\(v)"
        case .string(let v): return "\"\(v)\""
        case .array(let v): return "[" + v.map(\.description).joined(separator: ", ") + "]"
        case .object(let v): return "{" + v.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: ", ") + "}"
        }
    }

    subscript(key: String) -> JSONValue {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var double: Double? { if case .number(let n) = self { return n }; return nil }
    var uint32: UInt32? { double.flatMap { UInt32(exactly: $0) } }
    var int: Int? { double.flatMap { Int(exactly: $0) } }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var isNull: Bool { if case .null = self { return true }; return false }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}

/// Describes the first difference between expected and actual, or nil when they match.
/// Numbers compare within `tolerance`; with `subset` only the keys present in `expected` are checked.
func firstDifference(expected: JSONValue, actual: JSONValue, path: String = "$", tolerance: Double = 1e-6, subset: Bool = false) -> String? {
    switch (expected, actual) {
    case (.number(let e), .number(let a)):
        return abs(e - a) <= tolerance ? nil : "\(path): expected \(e), got \(a)"
    case (.array(let e), .array(let a)):
        if e.count != a.count { return "\(path): expected \(e.count) elements, got \(a.count): \(actual)" }
        for (i, pair) in zip(e, a).enumerated() {
            if let d = firstDifference(expected: pair.0, actual: pair.1, path: "\(path)[\(i)]", tolerance: tolerance, subset: subset) { return d }
        }
        return nil
    case (.object(let e), .object(let a)):
        for key in e.keys.sorted() {
            guard let value = a[key] else { return "\(path).\(key): missing in actual" }
            if let d = firstDifference(expected: e[key]!, actual: value, path: "\(path).\(key)", tolerance: tolerance, subset: subset) { return d }
        }
        if !subset, let extra = a.keys.sorted().first(where: { e[$0] == nil }) { return "\(path).\(extra): not in expected" }
        return nil
    default:
        return expected == actual ? nil : "\(path): expected \(expected), got \(actual)"
    }
}

struct FixtureError: Error, CustomStringConvertible {
    let description: String
}

/// One fixture file from `spec/fixtures/<folder>/<name>.json`.
struct Fixture: Sendable, CustomTestStringConvertible {
    let folder: String
    let name: String
    let root: JSONValue

    var testDescription: String { "\(folder)/\(name)" }
    var kind: String? { root["kind"].string }

    var hex: [UInt8] { Hex.bytes(root["hex"].string ?? "") }
    var expected: JSONValue { root["expected"] }
    var expectedError: JSONValue { root["expectedError"] }
}

enum Fixtures {
    /// `spec/fixtures`, found relative to this source file: mac/Tests/CombustionCodecTests -> repo root.
    static let directory: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("spec").appendingPathComponent("fixtures")

    static func load(_ folder: String, kind: String? = nil) -> [Fixture] {
        let dir = directory.appendingPathComponent(folder)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
        return files.compactMap { file in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(file)),
                  let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
            let fixture = Fixture(folder: folder, name: String(file.dropLast(5)), root: root)
            return kind == nil || fixture.kind == kind ? fixture : nil
        }
    }

    /// Every file in the folder, including ones that fail to parse (so a broken file fails a test).
    static func fileNames(_ folder: String) -> [String] {
        let dir = directory.appendingPathComponent(folder)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }
    }
}

enum Hex {
    static func bytes(_ string: String) -> [UInt8] {
        var out = [UInt8]()
        var high: UInt8?
        for scalar in string.unicodeScalars {
            guard let nibble = UInt8(String(scalar), radix: 16) else { continue }
            if let h = high { out.append(h << 4 | nibble); high = nil } else { high = nibble }
        }
        return out
    }

    static func string(_ bytes: [UInt8]) -> String {
        bytes.map { byte -> String in
            let digits = String(byte, radix: 16, uppercase: true)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }
}
