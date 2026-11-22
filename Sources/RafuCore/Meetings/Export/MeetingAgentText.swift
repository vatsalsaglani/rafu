import Foundation

/// The plain text that the hidden meeting agent reads, made from one
/// meeting. The same text goes into the two snapshot files and into the
/// one-string packet for the standard-input design. Echo turns are left
/// out (they repeat the far side), and each line carries its turn id so an
/// answer can cite it.
public enum MeetingAgentText {
    /// `meeting.md`: title, date, length and speakers.
    public static func overview(
        _ document: MeetingDocument, timeZone: TimeZone = .current
    ) -> String {
        let summary = document.summary
        var lines = ["# Meeting", ""]
        lines.append("Title: " + MeetingMarkdownExporter.singleLine(summary.title))
        lines.append(
            "Date: " + MeetingMarkdownExporter.dateText(summary.startDate, timeZone: timeZone))
        lines.append("Length: " + MeetingClockText.text(summary.duration))
        let speakers = document.speakerDisplayNames(includeEcho: false)
        lines.append("Speakers: " + (speakers.isEmpty ? "none" : speakers.joined(separator: ", ")))
        return lines.joined(separator: "\n") + "\n"
    }

    /// `transcript.md`: one line for each turn, `[t9 12:27] Priya: text`.
    public static func transcript(_ document: MeetingDocument) -> String {
        var lines: [String] = []
        for turn in document.shownTurns(includeEcho: false) {
            lines.append(
                "[\(turn.id.text) \(MeetingClockText.text(turn.start))] "
                    + MeetingMarkdownExporter.singleLine(document.displayName(for: turn.speaker))
                    + ": " + MeetingMarkdownExporter.singleLine(turn.text))
        }
        return lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n")
    }

    /// Both texts as one string, for a packet on standard input.
    public static func packet(_ document: MeetingDocument, timeZone: TimeZone = .current) -> String
    {
        "=== meeting.md ===\n" + overview(document, timeZone: timeZone)
            + "\n=== transcript.md ===\n" + transcript(document)
    }
}
