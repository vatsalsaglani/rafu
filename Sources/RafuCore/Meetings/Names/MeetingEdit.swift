import Foundation

/// Who gave a speaker name. Only `.user` changes a name.
public enum MeetingNameSource: Hashable, Codable, Sendable {
    /// The user typed or confirmed the name.
    case user
    /// The meeting agent suggested the name. `evidence` lists the turns it
    /// used (example: `t4`, `t9`), so the user can check them.
    case agent(evidence: [MeetingTurnID])
}

/// One change the user makes to a transcript. The turn ids never change; an
/// edit only changes what a turn shows.
public enum MeetingEdit: Hashable, Codable, Sendable {
    /// Gives a speaker label a name (example: "Speaker 2" is "Priya"). An empty
    /// name takes the name away. An edit with a source other than `.user`
    /// changes nothing when replayed.
    case renameSpeaker(label: MeetingSpeakerLabel, name: String, source: MeetingNameSource)
    /// Replaces the shown text of one turn. The recognised text stays in the
    /// stored turn.
    case correctText(turn: MeetingTurnID, text: String)
    /// Shows (`true`) or hides (`false`) one echo turn. It has no effect on a
    /// turn that is not marked as echo.
    case setEchoShown(turn: MeetingTurnID, shown: Bool)
}

/// A turn as the interface shows it: the corrected text, the speaker name and
/// whether it is hidden. The stored turn is unchanged.
public struct MeetingDisplayTurn: Hashable, Sendable, Identifiable {
    /// The stored turn with the shown text (`text` is the corrected text).
    public var turn: MeetingTurn
    /// The name of the speaker (example: "Priya", or "Speaker 2" with no name).
    public var speakerName: String
    /// True for an echo turn that the user has not asked to see.
    public var isHidden: Bool

    public init(turn: MeetingTurn, speakerName: String, isHidden: Bool) {
        self.turn = turn
        self.speakerName = speakerName
        self.isHidden = isHidden
    }

    public var id: MeetingTurnID { turn.id }
}
