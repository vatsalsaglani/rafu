import Foundation

/// A frozen copy of one meeting for the hidden agent: a new folder in a
/// private temporary root with `meeting.md` and `transcript.md` only. No
/// audio, no symbolic link, no dot file and no file named `AGENTS.md` or
/// `CLAUDE.md`. The caller removes the folder when the run ends.
public struct MeetingAgentSnapshot: Hashable, Sendable {
    public var meeting: MeetingID
    public var folder: URL

    public init(meeting: MeetingID, folder: URL) {
        self.meeting = meeting
        self.folder = folder
    }

    public var transcriptURL: URL {
        folder.appending(path: "transcript.md", directoryHint: .notDirectory)
    }

    public var overviewURL: URL {
        folder.appending(path: "meeting.md", directoryHint: .notDirectory)
    }

    /// Removes the folder and what the caller put in it. Safe to call twice.
    public func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

/// What the library offers beside the `MeetingStoring` contract: the writes
/// that the recorder, the speech code and the agent code need, and the
/// frozen snapshot of one meeting. `MeetingStore` conforms. Code that holds
/// the registered `any MeetingStoring` reaches these with
/// `store as? any MeetingLibraryServicing`.
public protocol MeetingLibraryServicing: MeetingStoring {
    /// Sets the recorded length (seconds).
    @discardableResult
    func setDuration(_ seconds: TimeInterval, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    /// Sets the engines and model revisions that made the text.
    @discardableResult
    func setEngines(_ engines: MeetingEngineUse, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    /// Replaces the whole transcript (the text made again after Stop). One
    /// atomic write: the old turns stay until the new file is in place. The
    /// text edits of the old turns are dropped; speaker names stay.
    @discardableResult
    func replaceTurns(_ turns: [MeetingTurn], in meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    /// Edits the text of one turn. The turn keeps its id; the turns file is
    /// not rewritten.
    @discardableResult
    func editTurnText(
        _ turn: MeetingTurnID, to text: String, in meeting: MeetingID, expectedVersion: Int
    ) async throws -> Int
    /// The speaker names that the user confirmed.
    func speakerNames(of meeting: MeetingID) async throws -> [MeetingSpeakerLabel: String]

    /// Appends a question or an answer. Citations that point at no turn are
    /// dropped; the return value is how many were dropped. The meeting
    /// version does not change.
    @discardableResult
    func appendConversation(_ entry: MeetingConversationEntry, to meeting: MeetingID)
        async throws -> Int
    func conversation(of meeting: MeetingID) async throws -> [MeetingConversationEntry]
    func verifyCitations(_ citations: [MeetingCitation], in meeting: MeetingID) async throws
        -> MeetingCitationCheck

    /// The frozen copy for the hidden agent. The caller removes the folder.
    func makeAgentSnapshot(of meeting: MeetingID) async throws -> MeetingAgentSnapshot
    /// The whole meeting with edits applied, for one export or one agent
    /// run. Never keep it in observable state.
    func document(of meeting: MeetingID) async throws -> MeetingDocument
    /// The Markdown export with options (echo turns, time zone). The
    /// contract's `exportMarkdown(of:)` uses the defaults.
    func exportMarkdown(of meeting: MeetingID, options: MeetingExportOptions) async throws
        -> String
    /// The lines that a read skipped in this meeting.
    func readReport(of meeting: MeetingID) async throws -> MeetingReadReport
    /// Makes the search index again from the files.
    func rebuildSearchIndex() async throws
}
