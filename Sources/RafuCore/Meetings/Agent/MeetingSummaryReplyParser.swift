import Foundation

/// Reads a summary reply: one JSON object only, for example
/// `{"title": "Launch plan", "summary": "Ship on March 14 [t2].",
/// "decisions": [{"text": "Ship", "owner": null, "turns": ["t2"]}],
/// "actionItems": [{"text": "Send notes", "owner": "Priya", "turns": ["t5"]}]}`.
///
/// The reply is untrusted data. The title is one line of at most 80
/// characters, the summary at most 8 KB, at most 20 decisions and 20 action
/// items of at most 400 characters each, an owner one line of at most 80
/// characters. Control characters are removed. A turn id that the meeting
/// does not have is dropped. Any other shape fails the whole reply. One
/// Markdown code fence around the object is allowed.
public enum MeetingSummaryReplyParser {
    public enum Problem: Error, Hashable, Sendable {
        case failed
    }

    public static func parse(
        _ text: String, knownTurns: Set<MeetingTurnID>, cli: MeetingAgentCLI, date: Date,
        textRevision: Int
    ) throws(Problem) -> MeetingSummaryNotes {
        let body = stripFence(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let data = body.data(using: .utf8),
            let object = (try? JSONSerialization.jsonObject(with: data, options: []))
                as? [String: Any]
        else { throw .failed }

        guard let rawTitle = object["title"] as? String else { throw .failed }
        let title = singleLine(rawTitle)
        guard !title.isEmpty, title.count <= MeetingAgentLimits.maximumSummaryTitleCharacters
        else { throw .failed }

        guard let rawSummary = object["summary"] as? String,
            rawSummary.utf8.count <= MeetingAgentLimits.maximumSummaryBytes
        else { throw .failed }
        let summary = MeetingAgentAnswerText.filtered(rawSummary)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw .failed }

        let decisions = try items(object["decisions"], knownTurns: knownTurns)
        let actionItems = try items(object["actionItems"], knownTurns: knownTurns)

        var citations: [MeetingTurnID] = []
        var seen = Set<MeetingTurnID>()
        let cited =
            MeetingCitationParser.citations(in: summary) + decisions.flatMap(\.citations)
            + actionItems.flatMap(\.citations)
        for id in cited where knownTurns.contains(id) && seen.insert(id).inserted {
            citations.append(id)
        }
        return MeetingSummaryNotes(
            title: title, summaryMarkdown: summary, decisions: decisions,
            actionItems: actionItems, citations: citations, cli: cli, date: date,
            textRevision: textRevision)
    }

    /// A missing list is empty; any other shape fails.
    private static func items(_ value: Any?, knownTurns: Set<MeetingTurnID>) throws(Problem)
        -> [MeetingSummaryItem]
    {
        guard let value, !(value is NSNull) else { return [] }
        guard let list = value as? [Any], list.count <= MeetingAgentLimits.maximumSummaryItems
        else { throw .failed }
        var result: [MeetingSummaryItem] = []
        for entry in list {
            guard let item = entry as? [String: Any], let rawText = item["text"] as? String else {
                throw .failed
            }
            let text = singleLine(rawText)
            guard !text.isEmpty, text.count <= MeetingAgentLimits.maximumSummaryItemCharacters
            else { throw .failed }

            var owner: String?
            switch item["owner"] {
            case nil, is NSNull:
                owner = nil
            case let rawOwner as String:
                let cleaned = singleLine(rawOwner)
                guard cleaned.count <= MeetingSpeakerNames.maximumNameLength else { throw .failed }
                owner = cleaned.isEmpty ? nil : cleaned
            default:
                throw .failed
            }

            var turns: [MeetingTurnID] = []
            switch item["turns"] {
            case nil, is NSNull:
                break
            case let rawTurns as [Any]:
                guard rawTurns.count <= MeetingAgentLimits.maximumCitations else { throw .failed }
                for raw in rawTurns {
                    guard let idText = raw as? String else { throw .failed }
                    if let id = MeetingTurnID(text: idText), knownTurns.contains(id),
                        !turns.contains(id)
                    {
                        turns.append(id)
                    }
                }
            default:
                throw .failed
            }
            result.append(MeetingSummaryItem(text: text, owner: owner, citations: turns))
        }
        return result
    }

    /// One line: control characters and line breaks become spaces, runs of
    /// spaces become one, ends trimmed.
    static func singleLine(_ raw: String) -> String {
        let flat = MeetingAgentAnswerText.filtered(raw).replacingOccurrences(of: "\n", with: " ")
        return flat.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
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
