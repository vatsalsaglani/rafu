import AppKit
import Testing

@testable import RafuApp

// Regression for the 2026-10-20 main-thread hang: replacing a selection near
// the end of a `.env` file spun forever in `drawIndentGuides` because the
// per-line walk stopped advancing at `content.length`.

@MainActor
private func lines(walking range: NSRange, in text: String) -> [NSRange] {
    var visited: [NSRange] = []
    RafuTextView.forEachBoundedLine(intersecting: range, in: text as NSString) {
        visited.append($0)
    }
    return visited
}

@MainActor
@Test("Line walk stops at the text end when the range runs past it")
func lineWalkStopsAtTextEnd() {
    let text = "A=1\n  B=2\n"
    let length = (text as NSString).length
    let visited = lines(walking: NSRange(location: 0, length: length + 9), in: text)
    #expect(visited == [NSRange(location: 0, length: 4), NSRange(location: 4, length: 6)])
}

@MainActor
@Test("Line walk visits nothing for a range at or past the text end")
func lineWalkIgnoresRangeAtTextEnd() {
    let text = "A=1\nB=2"
    let length = (text as NSString).length
    #expect(lines(walking: NSRange(location: length, length: 5), in: text).isEmpty)
    #expect(lines(walking: NSRange(location: length + 3, length: 5), in: text).isEmpty)
}

@MainActor
@Test("Line walk keeps CRLF on one line and ends without a trailing newline")
func lineWalkHandlesCRLFAndUnterminatedLastLine() {
    let text = "A=1\r\nB=2"
    let visited = lines(walking: NSRange(location: 0, length: 40), in: text)
    #expect(visited == [NSRange(location: 0, length: 5), NSRange(location: 5, length: 3)])
}

@MainActor
@Test("Drawing returns after a selection at the end of an env file is replaced")
func drawReturnsAfterEndOfFileReplacement() {
    let viewportRect = NSRect(x: 0, y: 0, width: 600, height: 800)
    let scrollView = NSScrollView(frame: viewportRect)
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView
    textView.font = RafuThemeCatalog.indigo.resolvedEditorFont()
    textView.indentGuideColor = .gray
    textView.currentLineHighlightColor = .gray
    textView.fileBlameColor = .gray

    var rows = (1...28).map { "  KEY_\($0)=value_\($0)" }
    rows += ["AWS_REGION=us-west-2", "ASSUREBOX_QYRION_PATH=qyrion", ""]
    textView.string = rows.joined(separator: "\n") + "\n"
    let content = textView.string as NSString
    textView.fileBlameAnnotations = [0: "a", content.length: "end"]
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    forceOffscreenDraw(textView, in: viewportRect)

    textView.setSelectedRange(content.range(of: "us-west-2"))
    textView.insertText("x", replacementRange: textView.selectedRange())
    forceOffscreenDraw(textView, in: viewportRect)

    let end = (textView.string as NSString).length
    textView.setSelectedRange(NSRange(location: end - 10, length: 10))
    textView.insertText("", replacementRange: textView.selectedRange())
    forceOffscreenDraw(textView, in: viewportRect)

    #expect(textView.string.contains("AWS_REGION=x\n"))
}

@MainActor
private func forceOffscreenDraw(_ view: NSView, in rect: NSRect) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
        Issue.record("could not allocate offscreen bitmap for \(rect)")
        return
    }
    view.cacheDisplay(in: rect, to: rep)
}
