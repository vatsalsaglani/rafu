import Foundation

/// Why an open document was placed into guard mode (plain text, no syntax
/// highlighting, no `@`-symbol scan) instead of its normal editing mode.
nonisolated enum DocumentGuardReason: Equatable, Sendable {
    case tooLarge(bytes: Int)
    case longLine(length: Int)
}

/// The outcome of evaluating a document against the guard thresholds.
nonisolated enum DocumentGuardDecision: Equatable, Sendable {
    case normal
    case guarded(reason: DocumentGuardReason)
}

/// Pure, nonisolated thresholds and evaluation for Increment 2's large-file
/// guard mode. Computed once at document open (see
/// `CodeEditorView.Coordinator.load()`); never re-evaluated per keystroke.
nonisolated enum DocumentGuardPolicy {
    /// Deliberately below `WorkspaceFileService.maximumEditorBytes` (4 MB):
    /// the editor's open cap already rejects anything above 4 MB, so this
    /// threshold is what actually makes `.tooLarge` reachable in practice.
    static let maximumUnguardedBytes = 2 * 1_024 * 1_024

    /// UTF-16 code units. Minified single-line files (dense JSON, bundled
    /// JS, etc.) can be well under the byte cap yet still be pathological
    /// for regex-based highlighting, which rescans a window around every
    /// edit.
    static let maximumUnguardedLineLength = 10_000

    /// Byte-size and longest-line decision, given pre-measured inputs.
    /// `.tooLarge` takes precedence when both conditions are true.
    static func evaluate(byteCount: Int, maxLineLength: Int) -> DocumentGuardDecision {
        if byteCount > maximumUnguardedBytes {
            return .guarded(reason: .tooLarge(bytes: byteCount))
        }
        if maxLineLength > maximumUnguardedLineLength {
            return .guarded(reason: .longLine(length: maxLineLength))
        }
        return .normal
    }

    /// Longest run of UTF-16 code units between newline boundaries
    /// (`\n`, 0x0A), where the start and end of `text` also count as
    /// boundaries. Single O(n) pass over UTF-16 code units; no substring
    /// allocation.
    ///
    /// Only `\n` is treated as a line boundary. A file that uses lone `\r`
    /// line endings (no `\n` at all — classic Mac OS style, effectively
    /// unseen today) is measured as one single line spanning the whole
    /// file. This is a conservative bias toward guarding, not a bug: an
    /// all-`\r` file with no `\n` degrades to the same worst case
    /// regex-highlighting would hit on a genuinely single-line file, so
    /// guarding it is the safe outcome. CRLF line endings behave like `\n`
    /// endings: `\r` is just an ordinary character counted within its line.
    static func maxLineLength(in text: String) -> Int {
        var longest = 0
        var current = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                longest = max(longest, current)
                current = 0
            } else {
                current += 1
            }
        }
        return max(longest, current)
    }

    /// Off-main evaluation for use inside the document-load `Task`. Callers
    /// are expected to check `Task.checkCancellation()` around this call;
    /// see `CodeEditorView.Coordinator.load()`.
    @concurrent
    static func decide(for text: String) async -> DocumentGuardDecision {
        evaluate(byteCount: text.utf8.count, maxLineLength: maxLineLength(in: text))
    }
}
