import Foundation

/// A JSON value that is `Sendable` and `Codable`, for the parts of the GPT-Live
/// wire format that are open-ended: tool parameter schemas. `[String: Any]`
/// cannot cross an actor boundary; this can.
public nonisolated enum VoiceJSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([VoiceJSON])
    case object([String: VoiceJSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([VoiceJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: VoiceJSON].self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Converts a value built from Swift literals, such as an MCP
    /// `inputSchema`. Unknown leaf types become `null`. `Bool` is tested
    /// before the numbers, so a literal `true` never turns into `1`.
    public init(any value: Any) {
        switch value {
        case let value as VoiceJSON: self = value
        case let value as Bool: self = .bool(value)
        case let value as Int: self = .integer(value)
        case let value as Double: self = .number(value)
        case let value as String: self = .string(value)
        case let value as [Any]: self = .array(value.map(VoiceJSON.init(any:)))
        case let value as [String: Any]:
            self = .object(value.mapValues(VoiceJSON.init(any:)))
        default: self = .null
        }
    }

    public subscript(key: String) -> VoiceJSON? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [VoiceJSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: VoiceJSON]? {
        if case .object(let value) = self { return value }
        return nil
    }

    /// Compact JSON with sorted keys; `{}` if encoding fails.
    public func jsonString() -> String {
        (try? VoiceWire.string(self)) ?? "{}"
    }

    /// A tool error for the backend: `{"error": code, "message": text}`.
    public static func toolError(_ code: String, _ message: String) -> String {
        VoiceJSON.object(["error": .string(code), "message": .string(message)]).jsonString()
    }
}

/// The one encoder configuration for the wire: sorted keys, no escaped slashes.
nonisolated enum VoiceWire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func string<Value: Encodable>(_ value: Value) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }
}

extension VoiceJSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
    ExpressibleByFloatLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .integer(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: VoiceJSON...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, VoiceJSON)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
