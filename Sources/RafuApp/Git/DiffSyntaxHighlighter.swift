import Foundation
import SwiftTreeSitter

/// Off-main syntax highlighting for the editor-hosted diff canvas (Part A of
/// the diff-syntax-highlighting-and-hover phase). Parses per SIDE, not per
/// line: a lone `"` or unmatched `{` on a single diff row is meaningless
/// without its neighbors, so each side's line contents are joined with
/// `"\n"` into one string per file diff, highlighted in a single grammar
/// pass (via the shared `PlainTextSyntaxHighlighter`), and the resulting
/// spans are sliced back onto their originating lines. Exactly two parses
/// per opened diff (old + new) — joining across a hunk gap is accepted as
/// cosmetic (tokens rarely survive the gap anyway); this never reconstructs
/// the full file.
///
/// Computed once per opened diff and cached by the view layer
/// (`GitSideBySideDiffView`'s `.task(id: openDiff.id)`), never in
/// `WorkspaceSession` — this is ephemeral view data, not workspace state.
/// Spans are theme-independent (only a `themeKey`, no resolved color), so a
/// theme switch recolors `GitDiffCell` at render time without recomputing
/// this cache.
nonisolated enum DiffSyntaxHighlighter {
    /// Per-side highlighted line spans, index-aligned with the Nth non-nil
    /// `oldLine`/`newLine` in `diff.rows` order — NOT the row index. A row
    /// missing that side (e.g. an addition-only row has no `oldLine`) simply
    /// contributes no entry to that side's array. `DiffLineIndexMap` is the
    /// row → array-index lookup callers use to bridge the two.
    nonisolated struct DiffSideHighlights: Sendable {
        let linesToSpans: [[SyntaxSpan]]

        static let empty = DiffSideHighlights(linesToSpans: [])
    }

    nonisolated struct DiffHighlights: Sendable {
        let old: DiffSideHighlights
        let new: DiffSideHighlights

        static let empty = DiffHighlights(old: .empty, new: .empty)
    }

    /// Upper bound (UTF-16 units) on one side's joined line content eligible
    /// for highlighting. Above this, that side falls back to plain
    /// (unhighlighted) rendering instead of parsing a very large diff off a
    /// scroll-adjacent path.
    private static let maximumHighlightedUTF16Length = 100_000

    /// Resolves a grammar for `diff.path`'s extension and highlights both
    /// sides. Returns `DiffHighlights.empty` (never partial garbage) for a
    /// binary diff, an empty diff, an unrecognized extension, a grammar with
    /// no vendored `highlights.scm`, or a cancelled task — every one of
    /// those cases is `GitDiffCell`'s plain-rendering fallback, unchanged.
    @concurrent
    static func highlights(for diff: GitFileDiff) async -> DiffHighlights {
        guard !diff.isBinary, !diff.hunks.isEmpty,
            let grammarID = GrammarLanguageID.languageID(
                forExtension: (diff.path as NSString).pathExtension.lowercased(),
                fileName: (diff.path as NSString).lastPathComponent)
        else { return .empty }

        guard let configuration = try? await GrammarRegistry.shared.configuration(for: grammarID),
            let query = configuration.queries[.highlights]
        else { return .empty }

        let rows = diff.rows
        let old = sideHighlights(
            lines: rows.compactMap(\.oldLine), language: grammarID.language, query: query)
        if Task.isCancelled { return .empty }
        let new = sideHighlights(
            lines: rows.compactMap(\.newLine), language: grammarID.language, query: query)
        return DiffHighlights(old: old, new: new)
    }

    /// Joins `lines`' contents with `"\n"`, runs one grammar pass over the
    /// joined text, and slices the resulting UTF-16 spans back onto their
    /// originating line (line-relative offsets). A span crossing a `"\n"`
    /// join (e.g. a multi-line string literal) is split across every line it
    /// touches, clipped to `[lineStart, lineStart + lineLength)` on each.
    private static func sideHighlights(
        lines: [GitDiffLine], language: Language, query: Query
    ) -> DiffSideHighlights {
        guard !lines.isEmpty else { return .empty }

        var lineStarts: [Int] = []
        lineStarts.reserveCapacity(lines.count)
        var lineLengths: [Int] = []
        lineLengths.reserveCapacity(lines.count)
        var joined = ""
        var cursor = 0
        for (index, line) in lines.enumerated() {
            lineStarts.append(cursor)
            let length = (line.content as NSString).length
            lineLengths.append(length)
            joined += line.content
            cursor += length
            if index < lines.count - 1 {
                joined += "\n"
                cursor += 1
            }
        }

        guard cursor <= maximumHighlightedUTF16Length,
            let spans = PlainTextSyntaxHighlighter.spans(
                text: joined, language: language, highlightsQuery: query)
        else {
            return DiffSideHighlights(linesToSpans: Array(repeating: [], count: lines.count))
        }

        var perLine: [[SyntaxSpan]] = Array(repeating: [], count: lines.count)
        // Spans are sorted once so `lineIndex` can advance monotonically
        // across the whole pass (O(spans + lines)) instead of rescanning
        // from the first line for every span.
        let sortedSpans = spans.sorted { $0.range.location < $1.range.location }
        var lineIndex = 0
        for span in sortedSpans {
            guard span.range.length > 0 else { continue }
            let spanEnd = span.range.location + span.range.length
            while lineIndex < lines.count,
                lineStarts[lineIndex] + lineLengths[lineIndex] <= span.range.location
            {
                lineIndex += 1
            }
            var probe = lineIndex
            while probe < lines.count, lineStarts[probe] < spanEnd {
                let lineStart = lineStarts[probe]
                let lineEnd = lineStart + lineLengths[probe]
                let clippedStart = max(lineStart, span.range.location)
                let clippedEnd = min(lineEnd, spanEnd)
                if clippedEnd > clippedStart {
                    perLine[probe].append(
                        SyntaxSpan(
                            themeKey: span.themeKey,
                            range: NSRange(
                                location: clippedStart - lineStart,
                                length: clippedEnd - clippedStart)))
                }
                probe += 1
            }
        }
        return DiffSideHighlights(linesToSpans: perLine)
    }
}

/// Row → per-side line-index lookup into `DiffSyntaxHighlighter.DiffHighlights`
/// (the Nth non-nil `oldLine`/`newLine` in `diff.rows` order — see that
/// type's doc). A pure, precomputable helper so `GitSideBySideDiffView` can
/// build it once per opened diff instead of scanning `diff.rows` in `body`
/// on every render.
nonisolated struct DiffLineIndexMap: Sendable {
    private let oldIndexByRowID: [Int: Int]
    private let newIndexByRowID: [Int: Int]

    init(rows: [GitDiffRow]) {
        var oldIndexByRowID: [Int: Int] = [:]
        var newIndexByRowID: [Int: Int] = [:]
        var oldIndex = 0
        var newIndex = 0
        for row in rows {
            if row.oldLine != nil {
                oldIndexByRowID[row.id] = oldIndex
                oldIndex += 1
            }
            if row.newLine != nil {
                newIndexByRowID[row.id] = newIndex
                newIndex += 1
            }
        }
        self.oldIndexByRowID = oldIndexByRowID
        self.newIndexByRowID = newIndexByRowID
    }

    func oldSpans(
        for row: GitDiffRow, in highlights: DiffSyntaxHighlighter.DiffHighlights
    ) -> [SyntaxSpan]? {
        guard let index = oldIndexByRowID[row.id],
            highlights.old.linesToSpans.indices.contains(index)
        else { return nil }
        return highlights.old.linesToSpans[index]
    }

    func newSpans(
        for row: GitDiffRow, in highlights: DiffSyntaxHighlighter.DiffHighlights
    ) -> [SyntaxSpan]? {
        guard let index = newIndexByRowID[row.id],
            highlights.new.linesToSpans.indices.contains(index)
        else { return nil }
        return highlights.new.linesToSpans[index]
    }
}
