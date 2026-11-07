import Foundation

/// The live voice model. Phase 0 measured only this one.
public nonisolated enum VoiceLiveModel {
    public static let identifier = "gpt-live-1"
    /// `wss://api.openai.com/v1/live/sessions`, no query (Phase 0).
    public static let endpoint = "wss://api.openai.com/v1/live/sessions"
}

/// The backend that Responses delegation runs (Phase 0: all five were
/// accepted at `session.start`; Terra and Luna were exercised end to end).
public nonisolated enum VoiceBackendModel: String, CaseIterable, Codable, Identifiable, Sendable {
    case terra = "gpt-6.1-terra"
    case luna = "gpt-6-luna"
    case sol = "gpt-6-sol"
    case sol61 = "gpt-6.1-sol"
    case astra = "gpt-6-astra"

    public static let `default` = VoiceBackendModel.terra

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .terra: "GPT-6.1 Terra (default)"
        case .luna: "GPT-6 Luna"
        case .sol: "GPT-6 Sol"
        case .sol61: "GPT-6.1 Sol"
        case .astra: "GPT-6 Astra"
        }
    }
}

/// The 25 voices GPT-Live accepted in Phase 0. An unknown name fails with a
/// misleading "access denied", so Rafu sends only these.
public nonisolated enum VoiceVoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case marin, cedar, alloy, verse, quartz, ripple, vesper, willow, stone, gleam
    case meridian, bossa, tempo, beacon, delta, cinder, nuri, juni, flitz, brise
    case sillage, nira, harema, shida, noeul

    public static let `default` = VoiceVoice.marin

    public var id: String { rawValue }

    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// `session.delegation`: Responses delegation. GPT-Live speaks; the backend
/// model reads the board and calls Rafu's tools. `session.update` replaces
/// this whole object; a partial patch is refused (Phase 0).
public nonisolated struct VoiceDelegationConfig: Encodable, Equatable, Sendable {
    public var model: String
    public var instructions: String
    public var toolChoice: String
    /// One tool call per backend turn, so a sensitive call and a confirmation
    /// cannot arrive together. Sent from Phase 1b; server acceptance is
    /// unverified (gpt-live-protocol.md). `nil` omits the key.
    public var parallelToolCalls: Bool?
    public var tools: [VoiceFunctionTool]

    public init(
        model: String, instructions: String, toolChoice: String = "auto",
        parallelToolCalls: Bool? = false, tools: [VoiceFunctionTool]
    ) {
        self.model = model
        self.instructions = instructions
        self.toolChoice = toolChoice
        self.parallelToolCalls = parallelToolCalls
        self.tools = tools
    }

    private enum OuterKeys: String, CodingKey { case type, responses }
    private enum InnerKeys: String, CodingKey {
        case model, instructions, tools
        case toolChoice = "tool_choice"
        case parallelToolCalls = "parallel_tool_calls"
    }

    public func encode(to encoder: any Encoder) throws {
        var outer = encoder.container(keyedBy: OuterKeys.self)
        try outer.encode("responses", forKey: .type)
        var inner = outer.nestedContainer(keyedBy: InnerKeys.self, forKey: .responses)
        try inner.encode(model, forKey: .model)
        try inner.encode(instructions, forKey: .instructions)
        try inner.encode(toolChoice, forKey: .toolChoice)
        try inner.encodeIfPresent(parallelToolCalls, forKey: .parallelToolCalls)
        try inner.encode(tools, forKey: .tools)
    }
}

/// `session.start`'s `session` object. The server rejects unknown fields, so
/// this encodes exactly the Phase 0 shape: model, instructions,
/// `audio.output.voice`, delegation. `model`, `instructions` and `audio` are
/// immutable after start.
public nonisolated struct VoiceSessionConfig: Encodable, Equatable, Sendable {
    public var model: String
    public var instructions: String
    public var voice: VoiceVoice
    public var delegation: VoiceDelegationConfig

    public init(
        model: String = VoiceLiveModel.identifier, instructions: String, voice: VoiceVoice,
        delegation: VoiceDelegationConfig
    ) {
        self.model = model
        self.instructions = instructions
        self.voice = voice
        self.delegation = delegation
    }

    private enum Keys: String, CodingKey { case model, instructions, audio, delegation }
    private enum AudioKeys: String, CodingKey { case output }
    private enum OutputKeys: String, CodingKey { case voice }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        try container.encode(model, forKey: .model)
        try container.encode(instructions, forKey: .instructions)
        var audio = container.nestedContainer(keyedBy: AudioKeys.self, forKey: .audio)
        var output = audio.nestedContainer(keyedBy: OutputKeys.self, forKey: .output)
        try output.encode(voice.rawValue, forKey: .voice)
        try container.encode(delegation, forKey: .delegation)
    }
}
