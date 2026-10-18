import Foundation
import Testing

@testable import RafuApp

@Suite("Canvas note Markdown helpers")
struct CanvasNoteMarkdownTests {
    /// Applies a task toggle to `source` the way the TextKit buffer does.
    private func toggled(_ source: String, _ index: Int) -> String? {
        guard let edit = CanvasNoteMarkdown.toggledTask(in: source, at: index) else { return nil }
        return NSString(string: source).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    @Test("Tasks are found in plain, nested, and ordered lists")
    func findsTasks() {
        let source = """
            # Plan
            - [ ] first
            - [x] second
              - [ ] nested
            1. [X] numbered
            * [ ] star
            + [ ] plus
            """
        let found = CanvasNoteMarkdown.tasks(in: source)
        #expect(found.map(\.isChecked) == [false, true, false, true, false, false])
        #expect(found.map(\.index) == [0, 1, 2, 3, 4, 5])
        #expect(found.map(\.line) == [1, 2, 3, 4, 5, 6])
    }

    @Test("Toggling flips only the chosen marker")
    func togglesNthTask() {
        let source = "- [ ] a\n- [x] b\n  - [ ] c\n"
        #expect(toggled(source, 0) == "- [x] a\n- [x] b\n  - [ ] c\n")
        #expect(toggled(source, 1) == "- [ ] a\n- [ ] b\n  - [ ] c\n")
        #expect(toggled(source, 2) == "- [ ] a\n- [x] b\n  - [x] c\n")
        #expect(toggled(source, 3) == nil)
        #expect(toggled(source, -1) == nil)
    }

    @Test("Task-looking lines inside fenced code are ignored")
    func ignoresFencedCode() {
        let source = """
            - [ ] real one
            ```
            - [ ] not a task
            ```
            ~~~md
            - [x] also not
            ~~~
            - [ ] real two
            """
        let found = CanvasNoteMarkdown.tasks(in: source)
        #expect(found.count == 2)
        #expect(toggled(source, 1)?.hasSuffix("- [x] real two") == true)
        #expect(toggled(source, 1)?.contains("- [ ] not a task") == true)
    }

    @Test("A longer fence is not closed by a shorter one")
    func fenceLengths() {
        let source = "````\n```\n- [ ] inside\n```\n````\n- [ ] outside\n"
        let found = CanvasNoteMarkdown.tasks(in: source)
        #expect(found.count == 1)
        #expect(found[0].line == 5)
    }

    @Test("CRLF and CR sources keep exact offsets")
    func lineEndings() {
        let source = "- [ ] a\r\n- [ ] b\r\n- [x] c\r"
        #expect(toggled(source, 1) == "- [ ] a\r\n- [x] b\r\n- [x] c\r")
        #expect(toggled(source, 2) == "- [ ] a\r\n- [ ] b\r\n- [ ] c\r")
    }

    @Test("Offsets are UTF-16 so non-ASCII text before a marker is safe")
    func utf16Offsets() {
        let source = "héllo 😀\n- [ ] task\n"
        #expect(toggled(source, 0) == "héllo 😀\n- [x] task\n")
    }

    @Test("Markers need a list bullet and trailing text")
    func rejectsNonTasks() {
        let source = "[ ] bare\n- [ ]\n- [] none\n- [y] odd\n-[ ] glued\n- [ ]x glued\n"
        #expect(CanvasNoteMarkdown.tasks(in: source).isEmpty)
    }

    @Test("Quoted task items count")
    func quotedTasks() {
        let source = "> - [ ] quoted\n"
        #expect(toggled(source, 0) == "> - [x] quoted\n")
    }

    @Test("Progress counts done and total")
    func progress() {
        let progress = CanvasNoteMarkdown.taskProgress(in: "- [x] a\n- [ ] b\n- [X] c\n")
        #expect(progress.done == 2)
        #expect(progress.total == 3)
    }

    @Test("Lines map to offsets and back")
    func lineMapping() {
        let source = "one\ntwo\r\nthree\n"
        #expect(CanvasNoteMarkdown.offset(ofLine: 0, in: source) == 0)
        #expect(CanvasNoteMarkdown.offset(ofLine: 1, in: source) == 4)
        #expect(CanvasNoteMarkdown.offset(ofLine: 2, in: source) == 9)
        #expect(CanvasNoteMarkdown.offset(ofLine: 9, in: source) == source.utf16.count)
        #expect(CanvasNoteMarkdown.line(containing: 5, in: source) == 1)
        #expect(CanvasNoteMarkdown.line(containing: 9, in: source) == 2)
        #expect(CanvasNoteMarkdown.line(containing: source.utf16.count, in: source) == 3)
        #expect(CanvasNoteMarkdown.line(containing: 0, in: "") == 0)
    }

    // MARK: Blocks

    @Test("Top-level blocks split on kind and blank lines")
    func blockKinds() {
        let source = """
            # Title

            First line
            second line

            - a
            - b

            > quote
            > more

            ```swift
            let x = 1
            ```

            ---

            | a | b |
            | - | - |
            | 1 | 2 |
            """
        let blocks = CanvasNoteMarkdown.blocks(in: source)
        #expect(
            blocks.map(\.kind) == [
                .heading(level: 1), .paragraph, .list, .quote, .code(language: "swift"), .rule,
                .table,
            ])
        #expect(blocks.map(\.startLine) == [0, 2, 5, 8, 11, 15, 17])
        #expect(blocks[1].text == "First line\nsecond line")
        #expect(blocks[2].text == "- a\n- b")
        #expect(blocks[4].endLine == 14)
    }

    @Test("Lists keep nested items, loose items, and fenced code in one block")
    func listBlocks() {
        let source = """
            - one
              - nested

            - two (loose)

              continued paragraph
            - three
              ```
              - [ ] code in item

              still code
              ```
            after
            """
        let blocks = CanvasNoteMarkdown.blocks(in: source)
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .list)
        #expect(blocks[0].taskCount == 0)
    }

    @Test("A paragraph underlined by a dash line is a setext heading, not a rule")
    func setextHeading() {
        let blocks = CanvasNoteMarkdown.blocks(in: "Title\n-----\n\nBody\n")
        #expect(blocks.map(\.kind) == [.heading(level: 2), .paragraph])
    }

    @Test("A list item interrupts a paragraph")
    func listInterruptsParagraph() {
        let blocks = CanvasNoteMarkdown.blocks(in: "Intro\n- a\n- b\n")
        #expect(blocks.map(\.kind) == [.paragraph, .list])
        #expect(blocks[1].startLine == 1)
    }

    @Test("Blocks know which tasks they contain")
    func blockTasks() {
        let source = "- [ ] a\n- [x] b\n\nText\n\n- [ ] c\n"
        let blocks = CanvasNoteMarkdown.blocks(in: source)
        #expect(blocks.count == 3)
        #expect(blocks[0].firstTaskIndex == 0)
        #expect(blocks[0].taskCount == 2)
        #expect(blocks[1].taskCount == 0)
        #expect(blocks[2].firstTaskIndex == 2)
        #expect(blocks[2].taskCount == 1)
    }

    @Test("Block ranges address the original source")
    func blockRanges() {
        let source = "# é\r\n\r\ntext 😀\r\nmore\r\n"
        let blocks = CanvasNoteMarkdown.blocks(in: source)
        #expect(blocks.count == 2)
        for block in blocks {
            #expect(NSString(string: source).substring(with: block.range) == block.text)
        }
    }

    @Test("An unterminated fence runs to the end of the note")
    func unterminatedFence() {
        let blocks = CanvasNoteMarkdown.blocks(in: "```py\nprint(1)\n\nprint(2)\n")
        #expect(blocks.count == 1)
        #expect(blocks[0].kind == .code(language: "py"))
        #expect(blocks[0].endLine == 4)
    }

    @Test("Collapsing keeps the opener, three lines, an ellipsis, and the closer")
    func collapsedCode() throws {
        let source = "```swift\na\nb\nc\nd\ne\n```\n"
        let block = try #require(CanvasNoteMarkdown.blocks(in: source).first)
        #expect(
            CanvasNoteMarkdown.text(of: block, collapsingCodeTo: 3)
                == "```swift\na\nb\nc\n…\n```")
        let short = try #require(CanvasNoteMarkdown.blocks(in: "```\na\nb\n```").first)
        #expect(CanvasNoteMarkdown.text(of: short, collapsingCodeTo: 3) == short.text)
        let open = try #require(CanvasNoteMarkdown.blocks(in: "```\na\nb\nc\nd\n").first)
        #expect(CanvasNoteMarkdown.text(of: open, collapsingCodeTo: 3) == "```\na\nb\nc\n…")
        let paragraph = try #require(CanvasNoteMarkdown.blocks(in: "text").first)
        #expect(CanvasNoteMarkdown.text(of: paragraph, collapsingCodeTo: 3) == "text")
    }

    // MARK: Summary

    @Test("Summary takes the first heading, first paragraph, and task count")
    func summary() {
        let source = """
            Some intro that comes first.

            ## **Release** plan ##

            Ship the [notes](https://example.com) feature.

            - [x] draft
            - [ ] review
            - [ ] publish
            """
        let summary = CanvasNoteMarkdown.summary(of: source)
        #expect(summary.title == "Release plan")
        #expect(summary.excerpt == "Some intro that comes first.")
        #expect(summary.tasksDone == 1)
        #expect(summary.tasksTotal == 3)
    }

    @Test("Summary falls back to a list item when there is no paragraph")
    func summaryFallback() {
        let summary = CanvasNoteMarkdown.summary(of: "# Todo\n\n- [ ] buy `milk`\n- [x] eggs\n")
        #expect(summary.title == "Todo")
        #expect(summary.excerpt == "buy milk")
        #expect(summary.tasksTotal == 2)
        let empty = CanvasNoteMarkdown.summary(of: "")
        #expect(empty.title == nil)
        #expect(empty.excerpt == nil)
        #expect(empty.tasksTotal == 0)
    }

    @Test("Headings inside code are not titles")
    func summaryIgnoresCode() {
        let summary = CanvasNoteMarkdown.summary(of: "```\n# comment\n```\n\nBody text\n")
        #expect(summary.title == nil)
        #expect(summary.excerpt == "Body text")
    }

    @Test("Plain text drops markers and keeps link labels")
    func plainText() {
        #expect(CanvasNoteMarkdown.plainText("**bold** and `code` and *em*") == "bold and code and em")
        #expect(CanvasNoteMarkdown.plainText("see [docs](a/b.md) ![alt](x.png)") == "see docs alt")
        #expect(CanvasNoteMarkdown.plainText("snake_case stays") == "snake_case stays")
    }
}
