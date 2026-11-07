import Foundation

/// One message Rafu sends on the GPT-Live socket. Every message carries
/// `type` and a fresh `event_id` (Phase 0 report, section 1).
public nonisolated enum VoiceLiveClientEvent: Equatable, Sendable {
    case sessionStart(VoiceSessionConfig)
    /// 20 ms of 24 kHz mono PCM16 little-endian (960 bytes).
    case inputAudioAppend(Data)
    case inputAudioMute
    case inputAudioUnmute
    /// Replaces the whole `delegation` object; a partial patch is refused.
    case sessionUpdate(VoiceDelegationConfig)
    /// `session.instructions.append`. Unverified field name (`content`).
    case instructionsAppend(String)
    /// `session.commentary.append`. Without a delegation id it is untested
    /// under Responses delegation; the key is omitted when nil.
    case commentaryAppend(delegationID: String?, String)
    case responseItemCreateFunctionOutput(callID: String, output: String)
    /// Mandatory after a `function_call_output` (Phase 0).
    case responseCreate
    case sessionClose

    public var type: String {
        switch self {
        case .sessionStart: "session.start"
        case .inputAudioAppend: "session.input_audio.append"
        case .inputAudioMute: "session.input_audio.mute"
        case .inputAudioUnmute: "session.input_audio.unmute"
        case .sessionUpdate: "session.update"
        case .instructionsAppend: "session.instructions.append"
        case .commentaryAppend: "session.commentary.append"
        case .responseItemCreateFunctionOutput: "response.item.create"
        case .responseCreate: "response.create"
        case .sessionClose: "session.close"
        }
    }

    /// A fresh `evt_` id, like the spike's.
    public static func newEventID() -> String {
        "evt_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }

    /// The JSON text for the socket: sorted keys, no escaped slashes.
    public func json(eventID: String = VoiceLiveClientEvent.newEventID()) throws -> String {
        if case .inputAudioAppend(let pcm) = self {
            // The hot path, 50 times a second: the same shape the encoder
            // produces (base64 never needs JSON escaping), without it.
            return
                "{\"audio\":\"\(pcm.base64EncodedString())\",\"event_id\":\"\(eventID)\",\"type\":\"\(type)\"}"
        }
        return try VoiceWire.string(Envelope(event: self, eventID: eventID))
    }

    private struct Envelope: Encodable {
        let event: VoiceLiveClientEvent
        let eventID: String

        private enum Keys: String, CodingKey {
            case type, session, audio, content, item
            case eventID = "event_id"
            case delegationID = "delegation_id"
        }
        private enum ItemKeys: String, CodingKey {
            case type, output
            case callID = "call_id"
        }
        private struct Delegation: Encodable {
            let delegation: VoiceDelegationConfig
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: Keys.self)
            try container.encode(event.type, forKey: .type)
            try container.encode(eventID, forKey: .eventID)
            switch event {
            case .sessionStart(let config):
                try container.encode(config, forKey: .session)
            case .inputAudioAppend(let pcm):
                try container.encode(pcm.base64EncodedString(), forKey: .audio)
            case .sessionUpdate(let delegation):
                try container.encode(Delegation(delegation: delegation), forKey: .session)
            case .instructionsAppend(let text):
                try container.encode(text, forKey: .content)
            case .commentaryAppend(let delegationID, let text):
                try container.encodeIfPresent(delegationID, forKey: .delegationID)
                try container.encode(text, forKey: .content)
            case .responseItemCreateFunctionOutput(let callID, let output):
                var item = container.nestedContainer(keyedBy: ItemKeys.self, forKey: .item)
                try item.encode("function_call_output", forKey: .type)
                try item.encode(callID, forKey: .callID)
                try item.encode(output, forKey: .output)
            case .inputAudioMute, .inputAudioUnmute, .responseCreate, .sessionClose:
                break
            }
        }
    }
}

/// One message GPT-Live sends, reduced to what Rafu uses. Nested
/// `response.event`s other than a finished function call and a completed
/// response are dropped, so reasoning blobs and config echoes never reach the
/// app (they decode to `.other`).
public nonisolated enum VoiceLiveServerEvent: Decodable, Equatable, Sendable {
    case sessionStarted(id: String, expiresAt: Int?)
    case outputAudioDelta(Data)
    case inputTranscriptDelta(String)
    case outputTranscriptDelta(String)
    case delegationCreated(id: String, target: String?)
    case functionCall(callID: String, name: String, argumentsJSON: String)
    case responseCompleted(inputTokens: Int?, outputTokens: Int?)
    case sessionUpdated
    case commentaryAppended
    case usageUpdated(seconds: Double, contextRatio: Double?)
    case sessionClosed(reason: String?, seconds: Int?)
    case error(code: String?, message: String?)
    case other(String)

    private enum Keys: String, CodingKey {
        case type, session, delta, delegation, event, usage, reason, error
        case contextWindow = "context_window"
    }
    private struct Session: Decodable {
        let id: String?
        let expiresAt: FlexibleNumber?
        private enum CodingKeys: String, CodingKey {
            case id
            case expiresAt = "expires_at"
        }
    }
    private struct Delegation: Decodable {
        let id: String?
        let target: String?
    }
    private struct Usage: Decodable {
        let seconds: FlexibleNumber?
    }
    private struct ContextWindow: Decodable {
        let usageRatio: FlexibleNumber?
        private enum CodingKeys: String, CodingKey { case usageRatio = "usage_ratio" }
    }
    private struct ErrorBody: Decodable {
        let code: String?
        let message: String?
    }
    /// The nested Responses event. Only the fields Rafu reads.
    private struct NestedEvent: Decodable {
        let type: String?
        let item: Item?
        let response: Response?

        struct Item: Decodable {
            let type: String?
            let name: String?
            let callID: String?
            let arguments: String?
            private enum CodingKeys: String, CodingKey {
                case type, name, arguments
                case callID = "call_id"
            }
        }
        struct Response: Decodable {
            let usage: TokenUsage?
        }
        struct TokenUsage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            private enum CodingKeys: String, CodingKey {
                case inputTokens = "input_tokens"
                case outputTokens = "output_tokens"
            }
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "session.started":
            let session = try container.decodeIfPresent(Session.self, forKey: .session)
            self = .sessionStarted(
                id: session?.id ?? "", expiresAt: session?.expiresAt.map { Int($0.value) })
        case "session.output_audio.delta":
            let text = try container.decode(String.self, forKey: .delta)
            self = .outputAudioDelta(Data(base64Encoded: text) ?? Data())
        case "session.input_transcript.delta":
            self = .inputTranscriptDelta(
                try container.decodeIfPresent(String.self, forKey: .delta) ?? "")
        case "session.output_transcript.delta":
            self = .outputTranscriptDelta(
                try container.decodeIfPresent(String.self, forKey: .delta) ?? "")
        case "session.delegation.created":
            let delegation = try container.decodeIfPresent(Delegation.self, forKey: .delegation)
            self = .delegationCreated(id: delegation?.id ?? "", target: delegation?.target)
        case "response.event":
            self = Self.nested(try container.decodeIfPresent(NestedEvent.self, forKey: .event))
        case "session.updated":
            self = .sessionUpdated
        case "session.commentary.appended":
            self = .commentaryAppended
        case "session.usage.updated":
            let usage = try container.decodeIfPresent(Usage.self, forKey: .usage)
            let window = try? container.decodeIfPresent(ContextWindow.self, forKey: .contextWindow)
            self = .usageUpdated(
                seconds: usage?.seconds?.value ?? 0, contextRatio: window?.usageRatio?.value)
        case "session.closed":
            let usage = try? container.decodeIfPresent(Usage.self, forKey: .usage)
            self = .sessionClosed(
                reason: try container.decodeIfPresent(String.self, forKey: .reason),
                seconds: usage?.seconds.map { Int($0.value) })
        case "error":
            let body = try? container.decodeIfPresent(ErrorBody.self, forKey: .error)
            self = .error(code: body?.code, message: body?.message)
        default:
            self = .other(type)
        }
    }

    private static func nested(_ event: NestedEvent?) -> VoiceLiveServerEvent {
        guard let event, let type = event.type else { return .other("response.event") }
        switch type {
        case "response.output_item.done":
            guard let item = event.item, item.type == "function_call", let callID = item.callID,
                let name = item.name
            else { return .other("response.event/\(type)") }
            return .functionCall(callID: callID, name: name, argumentsJSON: item.arguments ?? "{}")
        case "response.completed":
            return .responseCompleted(
                inputTokens: event.response?.usage?.inputTokens,
                outputTokens: event.response?.usage?.outputTokens)
        default:
            return .other("response.event/\(type)")
        }
    }

    /// A short name for diagnostics and the timeline. Never a payload.
    public var kind: String {
        switch self {
        case .sessionStarted: "session.started"
        case .outputAudioDelta: "session.output_audio.delta"
        case .inputTranscriptDelta: "session.input_transcript.delta"
        case .outputTranscriptDelta: "session.output_transcript.delta"
        case .delegationCreated: "session.delegation.created"
        case .functionCall: "function_call"
        case .responseCompleted: "response.completed"
        case .sessionUpdated: "session.updated"
        case .commentaryAppended: "session.commentary.appended"
        case .usageUpdated: "session.usage.updated"
        case .sessionClosed: "session.closed"
        case .error: "error"
        case .other(let type): type
        }
    }

    /// Decodes one socket message; `nil` when it is not JSON with a `type`.
    public static func decode(_ text: String) -> VoiceLiveServerEvent? {
        try? JSONDecoder().decode(VoiceLiveServerEvent.self, from: Data(text.utf8))
    }
}

/// A number the server sends as an integer in one event and a float in
/// another (`usage.seconds`, Phase 0 section 5).
private nonisolated struct FlexibleNumber: Decodable {
    let value: Double

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) {
            value = Double(integer)
        } else if let text = try? container.decode(String.self), let number = Double(text) {
            value = number
        } else {
            value = try container.decode(Double.self)
        }
    }
}
