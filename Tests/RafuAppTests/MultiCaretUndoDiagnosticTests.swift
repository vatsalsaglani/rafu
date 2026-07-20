import AppKit
import Testing

@testable import RafuApp

/// Regression coverage for the multi-caret undo crash: a tree-sitter token
/// request that was in flight when the document changed used to complete
/// with its stale range, polluting Neon's valid-range bookkeeping and
/// tripping `RangeMutation.transform`'s bounds assertion on the next edit
/// (reliably: undo of a multi-caret backspace).

/// Forces `view` to actually run its `draw(_:)`/`drawRect(_:)` path for
/// `rect` via an offscreen bitmap, the way `-cacheDisplay(in:to:)` does.
/// `NSView.display()` is a no-op for drawing when the view has no live
/// WindowServer connection (true of this test process), so a test that
/// calls `.display()` and asserts on timing or drawn side effects is
/// silently vacuous — the decoration code never runs at all. Rendering into
/// an explicit bitmap sidesteps the WindowServer entirely and reliably
/// invokes drawing regardless of the test host's session.
@MainActor
private func forceOffscreenDraw(_ view: NSView, in rect: NSRect) {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: rect) else {
        Issue.record("could not allocate offscreen bitmap for \(rect)")
        return
    }
    view.cacheDisplay(in: rect, to: rep)
}

/// Forwards storage edits to the pipeline the way
/// `CodeEditorView.Coordinator` does, and records each event so the Neon
/// delta contract (`previousRange.max <= preEditLength`) can be asserted.
@MainActor
private final class PipelineForwardingDelegate: NSObject, NSTextStorageDelegate {
    struct Event {
        let editedRange: NSRange
        let delta: Int
        let postLength: Int
        var previousRangeMax: Int { editedRange.location + max(0, editedRange.length - delta) }
        var preEditLength: Int { postLength - delta }
    }

    var pipeline: NeonSyntaxHighlightingPipeline?
    var events: [Event] = []

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        let postLength = textStorage.length
        MainActor.assumeIsolated {
            pipeline?.didProcessEditing(
                editedMask: editedMask, editedRange: editedRange, changeInLength: delta)
            events.append(Event(editedRange: editedRange, delta: delta, postLength: postLength))
        }
    }
}

/// Minimal delegate that vends the test's UndoManager to the text view.
@MainActor
private final class UndoHostingDelegate: NSObject, NSTextViewDelegate {
    let manager: UndoManager
    init(manager: UndoManager) { self.manager = manager }
    nonisolated func undoManager(for view: NSTextView) -> UndoManager? {
        MainActor.assumeIsolated { manager }
    }
}

@MainActor
@Test("Undo of a multi-caret edit survives an in-flight stale token request")
func multiCaretUndoSurvivesStaleTokenRequest() async throws {
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView
    textView.allowsUndo = true

    let manager = UndoManager()
    manager.groupsByEvent = false
    let undoHost = UndoHostingDelegate(manager: manager)
    textView.delegate = undoHost

    let original = "let shared = 1\nlet shared = 2\n"
    textView.string = original

    let pipeline = NeonSyntaxHighlightingPipeline(
        textView: textView,
        theme: RafuThemeCatalog.indigo,
        fileExtension: "swift"
    )
    let forwarder = PipelineForwardingDelegate()
    forwarder.pipeline = pipeline
    textView.textStorage?.delegate = forwarder

    // Wait for the tree-sitter actor so the async token path is live.
    let deadline = ContinuousClock.now + .seconds(10)
    while !pipeline.hasLiveGrammarActorForTesting {
        guard ContinuousClock.now < deadline else {
            Issue.record("grammar actor never activated")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    // Let the activation-time full highlight finish.
    for _ in 0..<20 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(50))

    // Issue a fresh full-buffer token request. Its provider task is created
    // synchronously but cannot run until this test suspends, so everything
    // below happens with the request in flight against the 30-char document.
    pipeline.applyBaseStyleAndInvalidate()

    // ⌘D-style second caret on "shared", then multi-caret backspace: two
    // shrinking edits land while the full-buffer request is still pending.
    textView.setSelectedRange(NSRange(location: 4, length: 6))
    textView.selectNextOccurrence()
    textView.deleteBackward(nil)
    #expect(textView.string == "let  = 1\nlet  = 2\n")

    // Yield so the stale completion (ranges up to the pre-delete length)
    // arrives. Before the fix it polluted Neon's valid set beyond the
    // 18-char document.
    for _ in 0..<20 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(100))

    // Undo used to hit RangeMutation.transform's assertion here.
    manager.undo()
    #expect(textView.string == original)

    // Every delegate event must satisfy the Neon contract regardless.
    for event in forwarder.events {
        #expect(event.previousRangeMax <= event.preEditLength)
    }
    pipeline.tearDown()
}

@MainActor
@Test("Indent-guide line scan is bounded on single-giant-line documents")
func indentGuideLineScanBounded() {
    let viewportRect = NSRect(x: 0, y: 0, width: 480, height: 320)
    let scrollView = NSScrollView(frame: viewportRect)
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView

    // Every bounded decoration path (indent guides, current-line highlight)
    // only runs when its color/font are set — leaving these unset makes the
    // test vacuous (every decoration early-returns before the scan even
    // runs). Set them, and a caret, so the bounded scan is actually
    // exercised by the measured draw.
    textView.font = RafuThemeCatalog.indigo.resolvedEditorFont()
    textView.indentGuideColor = .gray
    textView.currentLineHighlightColor = .gray

    // One ~2 MB line with no newline: the previous implementation walked the
    // whole string per draw via NSString.lineRange(for:). The bounded scan
    // must finish promptly and draw nothing rather than hang.
    textView.string = "    " + String(repeating: "x", count: 2_000_000)
    textView.setSelectedRange(NSRange(location: 5, length: 0))
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        forceOffscreenDraw(textView, in: viewportRect)
    }
    // Generous bound: a debug-build draw of the visible slice should be far
    // under this; the unbounded version took tens of seconds.
    #expect(elapsed < .seconds(5))
}

@MainActor
@Test("Current-line and indent-guide draws are bounded on huge line-count documents")
func manyLineDocumentDrawIsBounded() {
    let viewportRect = NSRect(x: 0, y: 0, width: 480, height: 320)
    let scrollView = NSScrollView(frame: viewportRect)
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView

    textView.font = RafuThemeCatalog.indigo.resolvedEditorFont()
    textView.indentGuideColor = .gray
    textView.currentLineHighlightColor = .gray

    // 200k short lines: a document shape unrelated to the giant-single-line
    // case above, but one where per-draw decoration walks that aren't
    // scoped to the visible glyph range would also regress badly.
    let line = "    let x = 1\n"
    textView.string = String(repeating: line, count: 200_000)
    textView.setSelectedRange(NSRange(location: 20, length: 0))

    // Ensure the visible region is laid out before measuring so the ceiling
    // targets per-draw decoration cost, not one-time first layout.
    guard let layoutManager = textView.layoutManager, let container = textView.textContainer
    else {
        Issue.record("missing TextKit 1 stack")
        return
    }
    let visibleGlyphRange = layoutManager.glyphRange(
        forBoundingRect: viewportRect, in: container)
    layoutManager.ensureLayout(forGlyphRange: visibleGlyphRange)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        forceOffscreenDraw(textView, in: viewportRect)
    }
    #expect(elapsed < .seconds(5))
}

@MainActor
@Test("Editor disables Writing Tools on the code buffer")
func editorDisablesWritingTools() {
    let textView = RafuTextView.makeTextKit1()
    #expect(textView.writingToolsBehavior == .none)
}

@MainActor
@Test("Inline blame draw clears its hover rect when the caret's line boundary is unbounded")
func inlineBlameDrawClearsRectBeyondScanCap() {
    let viewportRect = NSRect(x: 0, y: 0, width: 480, height: 320)
    let scrollView = NSScrollView(frame: viewportRect)
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView

    textView.font = RafuThemeCatalog.indigo.resolvedEditorFont()
    textView.inlineBlameColor = .gray
    textView.inlineBlameAnnotation = InlineBlameAnnotation(lineNumber: 1, text: "author • 1d ago")

    // One 20k-char line, no newlines. A caret 10k in has no newline within
    // the 4096-unit scan cap in either direction, so a bounded line-range
    // lookup must return nil (deterministic, not timing-dependent): this is
    // the direct proof that `drawInlineBlameAnnotation`'s substitution is
    // actually exercised rather than skipped. Before the fix this location
    // still resolved a valid (if expensive) line range and left
    // `inlineBlameRect` non-zero.
    textView.string = String(repeating: "x", count: 20_000)
    textView.setSelectedRange(NSRange(location: 10_000, length: 0))
    forceOffscreenDraw(textView, in: viewportRect)

    #expect(textView.inlineBlameRect == .zero)
}
