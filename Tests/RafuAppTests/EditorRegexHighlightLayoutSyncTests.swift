import AppKit
import Testing

@testable import RafuApp

/// Forwards the storage delegate callback exactly as
/// `CodeEditorView.Coordinator.textStorage(_:didProcessEditing:...)` does.
@MainActor
private final class PipelineForwarder: NSObject, NSTextStorageDelegate {
    var pipeline: NeonSyntaxHighlightingPipeline?

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            pipeline?.didProcessEditing(
                editedMask: editedMask, editedRange: editedRange, changeInLength: delta)
        }
    }
}

@MainActor
private struct EditorHarness {
    let scrollView: NSScrollView
    let textView: RafuTextView
    let forwarder: PipelineForwarder
    let pipeline: NeonSyntaxHighlightingPipeline

    init(text: String, fileName: String) {
        scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 900, height: 860))
        textView = RafuTextView.makeTextKit1()
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.font = RafuThemeCatalog.indigo.resolvedEditorFont()
        scrollView.documentView = textView
        textView.string = text
        forwarder = PipelineForwarder()
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        pipeline = NeonSyntaxHighlightingPipeline(
            textView: textView,
            theme: RafuThemeCatalog.indigo,
            fileExtension: fileExtension,
            fileName: fileName
        )
        forwarder.pipeline = pipeline
        textView.textStorage?.delegate = forwarder
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
    }

    /// Replaces the selection the way typing does.
    func type(_ string: String) {
        textView.insertText(string, replacementRange: textView.selectedRange())
    }

    /// The layout manager must describe exactly the storage text: same
    /// character count, same characters, and every line fragment ending at
    /// or before the text end.
    func expectLayoutMatchesStorage(
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let layoutManager = textView.layoutManager!
        let storage = textView.textStorage!
        layoutManager.ensureLayout(for: textView.textContainer!)
        let glyphCount = layoutManager.numberOfGlyphs
        let mapped = layoutManager.characterRange(
            forGlyphRange: NSRange(location: 0, length: glyphCount), actualGlyphRange: nil)
        #expect(
            mapped == NSRange(location: 0, length: storage.length),
            "layout covers \(mapped) but storage length is \(storage.length)",
            sourceLocation: sourceLocation)
        let visible = layoutManager.glyphRange(
            forBoundingRect: textView.visibleRect, in: textView.textContainer!)
        let visibleCharacters = layoutManager.characterRange(
            forGlyphRange: visible, actualGlyphRange: nil)
        #expect(
            NSMaxRange(visibleCharacters) <= storage.length,
            "visible range \(visibleCharacters) passes text end \(storage.length)",
            sourceLocation: sourceLocation)
    }
}

/// The 31-line `.env` shape from the 2026-10-20 report: KEY=value lines,
/// `# ` comments, blank lines, then the region line, one more key, an empty
/// line, and a trailing newline.
private let envFixture: String = {
    var rows: [String] = []
    for index in 1...27 {
        switch index % 6 {
        case 0: rows.append("")
        case 3: rows.append("# section \(index) settings")
        default: rows.append("KEY_\(index)=value_\(index)")
        }
    }
    rows += [
        "ASSUREBOX_MODEL=global.openai.gpt-6.1-sol",
        "AWS_REGION=us-west-2",
        "ASSUREBOX_QYRION_PATH=qyrion",
        "",
    ]
    return rows.joined(separator: "\n") + "\n"
}()

@MainActor
private func runReportedEditSequence(on harness: EditorHarness) {
    let textView = harness.textView
    let regionValue = (textView.string as NSString).range(of: "us-west-2")
    textView.setSelectedRange(regionValue)
    harness.type("d")
    harness.expectLayoutMatchesStorage()
    harness.type("y")

    // Command-Shift-Down: select from the caret to the document end.
    let caret = textView.selectedRange().location
    let length = (textView.string as NSString).length
    textView.setSelectedRange(NSRange(location: caret, length: length - caret))
    harness.type("r")
    harness.expectLayoutMatchesStorage()

    // Shift-Up twice, then Delete, then type.
    textView.moveUpAndModifySelection(nil)
    textView.moveUpAndModifySelection(nil)
    textView.deleteBackward(nil)
    harness.expectLayoutMatchesStorage()
    harness.type("ion\n\n")
    harness.expectLayoutMatchesStorage()
}

@MainActor
@Test(
    "Layout follows the storage after edits at the end of a regex-highlighted file",
    arguments: [".env", "notes.txt", "config.ini", "Makefile"])
func layoutFollowsEditsInRegexHighlightedFile(fileName: String) {
    let harness = EditorHarness(text: envFixture, fileName: fileName)
    harness.expectLayoutMatchesStorage()
    runReportedEditSequence(on: harness)
}

@MainActor
@Test("Regex highlighting does not query layout while the storage is editing")
func regexHighlightingWaitsForEditToFinish() {
    let harness = EditorHarness(text: envFixture, fileName: ".env")
    let regionValue = (harness.textView.string as NSString).range(of: "us-west-2")
    harness.textView.setSelectedRange(regionValue)
    harness.type("dyrion")
    #expect(harness.textView.string.contains("AWS_REGION=dyrion\n"))
    harness.expectLayoutMatchesStorage()
}

@MainActor
@Test("Deferred regex invalidation still colors the edited text")
func deferredRegexInvalidationColorsEditedText() async throws {
    let harness = EditorHarness(text: envFixture, fileName: ".env")
    let textView = harness.textView
    let length = (textView.string as NSString).length
    textView.setSelectedRange(NSRange(location: length - 1, length: 0))
    harness.type("NEW_KEY")
    harness.type("=1")
    harness.expectLayoutMatchesStorage()

    // The invalidation is queued on the main queue; this continuation is
    // queued after it, so the flush has run when it resumes. No timer.
    await withCheckedContinuation { continuation in
        DispatchQueue.main.async { continuation.resume() }
    }

    let keyLocation = (textView.string as NSString).range(of: "NEW_KEY").location
    let layoutManager = try #require(textView.layoutManager)
    let applied = layoutManager.temporaryAttributes(
        atCharacterIndex: keyLocation, effectiveRange: nil)
    let propertyHex = try #require(RafuThemeCatalog.indigo.syntax["property"]?.color)
    let expectedColor = NSColor(rafuHex: propertyHex)
    #expect(applied[.foregroundColor] as? NSColor == expectedColor)
}

@MainActor
@Test("A later edit folds into a pending invalidation range")
func coalescedEditInvalidationCoversBothEdits() {
    typealias Pipeline = NeonSyntaxHighlightingPipeline
    // No pending range: the edit itself.
    #expect(
        Pipeline.coalescedEditInvalidation(
            pending: nil, editedRange: NSRange(location: 4, length: 2), delta: 2)
            == NSRange(location: 4, length: 2))
    // Insertion before the pending range moves it right.
    #expect(
        Pipeline.coalescedEditInvalidation(
            pending: NSRange(location: 10, length: 3),
            editedRange: NSRange(location: 2, length: 4), delta: 4)
            == NSRange(location: 2, length: 15))
    // Deletion that swallows the pending range collapses it onto the edit.
    #expect(
        Pipeline.coalescedEditInvalidation(
            pending: NSRange(location: 10, length: 3),
            editedRange: NSRange(location: 8, length: 0), delta: -9)
            == NSRange(location: 8, length: 0))
    // Edit after the pending range leaves it in place.
    #expect(
        Pipeline.coalescedEditInvalidation(
            pending: NSRange(location: 1, length: 2),
            editedRange: NSRange(location: 20, length: 1), delta: 1)
            == NSRange(location: 1, length: 20))
}
