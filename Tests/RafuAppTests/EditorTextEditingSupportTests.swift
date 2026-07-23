import AppKit
import Foundation
import Testing

@testable import RafuApp

// MARK: - LineCommenter

@Test("Line-comment prefixes map per language and unknown types opt out")
func lineCommentPrefixes() {
    #expect(LineCommenter.prefix(forExtension: "swift") == "//")
    #expect(LineCommenter.prefix(forExtension: "py") == "#")
    #expect(LineCommenter.prefix(forExtension: "sql") == "--")
    #expect(LineCommenter.prefix(forExtension: "", fileName: "Dockerfile") == "#")
    #expect(LineCommenter.prefix(forExtension: "", fileName: "Makefile") == "#")
    #expect(LineCommenter.prefix(forExtension: "html") == nil)
    #expect(LineCommenter.prefix(forExtension: "css") == nil)
    #expect(LineCommenter.prefix(forExtension: "md") == nil)
}

@Test("Toggling comments inserts the prefix at the minimum common indent")
func commentInsertionUsesMinimumIndent() {
    let lines = "    let a = 1\n        let b = 2\n"
    let result = LineCommenter.toggle(lines: lines, prefix: "//")
    #expect(result.didComment)
    #expect(result.replacement == "    // let a = 1\n    //     let b = 2\n")
}

@Test("Toggling fully commented lines removes prefix and one space")
func commentRemoval() {
    let lines = "    // let a = 1\n    //let b = 2\n"
    let result = LineCommenter.toggle(lines: lines, prefix: "//")
    #expect(!result.didComment)
    #expect(result.replacement == "    let a = 1\n    let b = 2\n")
}

@Test("Mixed commented and uncommented lines comment everything")
func mixedLinesComment() {
    let lines = "// done\ntodo\n"
    let result = LineCommenter.toggle(lines: lines, prefix: "//")
    #expect(result.didComment)
    #expect(result.replacement == "// // done\n// todo\n")
}

@Test("Blank lines are skipped when commenting a selection")
func blankLinesAreSkipped() {
    let lines = "a\n\nb\n"
    let result = LineCommenter.toggle(lines: lines, prefix: "#")
    #expect(result.replacement == "# a\n\n# b\n")
}

@Test("An all-blank selection is commented at column zero")
func allBlankSelectionComments() {
    let result = LineCommenter.toggle(lines: "\n", prefix: "//")
    #expect(result.didComment)
    #expect(result.replacement == "// \n")
}

@Test("A final line without trailing newline keeps its shape")
func noTrailingNewline() {
    let result = LineCommenter.toggle(lines: "last line", prefix: "--")
    #expect(result.replacement == "-- last line")
    let back = LineCommenter.toggle(lines: result.replacement, prefix: "--")
    #expect(back.replacement == "last line")
}

// MARK: - BracketWrap

@Test("Wrapping a selection produces the paired text with the original inside")
func bracketWrapWrapsSelectionAndKeepsInnerRange() {
    let result = BracketWrap.wrapping(selection: "hello", opening: "(")
    #expect(result?.text == "(hello)")
    #expect(result?.innerRange == NSRange(location: 1, length: 5))
}

@Test("Every configured opener maps to its closer")
func bracketWrapCoversAllConfiguredPairs() {
    #expect(BracketWrap.wrapping(selection: "x", opening: "[")?.text == "[x]")
    #expect(BracketWrap.wrapping(selection: "x", opening: "{")?.text == "{x}")
    #expect(BracketWrap.wrapping(selection: "x", opening: "<")?.text == "<x>")
    #expect(BracketWrap.wrapping(selection: "x", opening: "\"")?.text == "\"x\"")
    #expect(BracketWrap.wrapping(selection: "x", opening: "'")?.text == "'x'")
    #expect(BracketWrap.wrapping(selection: "x", opening: "`")?.text == "`x`")
}

@Test("An empty selection still wraps to an empty pair")
func bracketWrapEmptySelection() {
    let result = BracketWrap.wrapping(selection: "", opening: "(")
    #expect(result?.text == "()")
    #expect(result?.innerRange == NSRange(location: 1, length: 0))
}

@Test("A character with no configured pair returns nil")
func bracketWrapUnknownOpener() {
    #expect(BracketWrap.wrapping(selection: "x", opening: "a") == nil)
}

// MARK: - CommentSyntaxTable / BlockCommenter

@Test("Comment syntax pairs a line token with a block form where both exist")
func commentSyntaxLineAndBlockLanguages() {
    let swift = CommentSyntaxTable.syntax(forExtension: "swift")
    #expect(swift.line == "//")
    #expect(swift.block == BlockCommentDelimiters(open: "/*", close: "*/"))

    let css = CommentSyntaxTable.syntax(forExtension: "css")
    #expect(css.line == nil)
    #expect(css.block == BlockCommentDelimiters(open: "/*", close: "*/"))

    let html = CommentSyntaxTable.syntax(forExtension: "html")
    #expect(html.line == nil)
    #expect(html.block == BlockCommentDelimiters(open: "<!--", close: "-->"))

    let json = CommentSyntaxTable.syntax(forExtension: "json")
    #expect(json.line == nil)
    #expect(json.block == nil)
}

@Test("Block-comment toggling wraps a selection with padding")
func blockCommentWrapsSelection() {
    let result = BlockCommenter.toggle(selection: "color: red;", open: "/*", close: "*/")
    #expect(result.didComment)
    #expect(result.replacement == "/* color: red; */")
}

@Test("Block-comment toggling unwraps an already-commented selection")
func blockCommentUnwrapsSelection() {
    let result = BlockCommenter.toggle(selection: "/* color: red; */", open: "/*", close: "*/")
    #expect(!result.didComment)
    #expect(result.replacement == "color: red;")
}

@Test("Block-comment unwrapping tolerates missing padding spaces")
func blockCommentUnwrapsWithoutPadding() {
    let result = BlockCommenter.toggle(selection: "<!--note-->", open: "<!--", close: "-->")
    #expect(!result.didComment)
    #expect(result.replacement == "note")
}

// MARK: - AutoIndenter

@Test("Newline copies the current line's leading whitespace")
func newlineCopiesIndent() {
    let text = "    let a = 1"
    let insertion = AutoIndenter.newlineInsertion(
        forCaretAt: (text as NSString).length, in: text, fileExtension: "swift")
    #expect(insertion == "\n    ")
}

@Test("Newline after an opening brace adds one indent level")
func newlineAfterBraceIndents() {
    let text = "    func run() {"
    let insertion = AutoIndenter.newlineInsertion(
        forCaretAt: (text as NSString).length, in: text, fileExtension: "swift")
    #expect(insertion == "\n        ")
}

@Test("Python colon suffix adds one indent level; other languages ignore it")
func pythonColonIndents() {
    let text = "def run():"
    let python = AutoIndenter.newlineInsertion(
        forCaretAt: (text as NSString).length, in: text, fileExtension: "py")
    #expect(python == "\n    ")
    let swift = AutoIndenter.newlineInsertion(
        forCaretAt: (text as NSString).length, in: text, fileExtension: "swift")
    #expect(swift == "\n")
}

@Test("Tab-indented lines extend with a tab")
func tabIndentExtendsWithTab() {
    let text = "\tif ok {"
    let insertion = AutoIndenter.newlineInsertion(
        forCaretAt: (text as NSString).length, in: text, fileExtension: "swift")
    #expect(insertion == "\n\t\t")
}

@Test(
    """
    Newline insertion on an empty line is always plain "\\n", even right \
    after a brace — this is what keeps `CodeEditorView.Coordinator`'s \
    auto-indent `shouldChangeTextIn` delegate from rewriting \
    `LineManipulation.duplicateAbove(text:selection:)`'s insertion when the \
    duplicated line is blank (that insertion is also exactly "\\n" and lands \
    at the caret's exact current selection, so it takes the same code path \
    a plain Return keypress would)
    """
)
func newlineInsertionOnEmptyLineIsAlwaysPlain() {
    // Caret on the empty line between "{" and "}".
    let text = "if x {\n\n}"
    let emptyLineStart = 7
    #expect(
        AutoIndenter.newlineInsertion(
            forCaretAt: emptyLineStart, in: text, fileExtension: "swift") == "\n")
    // Same for Python's ":" trigger.
    let pythonText = "def run():\n\n    pass"
    #expect(
        AutoIndenter.newlineInsertion(forCaretAt: 11, in: pythonText, fileExtension: "py") == "\n"
    )
}

@Test("Newline at file start and mid-line uses only the text before the caret")
func newlineUsesTextBeforeCaret() {
    #expect(AutoIndenter.newlineInsertion(forCaretAt: 0, in: "", fileExtension: "swift") == "\n")
    // Caret between "{" and "}" on "  a {}": text before caret ends in "{".
    let text = "  a {}"
    let insertion = AutoIndenter.newlineInsertion(forCaretAt: 5, in: text, fileExtension: "swift")
    #expect(insertion == "\n      ")
}

// MARK: - BracketMatcher

@Test("Nested brackets match from either side of the caret")
func nestedBracketMatch() {
    let text = "f(a[0], (b))"
    // Caret after the opening parenthesis at offset 1.
    let fromOpen = BracketMatcher.matchedRanges(in: text, caretLocation: 2)
    #expect(
        fromOpen == [NSRange(location: 1, length: 1), NSRange(location: 11, length: 1)])
    // Caret after the final closing parenthesis.
    let fromClose = BracketMatcher.matchedRanges(in: text, caretLocation: 12)
    #expect(
        fromClose == [NSRange(location: 1, length: 1), NSRange(location: 11, length: 1)])
    // Caret inside the square brackets.
    let brackets = BracketMatcher.matchedRanges(in: text, caretLocation: 4)
    #expect(
        brackets == [NSRange(location: 3, length: 1), NSRange(location: 5, length: 1)])
}

@Test("Unmatched brackets and bracket-free positions return nil")
func unmatchedBrackets() {
    #expect(BracketMatcher.matchedRanges(in: "(a", caretLocation: 1) == nil)
    #expect(BracketMatcher.matchedRanges(in: "plain text", caretLocation: 3) == nil)
    #expect(BracketMatcher.matchedRanges(in: "", caretLocation: 0) == nil)
}

@Test("Bracket scanning stops at the bound instead of walking huge buffers")
func bracketScanIsBounded() {
    let text = "(" + String(repeating: "x", count: BracketMatcher.scanLimit + 10) + ")"
    #expect(BracketMatcher.matchedRanges(in: text, caretLocation: 1) == nil)
}

// MARK: - LineManipulation

@Test("Moving a middle line up swaps it with the preceding line")
func moveUpSwapsMiddleLine() {
    let text = "a\nb\nc\nd\n"
    // Caret at the start of "c".
    let edit = LineManipulation.moveUp(text: text, selection: NSRange(location: 4, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nc\nb\nd\n")
    #expect(edit.newSelection == NSRange(location: 2, length: 0))
}

@Test("Moving a middle line down swaps it with the following line")
func moveDownSwapsMiddleLine() {
    let text = "a\nb\nc\nd\n"
    // Caret at the start of "b".
    let edit = LineManipulation.moveDown(text: text, selection: NSRange(location: 2, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nc\nb\nd\n")
    #expect(edit.newSelection == NSRange(location: 4, length: 0))
}

@Test("Moving a multi-line selection block up carries the whole block")
func moveUpMovesMultiLineBlock() {
    let text = "a\nb\nc\nd\n"
    // Selection covering "b\nc" (lines 2-3).
    let edit = LineManipulation.moveUp(text: text, selection: NSRange(location: 2, length: 3))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "b\nc\na\nd\n")
}

@Test("Moving the first line up is a no-op")
func moveUpAtFirstLineIsNoOp() {
    let text = "a\nb\nc\n"
    #expect(LineManipulation.moveUp(text: text, selection: NSRange(location: 0, length: 0)) == nil)
}

@Test("Moving the last line down is a no-op")
func moveDownAtLastLineIsNoOp() {
    let text = "a\nb\nc\n"
    // Caret on the trailing empty line after the final newline.
    let length = (text as NSString).length
    #expect(
        LineManipulation.moveDown(text: text, selection: NSRange(location: length, length: 0))
            == nil)
}

@Test("Moving the last line without a trailing newline up preserves EOF shape")
func moveUpLastLineWithoutTrailingNewline() {
    let text = "line1\nline2\nline3"
    let ns = text as NSString
    let selection = NSRange(location: ns.length, length: 0)
    let edit = LineManipulation.moveUp(text: text, selection: selection)
    #expect(edit != nil)
    guard let edit else { return }
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "line1\nline3\nline2")
    #expect(!result.hasSuffix("\n"))
}

@Test("Moving a line down into the last, trailing-newline-free position preserves EOF shape")
func moveDownIntoLastLineWithoutTrailingNewline() {
    let text = "a\nb\nc"
    // Caret at the start of "b".
    let edit = LineManipulation.moveDown(text: text, selection: NSRange(location: 2, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nc\nb")
    #expect(!result.hasSuffix("\n"))
}

@Test("Duplicate above inserts an identical copy before the block")
func duplicateAboveInMiddle() {
    let text = "a\nb\nc\n"
    let edit = LineManipulation.duplicateAbove(
        text: text, selection: NSRange(location: 2, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nb\nb\nc\n")
}

@Test("Duplicate above at end of file with no trailing newline adds one between copies")
func duplicateAboveAtEOFWithoutTrailingNewline() {
    let text = "abc"
    let ns = text as NSString
    let edit = LineManipulation.duplicateAbove(
        text: text, selection: NSRange(location: ns.length, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "abc\nabc")
}

@Test("Duplicate below inserts an identical copy after the block and moves selection into it")
func duplicateBelowInMiddle() {
    let text = "a\nb\nc\n"
    let edit = LineManipulation.duplicateBelow(
        text: text, selection: NSRange(location: 2, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nb\nb\nc\n")
    #expect(edit.newSelection == NSRange(location: 4, length: 0))
}

@Test("Duplicate below at end of file with no trailing newline inserts a separating newline")
func duplicateBelowAtEOFWithoutTrailingNewline() {
    let text = "abc"
    let edit = LineManipulation.duplicateBelow(
        text: text, selection: NSRange(location: 1, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "abc\nabc")
    #expect(edit.newSelection == NSRange(location: 5, length: 0))
}

@Test("Deleting a middle line removes it and preserves the caret column")
func deleteMiddleLine() {
    let text = "a\nbb\nc\n"
    // Caret at column 1 on "bb".
    let edit = LineManipulation.deleteLines(text: text, selection: NSRange(location: 3, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nc\n")
    // "c" (1 character) is shorter than the deleted line's column (1, from
    // "bb"), so the caret clamps to just past "c" rather than overshooting.
    #expect(edit.newSelection == NSRange(location: 3, length: 0))
}

@Test("Deleting the last line without a trailing newline leaves no blank tail")
func deleteLastLineWithoutTrailingNewline() {
    let text = "a\nb\nc"
    let ns = text as NSString
    let edit = LineManipulation.deleteLines(
        text: text, selection: NSRange(location: ns.length, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result == "a\nb")
    #expect(!result.hasSuffix("\n"))
    #expect(edit.newSelection == NSRange(location: 3, length: 0))
}

@Test("Deleting the only line clears the document")
func deleteOnlyLine() {
    let text = "solo"
    let edit = LineManipulation.deleteLines(text: text, selection: NSRange(location: 2, length: 0))
    #expect(edit != nil)
    guard let edit else { return }
    let ns = text as NSString
    let result = ns.replacingCharacters(in: edit.replacementRange, with: edit.replacementText)
    #expect(result.isEmpty)
    #expect(edit.newSelection == NSRange(location: 0, length: 0))
}

@Test("Every LineManipulation transform no-ops on an empty document")
func lineManipulationGuardsEmptyDocument() {
    let empty = ""
    let selection = NSRange(location: 0, length: 0)
    #expect(LineManipulation.moveUp(text: empty, selection: selection) == nil)
    #expect(LineManipulation.moveDown(text: empty, selection: selection) == nil)
    #expect(LineManipulation.duplicateAbove(text: empty, selection: selection) == nil)
    #expect(LineManipulation.duplicateBelow(text: empty, selection: selection) == nil)
    #expect(LineManipulation.deleteLines(text: empty, selection: selection) == nil)
}

@Test("CRLF line endings round-trip without corruption across move/duplicate/delete")
func lineManipulationHandlesCRLF() {
    let text = "a\r\nb\r\nc\r\n"
    let ns = text as NSString

    // Caret on "b" (line 2); moving up swaps it with "a".
    let moved = LineManipulation.moveUp(text: text, selection: NSRange(location: 3, length: 0))
    #expect(moved != nil)
    if let moved {
        let result = ns.replacingCharacters(in: moved.replacementRange, with: moved.replacementText)
        #expect(result == "b\r\na\r\nc\r\n")
    }

    let duplicated = LineManipulation.duplicateBelow(
        text: text, selection: NSRange(location: 0, length: 0))
    #expect(duplicated != nil)
    if let duplicated {
        let result = ns.replacingCharacters(
            in: duplicated.replacementRange, with: duplicated.replacementText)
        #expect(result == "a\r\na\r\nb\r\nc\r\n")
    }

    let deleted = LineManipulation.deleteLines(
        text: text, selection: NSRange(location: 3, length: 0))
    #expect(deleted != nil)
    if let deleted {
        let result = ns.replacingCharacters(
            in: deleted.replacementRange, with: deleted.replacementText)
        #expect(result == "a\r\nc\r\n")
    }
}

// MARK: - Editor decoration views

@MainActor
@Test("Gutter ruler and decorated text view draw offscreen without errors")
func editorDecorationsDrawOffscreen() {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    let textView = RafuTextView.makeTextKit1()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
    scrollView.documentView = textView
    textView.string = "func a() {\n    let x = (1)\n}\n"

    let theme = RafuThemeCatalog.indigo
    let gutter = EditorGutterRulerView(
        scrollView: scrollView,
        textView: textView,
        style: EditorGutterStyle(theme: theme)
    )
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true

    textView.currentLineHighlightColor = theme.editorLineHighlightColor
    textView.indentGuideColor = theme.editorIndentGuideColor
    textView.bracketBorderColor = theme.editorMatchingBracketBorderColor
    textView.setSelectedRange(NSRange(location: 10, length: 0))
    textView.matchedBracketRanges =
        BracketMatcher.matchedRanges(in: textView.string, caretLocation: 10) ?? []
    #expect(textView.matchedBracketRanges.count == 2)

    gutter.gitMarkers = GitGutterLineChanges(
        added: [1...1], modified: [2...2], deletedAfter: [2])
    gutter.invalidateLineIndex()

    // Renders both views (gutter draw rebuilds the line index and thickness).
    #expect(!scrollView.dataWithPDF(inside: scrollView.bounds).isEmpty)
    #expect(gutter.ruleThickness > 10)
}
