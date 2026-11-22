import Foundation

/// A write that found a newer version on disk than the caller expected.
public struct MeetingVersionConflict: Error, Hashable, Sendable {
    public var meeting: MeetingID
    public var expected: Int
    public var found: Int

    public init(meeting: MeetingID, expected: Int, found: Int) {
        self.meeting = meeting
        self.expected = expected
        self.found = found
    }
}

/// One page of turns.
public struct MeetingTurnPage: Hashable, Sendable {
    public var turns: [MeetingTurn]
    /// The id to pass for the next page, or nil at the end.
    public var nextAfter: MeetingTurnID?
    public var version: Int

    public init(turns: [MeetingTurn], nextAfter: MeetingTurnID?, version: Int) {
        self.turns = turns
        self.nextAfter = nextAfter
        self.version = version
    }
}

/// One search hit.
public struct MeetingSearchHit: Hashable, Sendable {
    public var meeting: MeetingID
    public var turn: MeetingTurnID?
    /// A short piece of the matching text.
    public var snippet: String

    public init(meeting: MeetingID, turn: MeetingTurnID?, snippet: String) {
        self.meeting = meeting
        self.turn = turn
        self.snippet = snippet
    }
}

/// The meeting library in Rafu's app data. Methods take and return ids and
/// values, never a workspace path. Each write takes the version the caller
/// read and throws `MeetingVersionConflict` when the stored one is newer.
public protocol MeetingStoring: Sendable {
    // Create and list.
    func create(title: String, startDate: Date) async throws -> MeetingSummaryRecord
    func list() async throws -> [MeetingSummaryRecord]
    func summary(of meeting: MeetingID) async throws -> MeetingSummaryRecord?

    // Turns.
    @discardableResult
    func appendTurns(_ turns: [MeetingTurn], to meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    func turns(of meeting: MeetingID, after: MeetingTurnID?, limit: Int) async throws
        -> MeetingTurnPage

    // Changes.
    @discardableResult
    func setState(_ state: MeetingState, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    @discardableResult
    func rename(_ meeting: MeetingID, title: String, expectedVersion: Int) async throws -> Int
    @discardableResult
    func renameSpeaker(
        _ label: MeetingSpeakerLabel, to name: String, in meeting: MeetingID,
        expectedVersion: Int
    ) async throws -> Int
    func delete(_ meeting: MeetingID) async throws

    // Search.
    func search(_ query: String, limit: Int) async throws -> [MeetingSearchHit]

    // Agent and export text (values, never paths).
    /// The plain text of one meeting for the hidden meeting agent.
    func agentPacketText(of meeting: MeetingID) async throws -> String
    /// The Markdown export of one meeting. The caller writes it after a
    /// save panel.
    func exportMarkdown(of meeting: MeetingID) async throws -> String

    // Sizes and audio.
    func sizeOnDisk(of meeting: MeetingID) async throws -> MeetingSizes
    func applyAudioRetention(_ retention: MeetingAudioRetention, now: Date) async throws
    /// The one path API: the folder of a meeting's audio, for the capture
    /// and speech code only. Never for an agent tool.
    func audioFolder(for meeting: MeetingID) async throws -> URL
}
