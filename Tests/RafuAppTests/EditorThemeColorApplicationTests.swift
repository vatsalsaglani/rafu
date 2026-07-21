import AppKit
import Testing

@testable import RafuApp

/// `updateNSView` used to assign `textView.textColor` on EVERY SwiftUI update
/// — which is every keystroke, since `textDidChange` marks the document dirty
/// and refreshes find state. `-[NSTextView setTextColor:]` routes through
/// `setTypingAttributes:` → `updateFontPanel`, which enumerates attributes
/// over `rangeForUserCharacterAttributeChange`; that enumeration is what
/// raised `NSRangeException` from `ensureAttributesAreFixedInRange:` in
/// `select-multi-words-and-update-error.txt`, and it is real work on the
/// typing path regardless. These tests pin that the assignment happens only
/// on a genuine theme change.
@Suite("Editor theme color application")
@MainActor
struct EditorThemeColorApplicationTests {
    @Test("An unchanged theme resolves to an equal color set")
    func unchangedThemeIsEqual() {
        let theme = RafuThemeCatalog.indigo
        #expect(EditorColorSet(theme: theme) == EditorColorSet(theme: theme))
    }

    @Test("A different theme resolves to a different color set")
    func differentThemeDiffers() {
        #expect(
            EditorColorSet(theme: RafuThemeCatalog.indigo)
                != EditorColorSet(theme: RafuThemeCatalog.khadi))
    }

    /// The guard compares resolved hex, not `NSColor`: an `NSColor(rafuHex:)`
    /// round trip is not guaranteed to compare equal across colorspace
    /// representations, which would silently defeat it.
    @Test("The color set is keyed by the theme's resolved editor hex values")
    func keyedByResolvedHex() {
        let theme = RafuThemeCatalog.indigo
        let colors = EditorColorSet(theme: theme)
        #expect(colors.background == theme.editor.background)
        #expect(colors.foreground == theme.editor.foreground)
        #expect(colors.cursor == theme.editor.cursor)
    }
}

/// Editing paths must leave every selected range inside the buffer. An
/// out-of-bounds selection is what AppKit's font-panel update enumerates over,
/// so this is the invariant behind the reported crash.
@Suite("Editor selection stays in bounds")
@MainActor
struct EditorSelectionBoundsTests {
    private func makeTextView(_ text: String) -> RafuTextView {
        let textView = RafuTextView.makeTextKit1()
        textView.font = RafuThemeCatalog.indigo.resolvedEditorFont()
        textView.string = text
        return textView
    }

    private func expectSelectionInBounds(_ textView: RafuTextView, _ label: String) {
        let length = (textView.string as NSString).length
        for value in textView.selectedRanges {
            let range = value.rangeValue
            #expect(
                NSMaxRange(range) <= length,
                "\(label): \(range) exceeds buffer length \(length)"
            )
        }
    }

    @Test("Typing over a multi-word selection leaves the selection in bounds")
    func typingOverSelection() {
        let textView = makeTextView("hello world foo bar")
        // What option+shift+left twice produces: a backwards multi-word
        // selection, here "foo bar".
        textView.setSelectedRange(NSRange(location: 12, length: 7))
        textView.insertText("x", replacementRange: textView.selectedRange())

        #expect(textView.string == "hello world x")
        expectSelectionInBounds(textView, "typing over selection")
    }

    @Test("Wrapping a multi-word selection leaves the selection in bounds")
    func bracketWrapOverSelection() {
        let textView = makeTextView("hello world foo bar")
        textView.setSelectedRange(NSRange(location: 12, length: 7))
        textView.insertText("(", replacementRange: textView.selectedRange())

        #expect(textView.string == "hello world (foo bar)")
        expectSelectionInBounds(textView, "bracket wrap")
    }

    @Test("Deleting a multi-word selection leaves the selection in bounds")
    func deleteOverSelection() {
        let textView = makeTextView("hello world foo bar")
        textView.setSelectedRange(NSRange(location: 12, length: 7))
        textView.deleteBackward(nil)

        #expect(textView.string == "hello world ")
        expectSelectionInBounds(textView, "delete selection")
    }

    @Test("Newline over a selection replaces it and stays in bounds")
    func newlineOverSelection() {
        let textView = makeTextView("hello world foo bar")
        textView.setSelectedRange(NSRange(location: 12, length: 7))
        textView.insertText("\n", replacementRange: textView.selectedRange())

        #expect(textView.string == "hello world \n")
        expectSelectionInBounds(textView, "newline over selection")
    }

    @Test("An empty untitled-style buffer keeps the selection in bounds")
    func emptyBuffer() {
        let textView = makeTextView("abc")
        textView.setSelectedRange(NSRange(location: 0, length: 3))
        textView.insertText("", replacementRange: textView.selectedRange())

        #expect(textView.string.isEmpty)
        expectSelectionInBounds(textView, "emptied buffer")
    }
}
