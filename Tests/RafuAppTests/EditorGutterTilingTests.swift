import AppKit
import Testing

@testable import RafuApp

/// Regression for "text starts underneath the line numbers": macOS 26 tiles
/// vertical rulers as OVERLAYS (full-width clip view + `contentInsets.left`),
/// so the wrapping text view autoresized to the full clip width and any
/// scroll to x = 0 legally parked the first characters of every line under
/// the gutter. `EditorDropForwardingScrollView.tile()` re-tiles classically:
/// the clip view must start at the ruler's trailing edge with no leftover
/// overlay inset, making x = 0 the true horizontal home.
@Suite("Editor gutter tiling")
@MainActor
struct EditorGutterTilingTests {
    private func makeEditor(
        lineCount: Int
    ) -> (scrollView: EditorDropForwardingScrollView, gutter: EditorGutterRulerView) {
        let theme = RafuThemeCatalog.indigo
        let scrollView = EditorDropForwardingScrollView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true

        let textView = RafuTextView.makeTextKit1()
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.font = theme.resolvedEditorFont()
        scrollView.documentView = textView

        let gutter = EditorGutterRulerView(
            scrollView: scrollView,
            textView: textView,
            style: EditorGutterStyle(theme: theme)
        )
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        textView.string = String(
            repeating: "Rafu is a small, native macOS repository companion.\n",
            count: lineCount
        )
        gutter.invalidateLineIndex()
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        return (scrollView, gutter)
    }

    @Test("Clip view sits beside the gutter, not underneath it")
    func clipBesideGutter() {
        let (scrollView, gutter) = makeEditor(lineCount: 200)
        let clip = scrollView.contentView
        #expect(gutter.ruleThickness > 0)
        #expect(abs(clip.frame.minX - gutter.frame.maxX) <= 0.5)
        #expect(clip.contentInsets.left == 0)
    }

    @Test("x = 0 is the horizontal home and the document never overflows it")
    func homeIsZeroWithNoPhantomOverflow() {
        let (scrollView, _) = makeEditor(lineCount: 200)
        let clip = scrollView.contentView
        guard let documentView = scrollView.documentView else {
            Issue.record("no document view")
            return
        }
        // Scrolling "home" must land at 0, and the wrapped document must fit
        // the visible width exactly — the overlay-tiling bug made it
        // ruleThickness wider, which is what let text hide under the gutter.
        documentView.scroll(NSPoint(x: 0, y: 0))
        #expect(clip.bounds.origin.x == 0)
        #expect(documentView.frame.width <= clip.bounds.width + 0.5)
    }

    @Test("A thickness change (line count gains a digit) keeps the geometry")
    func thicknessChangeKeepsGeometry() {
        let (scrollView, gutter) = makeEditor(lineCount: 9)
        guard let textView = scrollView.documentView as? RafuTextView else {
            Issue.record("no text view")
            return
        }
        let before = gutter.ruleThickness
        textView.string = String(
            repeating: "Rafu is a small, native macOS repository companion.\n",
            count: 5_000
        )
        gutter.invalidateLineIndex()
        scrollView.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        #expect(gutter.ruleThickness > before)
        #expect(abs(clip.frame.minX - gutter.frame.maxX) <= 0.5)
        #expect(clip.contentInsets.left == 0)
        #expect(textView.frame.width <= clip.bounds.width + 0.5)
    }
}
