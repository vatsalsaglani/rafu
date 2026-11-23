import Foundation

/// The JSON settings for every meeting file: one object for each line or
/// file, ISO 8601 dates with milliseconds. Encoders and decoders are made
/// new for each use because `JSONEncoder` is not `Sendable`.
enum MeetingJSON {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Self.dateStyle))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            do {
                return try Date(text, strategy: Self.dateStyle)
            } catch {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Not an ISO 8601 date.")
            }
        }
        return decoder
    }

    private static var dateStyle: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    }
}

/// The content of `meeting.json`. It has no workspace field: a meeting
/// belongs to the app.
struct MeetingRecordFile: Codable, Sendable {
    static let currentSchema = 1

    var schema: Int = MeetingRecordFile.currentSchema
    var version: Int
    var id: MeetingID
    var title: String
    var startDate: Date
    var duration: TimeInterval
    var state: MeetingState
    var engines: MeetingEngineUse
}

/// One line of `edits.jsonl`. The turns file is never rewritten by an edit;
/// the latest line for a speaker or a turn wins when the meeting is read.
struct MeetingEditLine: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case speakerName
        case turnText
    }

    var kind: Kind
    var date: Date
    var speaker: MeetingSpeakerLabel?
    /// For `.speakerName`. An empty name clears the rename.
    var name: String?
    var turn: MeetingTurnID?
    /// For `.turnText`.
    var text: String?
}

/// The speaker renames and text edits of one meeting, folded from the edit
/// list (the latest line wins).
struct MeetingEdits: Sendable {
    var speakerNames: [MeetingSpeakerLabel: String] = [:]
    var turnTexts: [MeetingTurnID: String] = [:]
    var skippedLines = 0

    mutating func apply(_ line: MeetingEditLine) {
        switch line.kind {
        case .speakerName:
            guard let speaker = line.speaker else { return }
            if let name = line.name, !name.isEmpty {
                speakerNames[speaker] = name
            } else {
                speakerNames[speaker] = nil
            }
        case .turnText:
            guard let turn = line.turn, let text = line.text else { return }
            turnTexts[turn] = text
        }
    }
}

/// Who said a line of the conversation.
public enum MeetingConversationRole: String, Codable, Sendable {
    case question
    case answer
}

/// One line of `conversation.jsonl`: a question the user asked, or the
/// answer of the hidden agent with its checked citations. The answer names
/// the agent CLI that wrote it.
public struct MeetingConversationEntry: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var date: Date
    public var role: MeetingConversationRole
    public var text: String
    /// The agent that wrote an answer. Nil for a question.
    public var cli: MeetingAgentCLI?
    public var citations: [MeetingCitation]
    /// The text revision of the meeting when the line was written. An answer
    /// with an older revision than the meeting answered an older text. Nil
    /// in a line written before the revision existed.
    public var textRevision: Int?

    public init(
        id: UUID = UUID(), date: Date, role: MeetingConversationRole, text: String,
        cli: MeetingAgentCLI? = nil, citations: [MeetingCitation] = [], textRevision: Int? = nil
    ) {
        self.id = id
        self.date = date
        self.role = role
        self.text = text
        self.cli = cli
        self.citations = citations
        self.textRevision = textRevision
    }
}

/// The result of checking citations against a meeting.
public struct MeetingCitationCheck: Hashable, Sendable {
    /// The citations whose turn exists in the meeting, in the given order.
    public var verified: [MeetingCitation]
    /// How many citations pointed at no turn.
    public var failedCount: Int

    public init(verified: [MeetingCitation], failedCount: Int) {
        self.verified = verified
        self.failedCount = failedCount
    }
}

/// Counts of the lines that a read skipped (a damaged line or a line over
/// the limit). The files are never changed by a read.
public struct MeetingReadReport: Hashable, Sendable {
    public var skippedTurnLines = 0
    public var skippedEditLines = 0
    public var skippedConversationLines = 0

    public init(
        skippedTurnLines: Int = 0, skippedEditLines: Int = 0, skippedConversationLines: Int = 0
    ) {
        self.skippedTurnLines = skippedTurnLines
        self.skippedEditLines = skippedEditLines
        self.skippedConversationLines = skippedConversationLines
    }

    public var totalSkipped: Int {
        skippedTurnLines + skippedEditLines + skippedConversationLines
    }
}

/// Everything that export and the agent text need from one meeting, with
/// the edits already applied. It holds the full text, so it is a short-lived
/// value for one export or one agent run, never observable state.
public struct MeetingDocument: Sendable {
    public var summary: MeetingSummaryRecord
    public var turns: [MeetingTurn]
    /// The names that the user confirmed, by speaker label.
    public var speakerNames: [MeetingSpeakerLabel: String]
    public var conversation: [MeetingConversationEntry]

    public init(
        summary: MeetingSummaryRecord, turns: [MeetingTurn],
        speakerNames: [MeetingSpeakerLabel: String] = [:],
        conversation: [MeetingConversationEntry] = []
    ) {
        self.summary = summary
        self.turns = turns
        self.speakerNames = speakerNames
        self.conversation = conversation
    }

    /// The name shown for a speaker: the confirmed name, else `Me`, `Them`
    /// or `Speaker <n>`.
    public func displayName(for label: MeetingSpeakerLabel) -> String {
        if let name = speakerNames[label], !name.isEmpty { return name }
        switch label {
        case .me: return "Me"
        case .them: return "Them"
        case .speaker(let number): return "Speaker \(number)"
        }
    }

    /// The turns to show: echo turns only when `includeEcho` is true.
    public func shownTurns(includeEcho: Bool) -> [MeetingTurn] {
        includeEcho ? turns : turns.filter { !$0.isEcho }
    }

    /// The display names of the speakers of the shown turns, in the order
    /// of their first turn, with no repeat.
    public func speakerDisplayNames(includeEcho: Bool) -> [String] {
        var seen = Set<MeetingSpeakerLabel>()
        var names: [String] = []
        for turn in shownTurns(includeEcho: includeEcho) where seen.insert(turn.speaker).inserted {
            names.append(displayName(for: turn.speaker))
        }
        return names
    }
}

/// Clock text for a time on the meeting clock: `12:27`, or `1:02:03` from
/// one hour.
public enum MeetingClockText {
    public static func text(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(seconds.isFinite ? seconds : 0, 0), 1_000_000_000))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        if hours > 0 {
            return "\(hours):" + twoDigits(minutes) + ":" + twoDigits(rest)
        }
        return twoDigits(minutes) + ":" + twoDigits(rest)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
