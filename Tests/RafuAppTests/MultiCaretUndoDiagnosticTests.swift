import AppKit
import Testing

@testable import RafuApp

/// Regression coverage for the multi-caret undo crash: a tree-sitter token
/// request that was in flight when the document changed used to complete
/// with its stale range, polluting Neon's valid-range bookkeeping and
/// tripping `RangeMutation.transform`'s bounds assertion on the next edit
/// (reliably: undo of a multi-caret backspace).

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
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let textView = RafuTextView.makeTextKit1()
    textView.frame = scrollView.bounds
    scrollView.documentView = textView

    // One ~2 MB line with no newline: the previous implementation walked the
    // whole string per draw via NSString.lineRange(for:). The bounded scan
    // must finish promptly and draw nothing rather than hang.
    textView.string = "    " + String(repeating: "x", count: 2_000_000)
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)

    let clock = ContinuousClock()
    let elapsed = clock.measure {
        textView.display()
    }
    // Generous bound: a debug-build draw of the visible slice should be far
    // under this; the unbounded version took tens of seconds.
    #expect(elapsed < .seconds(5))
}
