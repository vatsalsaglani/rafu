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
