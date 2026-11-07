import Foundation

/// What a voice call may do. The voice actor is the user, so an edit in Ask
/// mode runs with an undo notice instead of a question (VPLAN section 7).
public nonisolated enum VoiceDecision: Equatable, Sendable {
    case run
    case runWithNotice
    case confirm
    case deny(String)
}

public nonisolated enum VoicePolicy {
    public static let offMessage =
        "Agent control is Off for this Ensemble, so it is read-only by voice."

    /// The full Phase 1 and 2 table. `alwaysAllowed` is a remembered grant for
    /// this tool on this Ensemble; unlike the MCP rule it may cover a sensitive
    /// tool, because the voice actor is the user (ADR 0035).
    public static func decide(
        mode: CanvasAgentControlMode, risk: CanvasAgentRisk, alwaysAllowed: Bool = false
    ) -> VoiceDecision {
        if risk == .read { return .run }
        switch mode {
        case .off: return .deny(offMessage)
        case .allow: return risk == .sensitive ? .runWithNotice : .run
        case .ask:
            switch risk {
            case .read: return .run
            case .edit: return .runWithNotice
            case .sensitive: return alwaysAllowed ? .runWithNotice : .confirm
            }
        }
    }

    /// The terminal output tail goes to the backend only in Allow mode, and
    /// only while the Settings toggle is on (default on).
    public static func sharesTerminalTail(mode: CanvasAgentControlMode, setting: Bool) -> Bool {
        mode == .allow && setting
    }
}
