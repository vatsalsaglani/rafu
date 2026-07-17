import Foundation
import Testing

@testable import RafuApp

@Suite("Git hunk patch builder")
struct GitHunkPatchBuilderTests {
    @Test("Single hunk preserves the raw patch verbatim")
    func singleHunk() throws {
        let rawPatch = [
            "diff --git a/file.txt b/file.txt",
            "index 1111111..2222222 100644",
            "--- a/file.txt",
            "+++ b/file.txt",
            "@@ -1 +1 @@",
            "-old",
            "+new",
            "",
        ].joined(separator: "\n")
        let diff = UnifiedDiffParser.parse(path: "file.txt", originalPath: nil, patch: rawPatch)
        let hunk = try #require(diff.hunks.first)

        #expect(try GitHunkPatchBuilder.patch(for: hunk, in: diff) == rawPatch)
    }

    @Test("Middle hunk keeps the prologue and only its exact raw block")
    func middleOfThree() throws {
        let prologue = [
            "diff --git a/file.txt b/file.txt",
            "index 1111111..2222222 100644",
            "--- a/file.txt",
            "+++ b/file.txt",
            "",
        ].joined(separator: "\n")
        let first = "@@ -1 +1 @@\n-one\n+ONE\n"
        let middle = "@@ -10 +10 @@\n-ten\n+TEN\n"
        let last = "@@ -20 +20 @@\n-twenty\n+TWENTY\n"
        let rawPatch = prologue + first + middle + last
        let diff = UnifiedDiffParser.parse(path: "file.txt", originalPath: nil, patch: rawPatch)
        let hunk = try #require(diff.hunks[safe: 1])

        #expect(try GitHunkPatchBuilder.patch(for: hunk, in: diff) == prologue + middle)
    }

    @Test("No-newline marker is retained instead of reconstructed from rows")
    func noTrailingNewlineMarker() throws {
        let prologue = [
            "diff --git a/file.txt b/file.txt",
            "index 1111111..2222222 100644",
            "--- a/file.txt",
            "+++ b/file.txt",
            "",
        ].joined(separator: "\n")
        let first =
            "@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"
        let second = "@@ -5 +5 @@\n-five\n+FIVE\n"
        let rawPatch = prologue + first + second
        let diff = UnifiedDiffParser.parse(path: "file.txt", originalPath: nil, patch: rawPatch)
        let hunk = try #require(diff.hunks.first)

        let selected = try GitHunkPatchBuilder.patch(for: hunk, in: diff)
        #expect(selected == prologue + first)
        #expect(selected.contains("\\ No newline at end of file"))
    }
}

extension Collection {
    fileprivate subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
