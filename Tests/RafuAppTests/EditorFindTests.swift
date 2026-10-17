import AppKit
import Foundation
import Testing

@testable import RafuApp

@Test("Text search supports literal case, whole words, and regex capture replacement")
func textSearchModes() throws {
    let insensitive = TextSearchPattern(query: "rafu")
    #expect(try insensitive.matches(in: "Rafu rafu").count == 2)

    let wholeWord = TextSearchPattern(query: "cat", options: [.wholeWord])
    #expect(try wholeWord.matches(in: "cat scatter cat_ cat").count == 2)

    let regex = TextSearchPattern(
        query: #"(\w+)-(\w+)"#,
        replacementTemplate: "$2/$1",
        options: [.regularExpression, .caseSensitive]
    )
    #expect(try regex.replacingMatches(in: "indigo-khadi") == "khadi/indigo")
}

@MainActor
@Test("NSTextView find bridge replaces current and all while preserving undo")
func textViewFindBridgeSupportsUndo() async throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    defer { withExtendedLifetime(window) {} }
    let textView = NSTextView()
    textView.allowsUndo = true
    window.contentView = textView
    window.makeFirstResponder(textView)
    textView.string = "Rafu and Rafu"
    let state = DocumentFindState()
    let controller = NSTextViewFindController(textView: textView)
    state.attach(controller)
    state.query = "Rafu"
    state.replacement = "રફૂ"
    state.activate()
    await controller.waitForSearchCompletion()

    #expect(state.matchCount == 2)
    state.findNext()
    await controller.waitForSearchCompletion()
    #expect(textView.selectedRange() == NSRange(location: 0, length: 4))

    state.replaceCurrent()
    await controller.waitForSearchCompletion()
    #expect(textView.string == "રફૂ and Rafu")
    #expect(state.matchCount == 1)

    state.replaceAll()
    await controller.waitForSearchCompletion()
    #expect(textView.string == "રફૂ and રફૂ")
    #expect(state.matchCount == 0)

    let undoManager = try #require(textView.undoManager)
    undoManager.undo()
    await controller.waitForSearchCompletion()
    #expect(textView.string == "રફૂ and Rafu")
}

@MainActor
@Test("Match highlighting is gated on isActive and cleared on detach")
func matchHighlightsFollowActivation() async throws {
    let textView = NSTextView()
    textView.string = "Rafu and Rafu"
    let state = DocumentFindState()
    let controller = NSTextViewFindController(textView: textView)
    controller.matchHighlightColor = .systemYellow
    controller.activeMatchHighlightColor = .systemOrange
    state.attach(controller)
    state.query = "Rafu"
    // Explicit navigation remains available while the bar is closed.
    state.findNext()
    await controller.waitForSearchCompletion()
    textView.setSelectedRange(NSRange(location: 0, length: 0))
    #expect(state.matchCount == 2)

    let layoutManager = try #require(textView.layoutManager)
    func highlightColor(at index: Int) -> NSColor? {
        layoutManager.temporaryAttribute(
            .backgroundColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
    }

    // Explicit navigation ran while the bar was closed, so nothing is painted.
    #expect(!state.isActive)
    #expect(highlightColor(at: 0) == nil)

    state.activate()
    await controller.waitForSearchCompletion()
    #expect(state.isActive)
    #expect(highlightColor(at: 0) == .systemYellow)
    #expect(highlightColor(at: 9) == .systemYellow)

    // The current match uses the active color.
    state.findNext()
    await controller.waitForSearchCompletion()
    #expect(highlightColor(at: 0) == .systemOrange)
    #expect(highlightColor(at: 9) == .systemYellow)

    state.deactivate()
    #expect(highlightColor(at: 0) == nil)
    #expect(highlightColor(at: 9) == nil)

    state.activate()
    await controller.waitForSearchCompletion()
    #expect(highlightColor(at: 0) != nil)
    state.detach(controller)
    #expect(!state.isActive)
}

@MainActor
@Test("Invalid regex is surfaced without mutating the live buffer")
func invalidRegexIsNonDestructive() async {
    let textView = NSTextView()
    textView.string = "Rafu"
    let state = DocumentFindState()
    let controller = NSTextViewFindController(textView: textView)
    state.attach(controller)
    state.options = [.regularExpression]
    state.query = "("
    state.activate()
    await controller.waitForSearchCompletion()

    #expect(state.errorMessage != nil)
    state.replaceAll()
    await controller.waitForSearchCompletion()
    #expect(textView.string == "Rafu")
}
