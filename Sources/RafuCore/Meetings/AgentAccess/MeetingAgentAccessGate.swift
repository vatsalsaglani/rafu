import Foundation

/// The refusal an agent tool gives when the user has not allowed agents to
/// read meetings. It carries no meeting data, no title and no count.
public struct MeetingAgentAccessDenied: Error, Hashable, Sendable {
    public init() {}

    public var message: String { MeetingAgentAccessGate.refusalMessage }
}

/// The one check before each meeting tool for agents: Settings ▸ Meetings ▸
/// "Allow agents to read your meetings" (default off). The caller reads the
/// switch at each call and passes the value here; nothing is cached.
public enum MeetingAgentAccessGate {
    /// The refusal text. The same text in each tool, so an agent cannot tell
    /// one tool from another by its refusal.
    public static let refusalMessage =
        "The user has not allowed agents to read meetings. Ask the user to turn on Settings ▸ Meetings ▸ Allow agents to read your meetings."
    /// The switch is on, but this Mac has no Meetings library.
    public static let unavailableMessage = "Meetings is not available on this Mac."
    /// The same text for an unknown id and for a meeting that is not ready,
    /// so an agent cannot probe ids.
    public static let noSuchMeetingMessage = "No such meeting."
    /// Each error from the library maps to this text. A library error can
    /// hold a path, so its own text never reaches an agent.
    public static let readFailedMessage = "The meeting could not be read."

    public static func check(_ access: MeetingAgentAccess) -> Result<Void, MeetingAgentAccessDenied>
    {
        access == .on ? .success(()) : .failure(MeetingAgentAccessDenied())
    }
}

/// The bounds of the meeting tools for agents.
public enum MeetingAgentToolLimits {
    /// A search query, in characters.
    public static let maximumQueryCharacters = 200
    public static let searchLimits = 1...20
    public static let defaultSearchLimit = 10
    public static let readLimits = 1...40
    public static let defaultReadLimit = 40
    /// One search snippet, in characters.
    public static let maximumSnippetCharacters = 240
    /// One turn text, in characters. Longer text is cut with "…".
    public static let maximumTurnCharacters = 2_000
    /// A title or a speaker name, in characters.
    public static let maximumTitleCharacters = 200
    /// The encoded reply, in bytes. One MCP frame is 64 KiB and the bridge
    /// passes at most half of it to the agent, with its own wrapper around
    /// the reply, so a meeting reply stays at 24 KiB.
    public static let maximumReplyBytes = 24 * 1_024
}
