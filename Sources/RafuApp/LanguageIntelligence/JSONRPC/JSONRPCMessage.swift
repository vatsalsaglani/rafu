import Foundation

/// A dependency-free JSON document tree. Used for `params`/`data` payloads
/// whose shape isn't known ahead of time (e.g. server-defined notification
/// params, error `data`), and reused by lane 2's lenient server-capability
/// decoding. Never used to represent a JSON-RPC id — see ``JSONRPCID``.
nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "Unsupported JSON value shape"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A JSON-RPC 2.0 request/response id: either an integer or a string, never
/// a fractional number or `null`. Hashable so it can key a continuation map
/// (``JSONRPCConnection``'s `pending`).
nonisolated enum JSONRPCID: Codable, Hashable, Sendable, Equatable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "id must be an integer or string"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        }
    }
}

/// A JSON-RPC 2.0 error object. Conforms to `Error` so it can be thrown
/// directly by ``JSONRPCConnection/sendRequest(method:params:)`` when a
/// server response carries an `error` field.
nonisolated struct JSONRPCErrorObject: Codable, Sendable, Equatable, Error {
    let code: Int
    let message: String
    let data: JSONValue?

    static let parseError = -32700
    static let invalidRequest = -32600
    static let methodNotFound = -32601
    static let invalidParams = -32602
    static let internalError = -32603
    static let requestCancelled = -32800
}

/// A decoded server-to-client (or client-to-server) notification: no `id`,
/// so no reply is expected either way.
nonisolated struct JSONRPCNotification: Codable, Sendable, Equatable {
    let method: String
    let params: JSONValue?

    private enum CodingKeys: String, CodingKey {
        case method
        case params
    }

    /// Wire keys used only for encoding; kept separate from `CodingKeys` so
    /// the compiler still synthesizes `init(from:)` (which must ignore the
    /// `jsonrpc` field, not require it).
    private enum WireCodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: WireCodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// A decoded incoming server-to-client request (has both `method` and
/// `id`, so a reply is expected). Representable purely via synthesized
/// `Codable` since decoding simply ignores the extra `jsonrpc` wire field.
nonisolated struct JSONRPCRequest: Codable, Sendable, Equatable {
    let id: JSONRPCID
    let method: String
    let params: JSONValue?
}

/// One decoded, framed JSON-RPC body classified by shape. `.response` keeps
/// the raw body (rather than a decoded `result`) so the caller — the only
/// party that knows the expected `Result` type — decodes it exactly once.
nonisolated enum JSONRPCIncomingMessage: Sendable {
    case request(JSONRPCRequest)
    case notification(JSONRPCNotification)
    case response(id: JSONRPCID, body: Data)

    /// Thrown when a decoded JSON-RPC body has neither `method` nor `id`,
    /// so it cannot be any of the three known shapes. Carries only the byte
    /// count of the offending body — never its contents.
    nonisolated enum ClassificationError: Error, Equatable {
        case malformedFrame(byteCount: Int)
    }

    private struct Probe: Decodable {
        let id: JSONRPCID?
        let method: String?
    }

    static func classify(_ body: Data) throws -> JSONRPCIncomingMessage {
        let probe = try JSONDecoder().decode(Probe.self, from: body)
        switch (probe.method, probe.id) {
        case (.some, .some):
            return .request(try JSONDecoder().decode(JSONRPCRequest.self, from: body))
        case (.some, .none):
            return .notification(try JSONDecoder().decode(JSONRPCNotification.self, from: body))
        case (.none, .some(let id)):
            return .response(id: id, body: body)
        case (.none, .none):
            throw ClassificationError.malformedFrame(byteCount: body.count)
        }
    }
}

/// Outgoing client-to-server request envelope. Adds the `jsonrpc` wire
/// field and omits `params` entirely (rather than encoding it as `null`)
/// when there are none.
nonisolated struct JSONRPCRequestEnvelope<Params: Encodable>: Encodable {
    let id: JSONRPCID
    let method: String
    let params: Params?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// Outgoing client-to-server notification envelope: the same shape as
/// ``JSONRPCRequestEnvelope`` minus `id`.
nonisolated struct JSONRPCNotificationEnvelope<Params: Encodable>: Encodable {
    let method: String
    let params: Params?

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case method
        case params
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(method, forKey: .method)
        try container.encodeIfPresent(params, forKey: .params)
    }
}

/// Decoded incoming response envelope. `"result": null` is a legal answer
/// (e.g. a hover miss); a response with neither `result` nor `error` is a
/// protocol violation. Because `KeyedDecodingContainer.decodeIfPresent`
/// treats an explicit JSON `null` the same as a missing key (both decode to
/// `nil`), `result`/`error` alone cannot distinguish the two — `hasResult`
/// records whether the `result` key was present at all, independent of
/// whether its value happened to be `null`.
nonisolated struct JSONRPCResponseEnvelope<Result: Decodable>: Decodable {
    let id: JSONRPCID?
    let result: Result?
    let error: JSONRPCErrorObject?
    let hasResult: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case result
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(JSONRPCID.self, forKey: .id)
        error = try container.decodeIfPresent(JSONRPCErrorObject.self, forKey: .error)
        if container.contains(.result) {
            hasResult = true
            result = try container.decode(Result.self, forKey: .result)
        } else {
            hasResult = false
            result = nil
        }
    }
}

/// Outgoing error-response envelope, used only to answer an incoming
/// server-to-client request Rafu doesn't (yet) implement a handler for.
nonisolated struct JSONRPCErrorResponseEnvelope: Encodable {
    let id: JSONRPCID
    let error: JSONRPCErrorObject

    private enum CodingKeys: String, CodingKey {
        case jsonrpc
        case id
        case error
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("2.0", forKey: .jsonrpc)
        try container.encode(id, forKey: .id)
        try container.encode(error, forKey: .error)
    }
}
