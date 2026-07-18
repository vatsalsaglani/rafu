import Foundation

/// One ghost-text annotation drawn after the caret line's content: the
/// inline-blame summary for that line. Pure value type — `RafuTextView`
/// draws it in `drawBackground`, never touching `NSTextStorage`. See ADR
/// 0013 for why this lives past line-end rather than in the gutter.
nonisolated struct InlineBlameAnnotation: Equatable, Sendable {
    /// 1-based line number this annotation targets. `CodeEditorView.Coordinator`
    /// only ever sets an annotation whose `lineNumber` matches the caret's
    /// current line; a caret move to a different line clears the annotation
    /// before scheduling a new lookup (see `scheduleInlineBlame()`).
    let lineNumber: Int
    /// The formatted "Author • relative-time • summary" ghost text, already
    /// middle-truncated to the formatter's character budget.
    let text: String
}

/// Pure formatter for inline-blame ghost text: "Author • relative-time •
/// summary", middle-truncated to a character budget. Relative time is always
/// computed against an INJECTED reference `Date` (never `Date()` internally)
/// so callers — and tests — get deterministic output.
nonisolated enum InlineBlameFormatter {
    /// Default character budget for the formatted annotation, chosen to stay
    /// comfortably inside a typical editor line's remaining width.
    static let defaultCharacterBudget = 80

    /// Formats one blamed line's ghost text against `referenceDate`.
    static func format(
        _ line: GitBlameLine,
        referenceDate: Date,
        characterBudget: Int = defaultCharacterBudget
    ) -> String {
        let relative = relativeTime(from: line.time, to: referenceDate)
        let full = "\(line.author) • \(relative) • \(line.summary)"
        return middleTruncated(full, characterBudget: characterBudget)
    }

    /// A short, deterministic relative-time phrase ("just now", "5m ago",
    /// "3h ago", "2d ago", "6w ago", "4mo ago", "2y ago"). A `date` after
    /// `referenceDate` (clock skew) clamps to "just now" rather than
    /// producing a negative duration.
    static func relativeTime(from date: Date, to referenceDate: Date) -> String {
        let seconds = max(0, referenceDate.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<604_800: return "\(Int(seconds / 86_400))d ago"
        case ..<2_629_800: return "\(Int(seconds / 604_800))w ago"
        case ..<31_557_600: return "\(Int(seconds / 2_629_800))mo ago"
        default: return "\(Int(seconds / 31_557_600))y ago"
        }
    }

    /// Middle-truncates `text` to at most `characterBudget` characters:
    /// keeps a head and tail slice with a single ellipsis between them, so
    /// the author/time prefix and the tail of a long summary both stay
    /// legible. A no-op when `text` already fits within the budget.
    static func middleTruncated(_ text: String, characterBudget: Int) -> String {
        guard characterBudget > 0, text.count > characterBudget else { return text }
        let ellipsis = "…"
        guard characterBudget > ellipsis.count else {
            return String(text.prefix(characterBudget))
        }
        let keep = characterBudget - ellipsis.count
        let headCount = (keep + 1) / 2
        let tailCount = keep - headCount
        let head = text.prefix(headCount)
        let tail = text.suffix(tailCount)
        return "\(head)\(ellipsis)\(tail)"
    }
}
