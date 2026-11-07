import Foundation

/// Who speaks. Phase 1 has one persona, Rafu, the orchestrator. Phase 2 adds
/// one persona per Ensemble here, swapped in with `session.update`.
public nonisolated struct VoicePersona: Equatable, Sendable {
    public var id: String
    public var name: String
    public var voice: VoiceVoice
    /// GPT-Live's own instructions. Immutable after `session.start`.
    public var liveInstructions: String
    public var scope: VoiceToolScope
    private var backendBase: String

    public init(
        id: String, name: String, voice: VoiceVoice, liveInstructions: String,
        backendInstructions: String, scope: VoiceToolScope
    ) {
        self.id = id
        self.name = name
        self.voice = voice
        self.liveInstructions = liveInstructions
        self.backendBase = backendInstructions
        self.scope = scope
    }

    /// The backend's instructions, with an optional short context paragraph
    /// (for example a style profile summary, Phase 2).
    public func backendInstructions(context: String? = nil) -> String {
        guard let context, !context.isEmpty else { return backendBase }
        return backendBase + "\n\n" + context
    }

    public func with(voice: VoiceVoice) -> VoicePersona {
        var copy = self
        copy.voice = voice
        return copy
    }

    public static let rafu = VoicePersona(
        id: "rafu", name: "Rafu", voice: .default,
        liveInstructions: """
            You are Rafu, the voice of a macOS code workspace. The user runs a visual board \
            called an Ensemble, with notes, terminals and links, by talking to you. \
            Keep every spoken reply to one or two short sentences. Delegate every board \
            action and every question about the board to the backend. Never say an action \
            is done before the backend confirms it. If a request is unclear, ask one short \
            question.
            """,
        backendInstructions: """
            You act for the user on Rafu's Ensembles through the tools. The user is speaking, \
            so answer in one short sentence after the tools return.
            Rules:
            - Call ensemble_describe before you change the visible Ensemble, unless you \
            called it earlier in this turn. It lists every node and link with ids, the \
            selection and the focused node.
            - node_id, from, to and member_ids accept a node id, an exact or leading title, \
            or "selected" for the node the user means by "this".
            - When a tool returns error "ambiguous", say the candidate titles and ask which \
            one. Never guess.
            - When a tool returns error "needs_phase_2", tell the user in one sentence that \
            this works in a later version of Rafu voice. Do not retry it.
            - When a tool says Agent control is Off, say the Ensemble is read-only by voice.
            - "Undo" means voice_undo. "Fit everything" means view_zoom with mode fit. \
            "Tidy up" means view_tidy. "Stay with me" means voice_latch.
            - For "what is everyone doing everywhere", use cross_board_summary. For one \
            other Ensemble, use ensemble_describe with its name.
            - You cannot read files or run commands. Never claim you did.
            """,
        scope: .rafu)
}

/// Builds the wire configuration for a persona.
public nonisolated enum VoiceSessionPlan {
    public static func start(
        persona: VoicePersona, backend: VoiceBackendModel, tools: [VoiceFunctionTool],
        context: String? = nil
    ) -> VoiceSessionConfig {
        VoiceSessionConfig(
            instructions: persona.liveInstructions, voice: persona.voice,
            delegation: update(persona: persona, backend: backend, tools: tools, context: context))
    }

    /// The whole `delegation` object for `session.update` (a partial patch is
    /// refused by the server).
    public static func update(
        persona: VoicePersona, backend: VoiceBackendModel, tools: [VoiceFunctionTool],
        context: String? = nil
    ) -> VoiceDelegationConfig {
        VoiceDelegationConfig(
            model: backend.rawValue, instructions: persona.backendInstructions(context: context),
            tools: tools)
    }
}
