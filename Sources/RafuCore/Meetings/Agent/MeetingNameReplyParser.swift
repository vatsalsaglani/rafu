import Foundation

/// The speaker-name suggestions of one reply, before Rafu drops the labels
/// that are not in the meeting.
public struct MeetingNameSuggestionsReply: Hashable, Sendable {
    public var names: [MeetingSpeakerLabel: String]
    public var evidence: [MeetingSpeakerLabel: [MeetingTurnID]]

    public init(
        names: [MeetingSpeakerLabel: String] = [:],
        evidence: [MeetingSpeakerLabel: [MeetingTurnID]] = [:]
    ) {
        self.names = names
        self.evidence = evidence
    }
}

/// Reads a name-suggestion reply: one JSON object only, for example
/// `{"speaker-2": {"name": "Priya", "evidence": ["t1", "t13"]}}`. A key
/// must be a speaker label; `me` is dropped; a name is trimmed, one line,
/// at most `MeetingSpeakerNames.maximumNameLength` characters; each
/// evidence id is a turn id. A label with no evidence is left out. Any
/// other shape fails the whole reply. One Markdown code fence around the
/// object is allowed, because a model often adds one.
public enum MeetingNameReplyParser {
    public enum Problem: Error, Hashable, Sendable {
        case failed
    }

    public static func parse(_ text: String) throws(Problem) -> MeetingNameSuggestionsReply {
        let body = stripFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = body.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data, options: []))
                as? [String: Any]
        else { throw .failed }
        var reply = MeetingNameSuggestionsReply()
        for (key, value) in object {
            guard let label = MeetingSpeakerLabel(storageKey: key),
                let entry = value as? [String: Any],
                let rawName = entry["name"] as? String,
                let rawEvidence = entry["evidence"] as? [Any]
            else { throw .failed }
            var evidence: [MeetingTurnID] = []
            for item in rawEvidence {
                guard let idText = item as? String, let id = MeetingTurnID(text: idText) else {
                    throw .failed
                }
                if !evidence.contains(id) { evidence.append(id) }
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.contains(where: \.isNewline),
                name.count <= MeetingSpeakerNames.maximumNameLength,
                !name.unicodeScalars.contains(where: {
                    $0.properties.generalCategory == .control
                })
            else { throw .failed }
            guard label != .me, !name.isEmpty, !evidence.isEmpty else { continue }
            reply.names[label] = name
            reply.evidence[label] = evidence
        }
        return reply
    }

    private static func stripFence(_ text: String) -> String {
        guard text.hasPrefix("```"), text.hasSuffix("```"), text.count >= 6 else { return text }
        var inner = text.dropFirst(3).dropLast(3)
        if let newline = inner.firstIndex(of: "\n") {
            let tag = inner[..<newline].trimmingCharacters(in: .whitespaces)
            if tag.isEmpty || tag == "json" { inner = inner[inner.index(after: newline)...] }
        }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
