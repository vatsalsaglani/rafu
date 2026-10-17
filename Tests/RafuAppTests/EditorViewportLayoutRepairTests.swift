import AppKit
import Testing

@testable import RafuApp

/// Exercises the real TextKit stack. Request counts are deterministic; no
/// timing threshold or source-string assertion stands in for drawing work.
@MainActor
@Suite("Editor viewport layout repair")
struct EditorViewportLayoutRepairTests {
    @MainActor
    private struct Fixture {
        let scrollView: NSScrollView
        let textView: RafuTextView

        init(_ text: String, width: CGFloat = 320, height: CGFloat = 90) {
            scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
            textView = RafuTextView.makeTextKit1()
            textView.frame = NSRect(x: 0, y: 0, width: width, height: 20_000)
            textView.autoresizingMask = [.width]
            textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            textView.textContainerInset = NSSize(width: 8, height: 6)
            scrollView.documentView = textView
            textView.string = text
        }

        func resizeViewport(width: CGFloat) {
            // Resize the viewport owner, as an editor host does. AppKit can
            // enforce the clip width on a non-horizontally-resizable text view.
            scrollView.setFrameSize(NSSize(width: width, height: scrollView.frame.height))
            scrollView.tile()
            textView.setFrameSize(
                NSSize(width: scrollView.contentSize.width, height: textView.frame.height))
        }

        func viewport() throws -> EditorViewportLayout {
            try #require(
                EditorViewportLayout(
                    textView: textView, rect: textView.visibleRect,
                    metrics: textView.viewportLayoutMetrics))
        }

        func drawBackground() throws {
            // Call the real override inside a bitmap context. Unlike display(),
            // this runs headlessly and excludes unrelated AppKit glyph drawing.
            let bitmap = try #require(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 120,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                    bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = context
            textView.drawBackground(in: textView.visibleRect)
        }
    }

    @Test("Offscreen positions are rejected before character geometry lookup")
    func offscreenPositionsDoNotRequestGeometry() throws {
        let fixture = Fixture(String(repeating: "let x = 1\n", count: 2_000))
        let viewport = try fixture.viewport()
        let metrics = fixture.textView.viewportLayoutMetrics
        metrics.reset()
        let end = (fixture.textView.string as NSString).length
        #expect(!viewport.containsInsertion(at: end - 2))
        #expect(viewport.caretRect(at: end - 2) == nil)
        #expect(viewport.boundingRect(for: NSRange(location: end - 2, length: 1)) == nil)
        #expect(metrics.characterGeometryRequests == 0)
        #expect(metrics.rejectedGeometryRequests == 2)
    }

    @Test("One overlay refresh requests one viewport for all extra carets")
    func multiCaretPassSharesViewport() throws {
        let fixture = Fixture(String(repeating: "let x = 1\n", count: 2_000))
        let view = fixture.textView
        let end = (view.string as NSString).length
        view.applyCaretRanges([
            NSRange(location: 0, length: 0), NSRange(location: 2, length: 0),
            NSRange(location: 12, length: 0), NSRange(location: end - 2, length: 0),
        ])
        let metrics = view.viewportLayoutMetrics
        metrics.reset()
        view.refreshMultiCaretOverlay()
        let overlay = try #require(view.subviews.compactMap { $0 as? MultiCaretOverlayView }.first)
        #expect(overlay.caretRects.count == 2)
        #expect(overlay.caretRects.allSatisfy { $0.intersects(view.visibleRect) })
        #expect(metrics.viewportRequests == 1)
        #expect(metrics.characterGeometryRequests == 2)
        #expect(metrics.rejectedGeometryRequests == 1)
    }

    @Test("Offscreen current line, brackets, and blame cause no character geometry")
    func offscreenDecorationsDoNotRequestGeometry() throws {
        let fixture = Fixture(String(repeating: "let x = 1\n", count: 2_000))
        let view = fixture.textView
        let end = (view.string as NSString).length
        view.setSelectedRange(NSRange(location: end - 2, length: 0))
        view.currentLineHighlightColor = .gray
        view.bracketBorderColor = .gray
        view.matchedBracketRanges = [NSRange(location: end - 2, length: 1)]
        view.inlineBlameColor = .gray
        view.inlineBlameAnnotation = InlineBlameAnnotation(lineNumber: 2_000, text: "Author")
        view.viewportLayoutMetrics.reset()
        try fixture.drawBackground()
        #expect(view.viewportLayoutMetrics.viewportRequests == 1)
        #expect(view.viewportLayoutMetrics.characterGeometryRequests == 0)
        #expect(view.inlineBlameRect == .zero)
    }

    @Test("Empty and trailing lines have visible insertion geometry")
    func emptyAndTrailingLines() throws {
        for text in ["", "x\n", "x\r\n", "\n\n", "😀\n"] {
            let fixture = Fixture(text)
            let viewport = try fixture.viewport()
            let end = (text as NSString).length
            let caret = try #require(viewport.caretRect(at: end))
            #expect(caret.height > 0)
            #expect(caret.width == 1)
            #expect(caret.intersects(fixture.textView.visibleRect))
            if end > 0 {
                let first = try #require(viewport.caretRect(at: 0))
                #expect(caret.minY > first.minY)
            }
        }
    }

    @Test("UTF-16 offsets map supplementary and combined characters to visible glyphs")
    func utf16Geometry() throws {
        let text = "😀 e\u{301} 🧑‍💻 (x)\n"
        let fixture = Fixture(text)
        let viewport = try fixture.viewport()
        let content = text as NSString
        let bracket = content.range(of: "(")
        let rect = try #require(viewport.boundingRect(for: bracket))
        #expect(rect.height > 0)
        #expect(rect.intersects(fixture.textView.visibleRect))
        #expect(viewport.caretRect(at: bracket.location) != nil)
        // Either UTF-16 unit of the first supplementary character maps safely.
        #expect(viewport.boundingRect(for: NSRange(location: 0, length: 1)) != nil)
        #expect(viewport.boundingRect(for: NSRange(location: 1, length: 1)) != nil)
    }

    @Test("Malformed and stale ranges are rejected without overflow")
    func invalidRanges() throws {
        let fixture = Fixture("abc")
        let viewport = try fixture.viewport()
        fixture.textView.viewportLayoutMetrics.reset()
        for range in [
            NSRange(location: NSNotFound, length: 1),
            NSRange(location: 2, length: Int.max),
            NSRange(location: 4, length: 0),
            NSRange(location: 0, length: 0),
        ] {
            #expect(viewport.boundingRect(for: range) == nil)
            if range.length > 0 { #expect(viewport.lineEndRect(for: range) == nil) }
        }
        #expect(fixture.textView.viewportLayoutMetrics.characterGeometryRequests == 0)
    }

    @Test("A wrapped line only requests visible characters and hides its offscreen end")
    func wrappedLineIsClippedBeforeGeometry() throws {
        let fixture = Fixture(String(repeating: "word ", count: 600), width: 180, height: 60)
        let viewport = try fixture.viewport()
        let wholeLine = NSRange(location: 0, length: (fixture.textView.string as NSString).length)
        #expect(viewport.characterRange.length < wholeLine.length)
        #expect(viewport.boundingRect(for: wholeLine) != nil)
        #expect(
            fixture.textView.viewportLayoutMetrics.lastCharacterRange == viewport.characterRange)
        #expect(viewport.lineEndRect(for: wholeLine) == nil)
    }

    @Test("Blame uses the last wrapped fragment instead of the multi-line union")
    func wrappedBlameUsesFinalFragment() throws {
        let text = String(repeating: "word ", count: 12) + "\n"
        let fixture = Fixture(text, width: 180, height: 240)
        let viewport = try fixture.viewport()
        let range = NSRange(location: 0, length: (text as NSString).length)
        let union = try #require(viewport.boundingRect(for: range))
        let end = try #require(viewport.lineEndRect(for: range))
        #expect(end.minY > union.minY)
        #expect(end.height < union.height)
    }

    @Test("New passes use current text, font, container size, and scroll position")
    func geometryIsNotRetainedAcrossInvalidation() throws {
        let fixture = Fixture("abc\ndef\n" + String(repeating: "text\n", count: 300))
        let initial = try fixture.viewport()
        let first = try #require(initial.caretRect(at: 4))
        fixture.textView.font = .monospacedSystemFont(ofSize: 25, weight: .regular)
        let changedFont = try #require(try fixture.viewport().caretRect(at: 4))
        #expect(changedFont.height > first.height)
        fixture.textView.textStorage?.replaceCharacters(
            in: NSRange(location: 0, length: 4), with: "")
        let changedText = try #require(try fixture.viewport().caretRect(at: 0))
        #expect(changedText.minY < changedFont.minY)
        fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        let scrolled = try fixture.viewport()
        #expect(!scrolled.containsInsertion(at: 0))
        #expect(scrolled.characterRange.location > 0)
        fixture.resizeViewport(width: 180)
        let resized = try fixture.viewport()
        #expect(resized.viewRect.width <= 180)
        #expect(resized.viewRect.width < initial.viewRect.width)
    }

    @Test("Viewport resize changes wrapped caret geometry")
    func resizedViewportReflowsCaretGeometry() throws {
        let fixture = Fixture(String(repeating: "word ", count: 12), height: 240)
        let initial = try fixture.viewport()
        let first = try #require(initial.caretRect(at: 50))
        fixture.resizeViewport(width: 180)
        let resized = try fixture.viewport()
        let reflowed = try #require(resized.caretRect(at: 50))
        #expect(resized.viewRect.width <= 180)
        #expect(reflowed.minY > first.minY)
    }

    @Test("Blame hit geometry clears on an offscreen pass and when completion takes over")
    func blameHitRectDoesNotSurviveInvalidation() throws {
        let fixture = Fixture("x\n" + String(repeating: "text\n", count: 300))
        let view = fixture.textView
        view.inlineBlameColor = .gray
        view.inlineBlameAnnotation = InlineBlameAnnotation(lineNumber: 1, text: "Author")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        try fixture.drawBackground()
        #expect(!view.inlineBlameRect.isEmpty)
        view.inlineCompletionGhost = "suggestion"
        view.inlineCompletionGhostColor = .gray
        try fixture.drawBackground()
        #expect(view.inlineBlameRect == .zero)
        view.inlineCompletionGhost = nil
        try fixture.drawBackground()
        #expect(!view.inlineBlameRect.isEmpty)
        fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        try fixture.drawBackground()
        #expect(view.inlineBlameRect == .zero)
    }

    @Test("Long lines decline bounded decorations before character geometry")
    func longLineDecorationsDecline() throws {
        let fixture = Fixture(String(repeating: "x", count: 12_000))
        let view = fixture.textView
        view.currentLineHighlightColor = .gray
        view.inlineBlameColor = .gray
        view.inlineBlameAnnotation = InlineBlameAnnotation(lineNumber: 1, text: "Author")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        view.viewportLayoutMetrics.reset()
        try fixture.drawBackground()
        #expect(view.viewportLayoutMetrics.characterGeometryRequests == 0)
        #expect(view.inlineBlameRect == .zero)
    }

    @Test("CRLF full-file blame requests one end per logical line")
    func crlfBlameDoesNotDrawAnExtraLFLine() throws {
        let fixture = Fixture("a\r\nb\r\n")
        let view = fixture.textView
        view.fileBlameColor = .gray
        // Offset 2 is the LF inside the first CRLF, not a line start.
        view.fileBlameAnnotations = [0: "first", 2: "invalid LF line", 3: "second", 6: "empty"]
        view.viewportLayoutMetrics.reset()
        try fixture.drawBackground()
        #expect(view.viewportLayoutMetrics.characterGeometryRequests == 2)
    }

    @Test("Scroll redraw removes and restores extra caret geometry")
    func scrollRedrawRefreshesOverlay() throws {
        let fixture = Fixture("abc def\n" + String(repeating: "text\n", count: 300))
        let view = fixture.textView
        view.applyCaretRanges([
            NSRange(location: 0, length: 0), NSRange(location: 4, length: 0),
        ])
        #expect(view.subviews.contains { $0 is MultiCaretOverlayView })
        fixture.scrollView.contentView.scroll(to: NSPoint(x: 0, y: 600))
        view.viewportLayoutMetrics.reset()
        try fixture.drawBackground()
        #expect(!view.subviews.contains { $0 is MultiCaretOverlayView })
        #expect(view.viewportLayoutMetrics.viewportRequests == 1)
        #expect(view.viewportLayoutMetrics.characterGeometryRequests == 0)
        fixture.scrollView.contentView.scroll(to: .zero)
        view.viewportLayoutMetrics.reset()
        try fixture.drawBackground()
        let overlay = try #require(view.subviews.compactMap { $0 as? MultiCaretOverlayView }.first)
        #expect(overlay.caretRects.count == 1)
        #expect(view.viewportLayoutMetrics.viewportRequests == 1)
    }

    @Test("Hidden editors issue no viewport request")
    func hiddenEditorDeclines() throws {
        let fixture = Fixture("abc")
        fixture.textView.isHidden = true
        fixture.textView.viewportLayoutMetrics.reset()
        #expect(
            EditorViewportLayout(
                textView: fixture.textView, rect: fixture.textView.bounds,
                metrics: fixture.textView.viewportLayoutMetrics) == nil)
        #expect(fixture.textView.viewportLayoutMetrics.viewportRequests == 0)
    }
}
