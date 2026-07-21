import Foundation
import Testing

@testable import RafuApp

/// Data-level proof for `DiffSyntaxHighlighter` (diff-syntax-highlighting-
/// and-hover phase, Part A2): per-side joining, index alignment, span
/// slicing across a `"\n"` join, and the plain-fallback paths. Fixtures are
/// built with `UnifiedDiffParser.parse`, the same production entry point
/// `GitService` uses, so hunk/row shapes match reality rather than a
/// hand-rolled approximation.
@Suite("DiffSyntaxHighlighter")
struct DiffSyntaxHighlighterTests {
    @Test(
        "Side-joining index alignment: deletion-only rows are absent from the new side and addition-only rows from the old side"
    )
    func sideJoiningExcludesUnpairedRows() async throws {
        let patch = [
            "@@ -1,3 +1,2 @@",
            " keep1",
            "-removed",
            " keep2",
            "@@ -10,2 +9,3 @@",
            " keep3",
            "+added",
            " keep4",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(path: "sample.swift", originalPath: nil, patch: patch)
        #expect(diff.rows.count == 6)

        let highlights = await DiffSyntaxHighlighter.highlights(for: diff)
        // 5 rows carry an oldLine (every row except the addition-only
        // "added" row); 5 rows carry a newLine (every row except the
        // deletion-only "removed" row).
        #expect(highlights.old.linesToSpans.count == 5)
        #expect(highlights.new.linesToSpans.count == 5)

        let lineIndexMap = DiffLineIndexMap(rows: diff.rows)
        let addedRow = try #require(diff.rows.first { $0.newLine?.content == "added" })
        let removedRow = try #require(diff.rows.first { $0.oldLine?.content == "removed" })

        #expect(addedRow.oldLine == nil)
        #expect(lineIndexMap.oldSpans(for: addedRow, in: highlights) == nil)
        #expect(removedRow.newLine == nil)
        #expect(lineIndexMap.newSpans(for: removedRow, in: highlights) == nil)

        // Every row that DOES carry a side gets a (possibly empty, never
        // missing) entry on that side.
        for row in diff.rows where row.oldLine != nil {
            #expect(lineIndexMap.oldSpans(for: row, in: highlights) != nil)
        }
        for row in diff.rows where row.newLine != nil {
            #expect(lineIndexMap.newSpans(for: row, in: highlights) != nil)
        }
    }

    @Test("A string literal spanning two visible lines colors both lines' slices")
    func stringLiteralSpanningTwoLinesColorsBoth() async throws {
        let patch = [
            "@@ -1,1 +1,3 @@",
            "-old",
            "+let text = \"\"\"",
            "+hello world",
            "+\"\"\"",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(path: "sample.swift", originalPath: nil, patch: patch)
        let highlights = await DiffSyntaxHighlighter.highlights(for: diff)
        let lineIndexMap = DiffLineIndexMap(rows: diff.rows)

        let bodyRow = try #require(diff.rows.first { $0.newLine?.content == "hello world" })
        let closingRow = try #require(diff.rows.first { $0.newLine?.content == "\"\"\"" })

        let bodySpans = try #require(lineIndexMap.newSpans(for: bodyRow, in: highlights))
        #expect(bodySpans.contains { $0.themeKey == "string" })
        // The capture that begins on the opening-quote line and crosses the
        // `"\n"` join must clip to exactly this line's full UTF-16 length —
        // the off-by-one trap the phase brief calls out.
        let contentLength = (bodyRow.newLine!.content as NSString).length
        #expect(
            bodySpans.contains {
                $0.themeKey == "string" && $0.range == NSRange(location: 0, length: contentLength)
            })

        let closingSpans = try #require(lineIndexMap.newSpans(for: closingRow, in: highlights))
        #expect(closingSpans.contains { $0.themeKey == "string" })
    }

    @Test("Multi-byte content (emoji/CJK) slices to valid, in-bounds ranges")
    func multiByteContentSlicesToValidRanges() async throws {
        let patch = [
            "@@ -1,1 +1,1 @@",
            "-let s = \"old\"",
            "+let s = \"\u{1F600} caf\u{00E9} \u{4F60}\u{597D}\"",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(path: "sample.swift", originalPath: nil, patch: patch)
        let highlights = await DiffSyntaxHighlighter.highlights(for: diff)
        let lineIndexMap = DiffLineIndexMap(rows: diff.rows)

        let row = try #require(diff.rows.first { $0.newLine != nil })
        let content = row.newLine!.content
        let contentLength = (content as NSString).length
        let spans = try #require(lineIndexMap.newSpans(for: row, in: highlights))
        #expect(!spans.isEmpty)
        for span in spans {
            #expect(span.range.location >= 0)
            #expect(span.range.length > 0)
            #expect(span.range.location + span.range.length <= contentLength)
        }
    }

    @Test("A binary diff yields empty results without parsing")
    func binaryDiffYieldsEmptyResults() async throws {
        let diff = GitFileDiff(
            path: "image.png", originalPath: nil, isBinary: true, hunks: [], rawPatch: "")
        let highlights = await DiffSyntaxHighlighter.highlights(for: diff)
        #expect(highlights.old.linesToSpans.isEmpty)
        #expect(highlights.new.linesToSpans.isEmpty)
    }

    @Test("An empty (no-hunk) diff yields empty results without parsing")
    func emptyDiffYieldsEmptyResults() async throws {
        let diff = GitFileDiff(
            path: "empty.swift", originalPath: nil, isBinary: false, hunks: [], rawPatch: "")
        let highlights = await DiffSyntaxHighlighter.highlights(for: diff)
        #expect(highlights.old.linesToSpans.isEmpty)
        #expect(highlights.new.linesToSpans.isEmpty)
    }

    @Test("An unknown file extension falls back to plain (empty) results")
    func unknownExtensionFallsBackToPlain() async throws {
        let patch = [
            "@@ -1,1 +1,1 @@",
            "-old content",
            "+new content",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(
            path: "notes.unknownext", originalPath: nil, patch: patch)
        let highlights = await DiffSyntaxHighlighter.highlights(for: diff)
        #expect(highlights.old.linesToSpans.isEmpty)
        #expect(highlights.new.linesToSpans.isEmpty)
    }
}
