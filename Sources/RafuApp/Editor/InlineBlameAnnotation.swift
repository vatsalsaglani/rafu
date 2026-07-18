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

    // MARK: - Issue #15: full-file blame

    /// Maps every entry in `lines` to its 1-based line's starting UTF-16
    /// character offset in `text`, formatted exactly like
    /// `format(_:referenceDate:characterBudget:)`. The offset key (rather
    /// than the raw line number) is what `RafuTextView.fileBlameAnnotations`
    /// draws against — see its doc comment for why. A `GitBlameLine` whose
    /// `lineNumber` falls outside `text`'s actual line count (a blame reply
    /// racing a structural edit) is skipped rather than mapped to a wrong
    /// offset.
    static func fileAnnotations(
        for lines: [GitBlameLine],
        in text: String,
        referenceDate: Date,
        characterBudget: Int = defaultCharacterBudget
    ) -> [Int: String] {
        let offsets = lineStartOffsets(in: text)
        var result: [Int: String] = [:]
        result.reserveCapacity(lines.count)
        for line in lines {
            guard line.lineNumber >= 1, line.lineNumber <= offsets.count else { continue }
            result[offsets[line.lineNumber - 1]] = format(
                line, referenceDate: referenceDate, characterBudget: characterBudget)
        }
        return result
    }

    /// The UTF-16 starting offset of every line in `text`, indexed 0-based
    /// by (1-based line number − 1) — index 0 (line 1) is always 0. Pure
    /// equivalent of `EditorGutterRulerView`'s own line-start index,
    /// computed independently here so this stays a value-type function with
    /// no `NSTextStorage`/AppKit dependency and is directly unit-testable.
    static func lineStartOffsets(in text: String) -> [Int] {
        let content = text as NSString
        var offsets: [Int] = [0]
        var location = 0
        while location < content.length {
            var lineEnd = 0
            var contentsEnd = 0
            content.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            if lineEnd >= content.length {
                // A trailing newline yields one final empty line.
                if contentsEnd < lineEnd { offsets.append(lineEnd) }
                break
            }
            offsets.append(lineEnd)
            location = lineEnd
        }
        return offsets
    }
}
