import Foundation

/// A name that someone proposes for a speaker label, with where it came from.
public struct MeetingSpeakerNameSuggestion: Hashable, Sendable {
    public var label: MeetingSpeakerLabel
    public var name: String
    public var source: MeetingNameSource

    public init(label: MeetingSpeakerLabel, name: String, source: MeetingNameSource) {
        self.label = label
        self.name = name
        self.source = source
    }
}

/// The confirmed names of the speakers of one meeting (label to name).
///
/// Only an edit with source `.user` changes a name. An agent suggestion is
/// data for the interface to show; no function here applies one.
public struct MeetingSpeakerNames: Hashable, Codable, Sendable {
    /// The longest name that is kept.
    public static let maximumNameLength = 80

    public private(set) var names: [MeetingSpeakerLabel: String]

    public init(names: [MeetingSpeakerLabel: String] = [:]) {
        var cleaned: [MeetingSpeakerLabel: String] = [:]
        for (label, name) in names {
            let value = Self.cleaned(name)
            if !value.isEmpty { cleaned[label] = value }
        }
        self.names = cleaned
    }

    // MARK: Reading

    /// The confirmed name, or nil.
    public func name(for label: MeetingSpeakerLabel) -> String? {
        names[label]
    }

    /// The name the interface shows: the confirmed name, else the default.
    public func displayName(for label: MeetingSpeakerLabel) -> String {
        names[label] ?? Self.defaultName(for: label)
    }

    /// "Me", "Them" or "Speaker 2".
    public static func defaultName(for label: MeetingSpeakerLabel) -> String {
        switch label {
        case .me: "Me"
        case .them: "Them"
        case .speaker(let number): "Speaker \(number)"
        }
    }

    /// The labels of the far side that have no confirmed name, in the order of
    /// their first turn. "Me" is never in the list. Echo turns do not count.
    public func namesToCheck(in turns: [MeetingTurn]) -> [MeetingSpeakerLabel] {
        var seen = Set<MeetingSpeakerLabel>()
        var result: [MeetingSpeakerLabel] = []
        for turn in turns where !turn.isEcho && turn.speaker != .me {
            guard seen.insert(turn.speaker).inserted else { continue }
            if names[turn.speaker] == nil { result.append(turn.speaker) }
        }
        return result
    }

    /// The confirmed names as suggestions with source `.user`.
    public var confirmedSuggestions: [MeetingSpeakerNameSuggestion] {
        names.map { MeetingSpeakerNameSuggestion(label: $0.key, name: $0.value, source: .user) }
            .sorted { $0.label.storageKey < $1.label.storageKey }
    }

    // MARK: Edits and suggestions

    /// The edit for a rename by the user. It does not change this value; add
    /// the edit to a `MeetingEditList` and replay.
    public func rename(_ label: MeetingSpeakerLabel, to name: String) -> MeetingEdit {
        .renameSpeaker(label: label, name: name, source: .user)
    }

    /// Turns the answer of the meeting agent into suggestions with source
    /// `.agent`. Nothing is applied. Blank names and the label "Me" are left
    /// out. `evidence` lists the turns the agent used for each label.
    public static func agentSuggestions(
        _ suggested: [MeetingSpeakerLabel: String],
        evidence: [MeetingSpeakerLabel: [MeetingTurnID]] = [:]
    ) -> [MeetingSpeakerNameSuggestion] {
        suggested.compactMap { label, name in
            let value = cleaned(name)
            guard label != .me, !value.isEmpty else { return nil }
            return MeetingSpeakerNameSuggestion(
                label: label, name: value,
                source: .agent(evidence: (evidence[label] ?? []).sorted()))
        }
        .sorted { $0.label.storageKey < $1.label.storageKey }
    }

    // MARK: Replay

    /// The names after replaying `edits` in order. A later rename of a label
    /// wins. Only edits with source `.user` count; an empty name removes the
    /// name.
    public static func replaying(_ edits: [MeetingEdit]) -> MeetingSpeakerNames {
        var names = MeetingSpeakerNames()
        for edit in edits {
            guard case .renameSpeaker(let label, let name, .user) = edit else { continue }
            let value = cleaned(name)
            if value.isEmpty {
                names.names[label] = nil
            } else {
                names.names[label] = value
            }
        }
        return names
    }

    /// Replays the rename edits and returns each turn with its speaker name.
    /// Edits of other kinds are ignored here (see `MeetingEditList.display`).
    /// Pure: the same input gives the same output, and no turn id changes.
    public static func apply(_ edits: [MeetingEdit], to turns: [MeetingTurn])
        -> [MeetingDisplayTurn]
    {
        let names = replaying(edits)
        return turns.map {
            MeetingDisplayTurn(
                turn: $0, speakerName: names.displayName(for: $0.speaker), isHidden: $0.isEcho)
        }
    }

    private static func cleaned(_ name: String) -> String {
        String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumNameLength))
    }

    // MARK: Codable

    /// Stored as `{"speaker-2": "Priya"}`: a label key is text, so the file
    /// is an object, not an array of pairs.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode([String: String].self)
        var decoded: [MeetingSpeakerLabel: String] = [:]
        for (key, name) in stored {
            guard let label = MeetingSpeakerLabel(storageKey: key) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Unknown speaker label \(key).")
            }
            decoded[label] = name
        }
        self.init(names: decoded)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(
            Dictionary(uniqueKeysWithValues: names.map { ($0.key.storageKey, $0.value) }))
    }
}
