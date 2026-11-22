import Foundation

/// The edits of one meeting, in the order the user made them. The list only
/// grows, except that `undoLast()` takes the newest edit away. The stored
/// turns are never changed: the list is replayed on top of them.
public struct MeetingEditList: Hashable, Codable, Sendable {
    public private(set) var edits: [MeetingEdit]

    public init(edits: [MeetingEdit] = []) {
        self.edits = edits
    }

    public var isEmpty: Bool { edits.isEmpty }

    /// Adds an edit at the end.
    public mutating func append(_ edit: MeetingEdit) {
        edits.append(edit)
    }

    /// Removes and returns the newest edit, or nil for an empty list.
    @discardableResult
    public mutating func undoLast() -> MeetingEdit? {
        edits.popLast()
    }

    /// The speaker names after the replay of all edits.
    public var speakerNames: MeetingSpeakerNames {
        MeetingSpeakerNames.replaying(edits)
    }

    /// Replays every edit on `turns`: speaker names, corrected text, and echo
    /// turns shown on request. Pure; the turns and their ids are not changed.
    /// An edit for a turn id that is not in `turns` is ignored; the newest edit
    /// of a kind for a turn wins.
    public func display(_ turns: [MeetingTurn]) -> [MeetingDisplayTurn] {
        let names = speakerNames
        var corrected: [MeetingTurnID: String] = [:]
        var shown: [MeetingTurnID: Bool] = [:]
        for edit in edits {
            switch edit {
            case .renameSpeaker:
                break
            case .correctText(let turn, let text):
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { corrected[turn] = value }
            case .setEchoShown(let turn, let isShown):
                shown[turn] = isShown
            }
        }
        return turns.map { turn in
            var shownTurn = turn
            if let text = corrected[turn.id] { shownTurn.text = text }
            return MeetingDisplayTurn(
                turn: shownTurn,
                speakerName: names.displayName(for: turn.speaker),
                isHidden: turn.isEcho && shown[turn.id] != true)
        }
    }
}
