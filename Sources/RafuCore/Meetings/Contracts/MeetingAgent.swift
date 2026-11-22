import Foundation

/// The user's agent CLI that the hidden meeting agent starts (the decision
/// record about a meeting agent with no visible terminal).
public enum MeetingAgentCLI: String, Codable, Sendable, CaseIterable {
    case claudeCode = "claude-code"
    case codex
}

/// A turn that an answer points at. The library checks each citation
/// against the meeting before the interface shows it.
public struct MeetingCitation: Hashable, Codable, Sendable {
    public var turn: MeetingTurnID
    /// A short quote from that turn.
    public var quote: String

    public init(turn: MeetingTurnID, quote: String) {
        self.turn = turn
        self.quote = quote
    }
}

/// The answer from the hidden meeting agent.
public struct MeetingAgentReply: Hashable, Sendable {
    public var cli: MeetingAgentCLI
    public var text: String
    public var citations: [MeetingCitation]

    public init(cli: MeetingAgentCLI, text: String, citations: [MeetingCitation]) {
        self.cli = cli
        self.text = text
        self.citations = citations
    }
}

/// Runs one question about one meeting, only on an explicit user action.
/// Read-only, limited to that meeting, with no Rafu-held credential.
public protocol MeetingAgentRunning: Sendable {
    func ask(_ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> MeetingAgentReply
    /// Speaker-name suggestions: a label and the suggested name.
    func suggestSpeakerNames(for meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> [MeetingSpeakerLabel: String]
}

extension MeetingAgentCLI {
    /// The name in the interface.
    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// The provider that gets the meeting text when this CLI answers.
    public var providerName: String {
        switch self {
        case .claudeCode: "Anthropic"
        case .codex: "OpenAI"
        }
    }
}

/// Whether a CLI can answer now.
public enum MeetingAgentAvailability: Hashable, Sendable {
    case ready
    case notInstalled
    /// The installed version did not pass Rafu's limits check.
    case unsupportedVersion(found: String)
}

/// Why a hidden agent run gave no answer.
public enum MeetingAgentError: Error, Hashable, Sendable {
    case notInstalled(MeetingAgentCLI)
    case unsupportedVersion(MeetingAgentCLI)
    case notSignedIn(MeetingAgentCLI)
    /// The meeting is live or has no transcript yet.
    case meetingNotReady
    /// A run for this meeting is in progress.
    case busy
    case timedOut
    case cancelled
    case replyTooLarge
    case transcriptTooLarge
    case failed

    public var message: String {
        switch self {
        case .notInstalled(let cli): "\(cli.displayName) is not installed on this Mac."
        case .unsupportedVersion(let cli): "Not available with this \(cli.displayName) version."
        case .notSignedIn(let cli):
            "\(cli.displayName) is not signed in. Sign in with \(cli.displayName) in a terminal, then try again."
        case .meetingNotReady: "You can ask after the meeting has stopped and its text is ready."
        case .busy: "An answer for this meeting is in progress."
        case .timedOut: "The agent gave no answer in 2 minutes."
        case .cancelled: "Cancelled."
        case .replyTooLarge: "The answer was too large, so Rafu did not show it."
        case .transcriptTooLarge: "This meeting is too long to send in one question."
        case .failed: "The agent gave no answer. Try again."
        }
    }
}

/// A runner can also tell whether a CLI can answer. The interface reads it
/// through `feature.agentRunner as? any MeetingAgentAvailabilityChecking`.
public protocol MeetingAgentAvailabilityChecking: Sendable {
    func availability(of cli: MeetingAgentCLI) async -> MeetingAgentAvailability
}
