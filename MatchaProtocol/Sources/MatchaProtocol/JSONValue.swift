//
// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial.
// Please see LICENSE files in the repository root for full details.
//

/// A JSON value read leniently: unlike `Codable`, a bad field never fails the whole event, so invalid revisions are dropped
/// field by field exactly like the Android and web clients.
///
/// It has its own strict RFC 8259 reader because Foundation's differ from the other clients: `JSONSerialization` drops a leading
/// U+FEFF from every string and `JSONDecoder` reads `1.0` as an integer.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    /// A number written without a fraction or exponent that fits in 64 bits. `1.0` is a `.number`.
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
    
    /// Parses JSON text, or returns nil when it is not JSON or nests deeper than 100 levels.
    public init?(json: String) {
        var parser = JSONParser(bytes: Array(json.utf8))
        guard let value = parser.parseDocument() else { return nil }
        self = value
    }
    
    /// Compact JSON with sorted keys, for event content.
    public var jsonString: String {
        var output = ""
        write(to: &output)
        return output
    }
    
    public var objectValue: JSONObject? {
        if case let .object(object) = self {
            object
        } else {
            nil
        }
    }
    
    public var stringValue: String? {
        if case let .string(string) = self {
            string
        } else {
            nil
        }
    }
    
    // MARK: - Private
    
    private func write(to output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .integer(let value): output += String(value)
        case .number(let value): output += value.isFinite ? "\(value)" : "null"
        case .string(let value): Self.writeString(value, to: &output)
        case .array(let values):
            output += "["
            for (index, value) in values.enumerated() {
                if index > 0 {
                    output += ","
                }
                value.write(to: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            for (index, key) in object.keys.sorted().enumerated() {
                if index > 0 {
                    output += ","
                }
                Self.writeString(key, to: &output)
                output += ":"
                object[key]?.write(to: &output)
            }
            output += "}"
        }
    }
    
    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20:
                let hex = String(scalar.value, radix: 16)
                output += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}

public typealias JSONObject = [String: JSONValue]

public extension Dictionary where Key == String, Value == JSONValue {
    func string(_ key: String) -> String? {
        self[key]?.stringValue
    }
    
    func bool(_ key: String) -> Bool? {
        if case let .bool(value) = self[key] {
            value
        } else {
            nil
        }
    }
    
    /// An integral number; fractional numbers and strings are rejected.
    func integer(_ key: String) -> Int64? {
        if case let .integer(value) = self[key] {
            value
        } else {
            nil
        }
    }
    
    func object(_ key: String) -> JSONObject? {
        self[key]?.objectValue
    }
    
    /// The event id a relation of `relationType` in this content points at, if any.
    func relationTarget(_ relationType: String) -> String? {
        guard let relation = object("m.relates_to"), relation.string("rel_type") == relationType else { return nil }
        return relation.string("event_id")
    }
    
    /// The event id an `m.reference` relation in this content points at, if any.
    var referenceTarget: String? {
        relationTarget(MatchaConfig.relationTypeReference)
    }
}

// swiftlint:disable optional_data_string_conversion
// The bytes are valid UTF-8 by construction, and Foundation's `String(bytes:encoding:)` would drop a leading U+FEFF.
/// A recursive descent reader of RFC 8259 JSON over UTF-8 bytes. Duplicate keys keep the last value.
/// ponytail: a lone surrogate escape becomes U+FFFD (Kotlin keeps it), and leading zeros are refused (kotlinx reads them).
private struct JSONParser {
    /// Matcha content nests a few levels; the bound keeps hostile events from exhausting a concurrency thread's small stack.
    private static let maxDepth = 100
    
    let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    
    init(bytes: [UInt8]) {
        self.bytes = bytes
    }
    
    mutating func parseDocument() -> JSONValue? {
        guard let value = parseValue() else { return nil }
        skipWhitespace()
        return index == bytes.count ? value : nil
    }
    
    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }
    
    private mutating func parseValue() -> JSONValue? {
        skipWhitespace()
        switch current {
        case UInt8(ascii: "{"): return parseContainer(close: "}") { parser in
                guard parser.current == UInt8(ascii: "\""), let key = parser.parseString() else { return nil }
                parser.skipWhitespace()
                guard parser.consume(":"), let value = parser.parseValue() else { return nil }
                return (key, value)
            }.map { .object(Dictionary($0) { _, last in last }) }
        case UInt8(ascii: "["): return parseContainer(close: "]") { parser in parser.parseValue().map { ("", $0) } }.map { .array($0.map(\.1)) }
        case UInt8(ascii: "\""): return parseString().map(JSONValue.string)
        case UInt8(ascii: "t"): return parseLiteral("true", value: .bool(true))
        case UInt8(ascii: "f"): return parseLiteral("false", value: .bool(false))
        case UInt8(ascii: "n"): return parseLiteral("null", value: .null)
        default: return parseNumber()
        }
    }
    
    /// The members of an object or the elements of an array, after its opening bracket.
    private mutating func parseContainer(close: Unicode.Scalar, member: (inout JSONParser) -> (String, JSONValue)?) -> [(String, JSONValue)]? {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maxDepth else { return nil }
        index += 1
        var members = [(String, JSONValue)]()
        skipWhitespace()
        if consume(close) {
            return members
        }
        repeat {
            skipWhitespace()
            guard let next = member(&self) else { return nil }
            members.append(next)
            skipWhitespace()
        } while consume(",")
        return consume(close) ? members : nil
    }
    
    private mutating func parseString() -> String? {
        index += 1
        var utf8 = [UInt8]()
        while let byte = current {
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: utf8, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard let escaped = parseEscape() else { return nil }
                utf8.append(contentsOf: String(escaped).utf8)
            case 0..<0x20:
                return nil
            default:
                utf8.append(byte)
            }
        }
        return nil
    }
    
    private mutating func parseEscape() -> Unicode.Scalar? {
        guard let byte = current else { return nil }
        index += 1
        switch byte {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{08}"
        case UInt8(ascii: "f"): return "\u{0C}"
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"):
            guard let unit = parseHex() else { return nil }
            guard (0xD800...0xDBFF).contains(unit) else { return Unicode.Scalar(unit) ?? "\u{FFFD}" }
            // A high surrogate must be followed by an escaped low one.
            let start = index
            if consume("\\"), consume("u"), let low = parseHex(), (0xDC00...0xDFFF).contains(low) {
                return Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)) ?? "\u{FFFD}"
            }
            index = start
            return "\u{FFFD}"
        default:
            return nil
        }
    }
    
    private mutating func parseHex() -> UInt32? {
        guard index + 4 <= bytes.count else { return nil }
        let digits = bytes[index..<(index + 4)]
        guard digits.allSatisfy({ isDigit($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0 | 0x20) }),
              let value = UInt32(String(decoding: digits, as: UTF8.self), radix: 16) else { return nil }
        index += 4
        return value
    }
    
    private mutating func parseLiteral(_ literal: String, value: JSONValue) -> JSONValue? {
        let literalBytes = Array(literal.utf8)
        guard bytes[index...].starts(with: literalBytes) else { return nil }
        index += literalBytes.count
        return value
    }
    
    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`
    private mutating func parseNumber() -> JSONValue? {
        let start = index
        _ = consume("-")
        guard let first = current, isDigit(first) else { return nil }
        index += 1
        if first != UInt8(ascii: "0") {
            skipDigits()
        }
        var isIntegral = true
        if consume(".") {
            guard skipDigits() else { return nil }
            isIntegral = false
        }
        if consume("e") || consume("E") {
            _ = consume("+") || consume("-")
            guard skipDigits() else { return nil }
            isIntegral = false
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isIntegral, let integer = Int64(text) {
            return .integer(integer)
        }
        return Double(text).map(JSONValue.number)
    }
    
    /// Skips digits; false when there were none.
    @discardableResult
    private mutating func skipDigits() -> Bool {
        let start = index
        while let byte = current, isDigit(byte) {
            index += 1
        }
        return index > start
    }
    
    private func isDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
    
    private mutating func consume(_ scalar: Unicode.Scalar) -> Bool {
        guard current == UInt8(scalar.value) else { return false }
        index += 1
        return true
    }
    
    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }
}

// swiftlint:enable optional_data_string_conversion
