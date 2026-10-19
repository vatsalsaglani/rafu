import AppKit
import Testing

@testable import RafuApp

/// Regression for the main-thread livelock on long files: macOS 26 overlay
/// tiling made `super.tile()` reset the clip view to full width (widening the
/// autoresizing text view) before `EditorDropForwardingScrollView.tile()`
/// narrowed it again. Every width change invalidates the whole contiguous
/// TextKit 1 layout (`widthTracksTextView`), so background layout restarted
/// from zero on each tile and never converged. A tile with nothing to change
/// must leave the text view's width, and its laid-out text, alone.
@Suite("Editor tile convergence")
@MainActor
struct EditorTileConvergenceTests {
    /// Records the width on every `frameDidChangeNotification`. Selector-based
    /// so no non-`Sendable` value crosses a `@Sendable` closure.
    private final class FrameWidthRecorder: NSObject {
        private(set) var widths: [CGFloat] = []
        private let view: NSView

        init(observing view: NSView) {
            self.view = view
            super.init()
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self, selector: #selector(frameChanged(_:)),
                name: NSView.frameDidChangeNotification, object: view)
        }

        func stop() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func frameChanged(_ note: Notification) {
            widths.append(view.frame.width)
        }
    }

    private struct Fixture {
        let scrollView: EditorDropForwardingScrollView
        let textView: RafuTextView
        let gutter: EditorGutterRulerView
    }

    private func makeEditor(lineCount: Int) -> Fixture {
        let theme = RafuThemeCatalog.indigo
        let scrollView = EditorDropForwardingScrollView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

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
        // A bare NSTextView keeps its 200 pt default width until something
        // sizes it; in the app the first layout pass fits it to the clip view.
        textView.setFrameSize(
            NSSize(width: scrollView.contentView.bounds.width, height: textView.frame.height))
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()
        return Fixture(scrollView: scrollView, textView: textView, gutter: gutter)
    }

    @Test("A no-op tile never changes the text view width")
    func noOpTileKeepsWidth() {
        let fixture = makeEditor(lineCount: 5_000)
        let textView = fixture.textView
        let settledWidth = textView.frame.width
        let settledContainerWidth = textView.textContainer?.size.width

        let recorder = FrameWidthRecorder(observing: textView)
        defer { recorder.stop() }

        for _ in 0..<10 {
            fixture.scrollView.tile()
        }

        #expect(recorder.widths.allSatisfy { $0 == settledWidth })
        #expect(textView.frame.width == settledWidth)
        #expect(textView.textContainer?.size.width == settledContainerWidth)
    }

    @Test("Tiling preserves already-laid-out text")
    func tilePreservesLayout() {
        let fixture = makeEditor(lineCount: 20_000)
        guard let layoutManager = fixture.textView.layoutManager,
            let container = fixture.textView.textContainer
        else {
            Issue.record("no layout manager")
            return
        }
        layoutManager.ensureLayout(for: container)
        let length = (fixture.textView.string as NSString).length
        #expect(layoutManager.firstUnlaidCharacterIndex() == length)

        for _ in 0..<3 {
            fixture.scrollView.tile()
        }
        #expect(layoutManager.firstUnlaidCharacterIndex() == length)
    }

    @Test("Geometry still tracks a scroll view resize")
    func geometryAfterResize() {
        let fixture = makeEditor(lineCount: 500)
        let scrollView = fixture.scrollView
        scrollView.setFrameSize(NSSize(width: 800, height: 400))
        scrollView.tile()
        scrollView.layoutSubtreeIfNeeded()

        let clip = scrollView.contentView
        #expect(abs(fixture.textView.frame.width - clip.bounds.width) <= 0.5)
        #expect(abs(clip.frame.minX - fixture.gutter.frame.maxX) <= 0.5)
        #expect(clip.contentInsets.left == 0)
    }

    @Test("A scrolled position survives repeated tiles")
    func scrollPositionSurvivesTile() {
        let fixture = makeEditor(lineCount: 20_000)
        let textView = fixture.textView
        let clip = fixture.scrollView.contentView
        guard let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else {
            Issue.record("no layout manager")
            return
        }
        layoutManager.ensureLayout(for: container)
        textView.setSelectedRange(NSRange(location: 540, length: 0))

        let documentHeight = textView.frame.height
        let target = NSPoint(x: clip.bounds.origin.x, y: (documentHeight / 2).rounded())
        clip.scroll(to: target)
        fixture.scrollView.reflectScrolledClipView(clip)
        let scrolledY = clip.bounds.origin.y
        #expect(scrolledY > 0)

        for _ in 0..<3 {
            fixture.scrollView.tile()
        }
        #expect(clip.bounds.origin.y == scrolledY)
    }
}
