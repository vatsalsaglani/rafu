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
