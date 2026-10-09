//
//  MCPJSON.swift
//  Framecho
//
//  A JSON value that is Codable and Sendable, for the Model Context Protocol
//  server. Tool arguments arrive as arbitrary JSON and tool results are
//  built by hand, so a typed tree is simpler than a Codable struct per call.
//

import Foundation

nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value):
            // JSON has no NaN or infinity; a broken number must not make the
            // whole reply unencodable.
            if value.isFinite { try container.encode(value) } else { try container.encodeNil() }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: - Reading

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    /// Integers and doubles both read as numbers: clients send `2` and `2.0`
    /// interchangeably.
    var doubleValue: Double? {
        switch self {
        case .int(let value): Double(value)
        case .double(let value): value
        default: nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let value): value
        case .double(let value) where value.rounded() == value && abs(value) < 1e15: Int(value)
        default: nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    // MARK: - Building

    /// Seconds rounded to milliseconds, which is finer than a frame and
    /// keeps replies readable.
    static func seconds(_ value: TimeInterval) -> JSONValue {
        .double((value * 1000).rounded() / 1000)
    }

    static func optional(_ value: JSONValue?) -> JSONValue {
        value ?? .null
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(integerLiteral value: Int) { self = .int(value) }
    nonisolated init(floatLiteral value: Double) { self = .double(value) }
    nonisolated init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    nonisolated init(nilLiteral: ()) { self = .null }
}

nonisolated enum JSONLine {
    /// One line of newline-delimited JSON: compact output never contains a
    /// raw newline, because JSON escapes them inside strings.
    static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
