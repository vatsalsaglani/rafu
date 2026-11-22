import Foundation

/// Options of one Markdown export.
public struct MeetingExportOptions: Hashable, Sendable {
    /// Echo turns (a "Me" turn that repeats the far side) are left out
    /// unless this is true.
    public var includeEchoTurns: Bool
    /// The time zone of the date line. A test sets a fixed one.
    public var timeZone: TimeZone

    public init(includeEchoTurns: Bool = false, timeZone: TimeZone = .current) {
        self.includeEchoTurns = includeEchoTurns
        self.timeZone = timeZone
    }
}

/// The pure Markdown export of one meeting: title, date, length, speakers,
/// the conversation (questions, answers and citations as `t9 12:27`), then
/// the transcript. It returns a `String`; the caller decides where it goes
/// (the clipboard, or a file after a save panel).
public enum MeetingMarkdownExporter {
    public static func export(
        _ document: MeetingDocument, options: MeetingExportOptions = MeetingExportOptions()
    ) -> String {
        var lines: [String] = []
        let summary = document.summary
        lines.append("# " + inlineText(summary.title))
        lines.append("")
        lines.append("- **Date:** " + dateText(summary.startDate, timeZone: options.timeZone))
        lines.append("- **Length:** " + MeetingClockText.text(summary.duration))
        let speakers = document.speakerDisplayNames(includeEcho: options.includeEchoTurns)
        if !speakers.isEmpty {
            lines.append("- **Speakers:** " + speakers.map(inlineText).joined(separator: ", "))
        }

        if !document.conversation.isEmpty {
            lines.append("")
            lines.append("## Conversation")
            for entry in document.conversation {
                lines.append("")
                lines.append(contentsOf: conversationLines(entry, document: document))
            }
        }

        lines.append("")
        lines.append("## Transcript")
        let turns = document.shownTurns(includeEcho: options.includeEchoTurns)
        if turns.isEmpty {
            lines.append("")
            lines.append("_No transcript._")
        }
        for turn in turns {
            lines.append("")
            let marker = turn.isEcho ? " (echo)" : ""
            lines.append(
                "**[\(turn.id.text) \(MeetingClockText.text(turn.start))] "
                    + inlineText(document.displayName(for: turn.speaker)) + marker + ":** "
                    + singleLine(turn.text))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A file name for the save panel: the title cleaned for a file system,
    /// the date, and `.md`.
    public static func suggestedFileName(
        title: String, startDate: Date, timeZone: TimeZone = .current
    ) -> String {
        var allowed = ""
        for character in title {
            if character.isLetter || character.isNumber || character == " " || character == "-"
                || character == "_"
            {
                allowed.append(character)
            }
        }
        let trimmed = allowed.trimmingCharacters(in: .whitespaces).prefix(60)
        let base = trimmed.isEmpty ? "Meeting" : String(trimmed)
        return base + " " + dayText(startDate, timeZone: timeZone) + ".md"
    }

    // MARK: Pieces

    private static func conversationLines(
        _ entry: MeetingConversationEntry, document: MeetingDocument
    ) -> [String] {
        switch entry.role {
        case .question:
            return ["**Question:** " + singleLine(entry.text)]
        case .answer:
            let name = entry.cli.map(agentName) ?? "Agent"
            var lines = ["**Answer (\(name)):**", ""]
            for line in entry.text.split(separator: "\n", omittingEmptySubsequences: false) {
                lines.append(line.isEmpty ? ">" : "> " + line)
            }
            if !entry.citations.isEmpty {
                lines.append(">")
                lines.append("> Sources:")
                for citation in entry.citations {
                    lines.append("> - " + citationText(citation, document: document))
                }
            }
            return lines
        }
    }

    /// `t9 12:27 "quote"`. The time comes from the cited turn; a turn that
    /// is not in the meeting has no time.
    static func citationText(_ citation: MeetingCitation, document: MeetingDocument) -> String {
        var text = citation.turn.text
        if let turn = document.turns.first(where: { $0.id == citation.turn }) {
            text += " " + MeetingClockText.text(turn.start)
        }
        let quote = singleLine(citation.quote)
        if !quote.isEmpty { text += " \"\(quote)\"" }
        return text
    }

    static func agentName(_ cli: MeetingAgentCLI) -> String {
        switch cli {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    static func dateText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm xxx"
        return formatter.string(from: date)
    }

    static func dayText(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// One line: each line break becomes a space.
    static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// One line, with the Markdown characters that change the look of the
    /// line escaped. For a title and a speaker name.
    static func inlineText(_ text: String) -> String {
        var result = ""
        for character in singleLine(text) {
            if "\\`*_[]<>".contains(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }
}
