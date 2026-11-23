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
/// It starts no process: it reads the last probe result (`MeetingAgentProbing`).
public protocol MeetingAgentAvailabilityChecking: Sendable {
    func availability(of cli: MeetingAgentCLI) async -> MeetingAgentAvailability
}

/// What a hidden meeting agent run is for. A runner allows one run of each
/// kind for each meeting at a time, so a question can run while the summary
/// runs.
public enum MeetingAgentRunKind: String, Hashable, Codable, Sendable, CaseIterable {
    /// One question from the user.
    case question
    /// Speaker-name suggestions. The question text is made by Rafu.
    case speakerNames
    /// The title and summary after processing. The question text is made by
    /// Rafu.
    case summary
}

/// One hidden agent run that is in progress, for the interface (for
/// example, Send becomes Stop).
public struct MeetingAgentActivity: Hashable, Sendable {
    public var kind: MeetingAgentRunKind
    public var cli: MeetingAgentCLI
    public var started: Date

    public init(kind: MeetingAgentRunKind, cli: MeetingAgentCLI, started: Date) {
        self.kind = kind
        self.cli = cli
        self.started = started
    }
}

/// One event of a streamed answer. `textDelta` adds text to the answer that
/// the interface shows; `textReset` clears it (the agent started a new
/// message). `finished` carries the final answer, which replaces the
/// streamed text.
public enum MeetingAgentStreamEvent: Hashable, Sendable {
    /// The process started.
    case started
    case textDelta(String)
    case textReset
    case finished(MeetingAgentReply)
}

/// The result of a name-suggestion run.
public enum MeetingNameSuggestionResult: Hashable, Sendable {
    /// The suggested name for each label (never empty).
    case names([MeetingSpeakerLabel: String])
    /// The agent ran and found no name in the transcript.
    case noNamesFound
    /// The meeting has no speaker label to name, so no agent ran.
    case nothingToName
}

/// A runner that streams answers and can stop one run. The interface reads
/// it through `feature.agentRunner as? any MeetingAgentStreaming`.
public protocol MeetingAgentStreaming: Sendable {
    /// Asks a question. The stream ends after `finished`, or with a
    /// `MeetingAgentError`. Ending the iteration cancels the run.
    func askStream(_ question: String, about meeting: MeetingID, using cli: MeetingAgentCLI)
        -> AsyncThrowingStream<MeetingAgentStreamEvent, Error>
    /// Stops the run of this kind for this meeting, if one runs.
    func cancelRun(_ kind: MeetingAgentRunKind, for meeting: MeetingID) async
    /// Speaker-name suggestions that tell "no names found" apart from
    /// "nothing to name".
    func suggestSpeakerNameResult(for meeting: MeetingID, using cli: MeetingAgentCLI)
        async throws -> MeetingNameSuggestionResult
}

/// Why a probe of a CLI failed.
public enum MeetingAgentProbeFailure: String, Hashable, Codable, Sendable {
    /// `--version` gave no version.
    case versionUnreadable
    case launchFailed
    case timedOut
    /// The probe run gave no answer.
    case noAnswer
    /// The CLI does not know a setting that Rafu uses.
    case settingNotKnown
    /// Rafu could not read the tool list that Codex sends to the model.
    case toolListUnreadable
    /// The CLI used a tool during the probe run.
    case toolEvent
    /// The CLI wrote a file during the probe run.
    case wroteFiles

    public var message: String {
        switch self {
        case .versionUnreadable: "Rafu could not read the version."
        case .launchFailed: "The agent did not start."
        case .timedOut: "The agent gave no answer in time."
        case .noAnswer: "The agent gave no answer."
        case .settingNotKnown: "This version does not know a setting that Rafu uses."
        case .toolListUnreadable: "Rafu could not check the tools of this version."
        case .toolEvent: "The agent used a tool that Rafu does not allow."
        case .wroteFiles: "The agent wrote a file."
        }
    }
}

/// The result of a probe: a short check, with fixed text only, that a CLI
/// starts, is signed in and stays inside Rafu's limits.
public enum MeetingAgentProbeResult: Hashable, Codable, Sendable {
    case ready
    case notInstalled
    case notSignedIn
    case unsupportedVersion(found: String)
    case failed(reason: MeetingAgentProbeFailure)

    public var isReady: Bool { self == .ready }

    public var message: String {
        switch self {
        case .ready: "ready"
        case .notInstalled: "not installed"
        case .notSignedIn: "not signed in"
        case .unsupportedVersion: "this version is not supported"
        case .failed(let reason): reason.message
        }
    }
}

/// A runner that can probe a CLI. The interface reads it through
/// `feature.agentRunner as? any MeetingAgentProbing`. A ready result stays
/// until the CLI binary changes; `refresh` probes again.
public protocol MeetingAgentProbing: Sendable {
    func probe(_ cli: MeetingAgentCLI, refresh: Bool) async -> MeetingAgentProbeResult
}

/// One decision or action item of a meeting summary.
public struct MeetingSummaryItem: Hashable, Codable, Sendable {
    public var text: String
    /// The person who owns it, when the transcript names one.
    public var owner: String?
    public var citations: [MeetingTurnID]

    public init(text: String, owner: String? = nil, citations: [MeetingTurnID] = []) {
        self.text = text
        self.owner = owner
        self.citations = citations
    }
}

/// The title and summary that the hidden agent wrote for one meeting
/// (`notes.json` in the meeting folder). `textRevision` is the text revision
/// of the meeting that the agent read: when the text is made again, the
/// notes are stale.
public struct MeetingSummaryNotes: Hashable, Codable, Sendable {
    public static let currentSchema = 1

    public var schema: Int
    public var title: String
    public var summaryMarkdown: String
    public var decisions: [MeetingSummaryItem]
    public var actionItems: [MeetingSummaryItem]
    public var citations: [MeetingTurnID]
    /// The agent that wrote the notes.
    public var cli: MeetingAgentCLI
    public var date: Date
    public var textRevision: Int

    public init(
        schema: Int = MeetingSummaryNotes.currentSchema, title: String, summaryMarkdown: String,
        decisions: [MeetingSummaryItem] = [], actionItems: [MeetingSummaryItem] = [],
        citations: [MeetingTurnID] = [], cli: MeetingAgentCLI, date: Date, textRevision: Int
    ) {
        self.schema = schema
        self.title = title
        self.summaryMarkdown = summaryMarkdown
        self.decisions = decisions
        self.actionItems = actionItems
        self.citations = citations
        self.cli = cli
        self.date = date
        self.textRevision = textRevision
    }
}

/// Where the summary of one meeting is, for the interface.
public enum MeetingSummaryState: Hashable, Sendable {
    /// No summary, and none is being written.
    case none
    case generating
    case ready
    /// No agent is ready (not installed, not signed in, not supported).
    case unavailable
    /// The text was made again after the summary was written.
    case stale
    case failed(MeetingAgentError)
}

/// Settings ▸ Meetings: write a title and a summary after each processing
/// job. On by default.
public enum MeetingAutoSummaryPreference {
    public static let key = "meetings.autoSummary"

    /// True when the key is missing.
    public static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) == nil ? true : defaults.bool(forKey: key)
    }
}
