import AppKit
import Testing

@testable import RafuApp

@Suite("Edit-driven gutter line index")
@MainActor
struct EditorGutterIncrementalIndexTests {
    /// Independent Foundation oracle, with the editor's final empty line.
    private func foundationStarts(_ content: NSString) -> [Int] {
        var result = [0]
        var location = 0
        while location < content.length {
            var end = 0
            var contentsEnd = 0
            content.getLineStart(
                nil, end: &end, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0))
            if end < content.length || contentsEnd < end { result.append(end) }
            location = end
        }
        return result
    }

    private func check(_ index: EditorGutterLineIndex, content: NSString) {
        let expected = foundationStarts(content)
        #expect(index.starts == expected)
        #expect(index.lineCount == expected.count)
        #expect(index.utf16Length == content.length)
        for offset in 0...content.length {
            let line = expected.lastIndex(where: { $0 <= offset })! + 1
            #expect(index.lineNumber(forOffset: offset) == line)
        }
    }

    @Test("Line starts match Foundation separators and UTF-16 positions")
    func separatorsAndUTF16() {
        for text in [
            "", "x", "\n", "\r", "\r\n", "\n\n", "\r\n\r\n",
            "a\u{0085}b\u{2028}c\u{2029}", "😀e\u{0301}\r\n🧵\n",
            "a\u{000B}b\u{000C}c",
        ] {
            let content = text as NSString
            let index = EditorGutterLineIndex(content: content)
            check(index, content: content)
        }
    }

    @Test("Replacements at every CRLF edge match a fresh Foundation index")
    func replacementBoundaries() {
        let bases = ["", "x", "\r", "\n", "\r\n", "a\r\nb", "\r\r\n\n", "x\n\r\ny"]
        let replacements = ["", "x", "\r", "\n", "\r\n", "\n\r", "\u{2028}", "😀\n"]
        for base in bases {
            let old = base as NSString
            for location in 0...old.length {
                for length in 0...(old.length - location) {
                    for replacement in replacements {
                        let oldRange = NSRange(location: location, length: length)
                        let content =
                            old.replacingCharacters(in: oldRange, with: replacement) as NSString
                        var index = EditorGutterLineIndex(content: old)
                        let insertedLength = (replacement as NSString).length
                        index.applyEdit(
                            content: content,
                            editedRange: NSRange(location: location, length: insertedLength),
                            changeInLength: insertedLength - length)
                        check(index, content: content)
                        #expect(index.operations.fullRebuilds == 1)
                        #expect(index.operations.incrementalScans == 1)
                    }
                }
            }
        }
    }

    @Test("Repeated near-EOF edits and inverse replacements do not rescan the prefix")
    func boundedScanAndInverseEdits() {
        let text = NSMutableString(string: String(repeating: "row 😀\r\n", count: 12_000))
        var index = EditorGutterLineIndex(content: text)
        let originalStarts = index.starts
        for _ in 0..<100 {
            let location = text.length - 2
            text.insert("🧵\n", at: location)
            index.applyEdit(
                content: text, editedRange: NSRange(location: location, length: 3),
                changeInLength: 3)
            #expect(index.lineCount == 12_002)
            text.deleteCharacters(in: NSRange(location: location, length: 3))
            index.applyEdit(
                content: text, editedRange: NSRange(location: location, length: 0),
                changeInLength: -3)
        }
        #expect(index.starts == originalStarts)
        #expect(index.operations.fullRebuilds == 1)
        #expect(index.operations.incrementalScans == 200)
        #expect(index.operations.incrementalUTF16Units <= 700)
        #expect(index.operations.shiftedOffsets <= 200)
    }

    @Test("A mismatched edit falls back to a counted rebuild")
    func missedEditRecovery() {
        var index = EditorGutterLineIndex(content: "old" as NSString)
        index.applyEdit(
            content: "new\ntext\n" as NSString,
            editedRange: NSRange(location: 0, length: 1), changeInLength: 0)
        check(index, content: "new\ntext\n" as NSString)
        #expect(index.operations.fullRebuilds == 2)
        #expect(index.operations.incrementalScans == 0)
    }

    @Test("Typing in one long line scans only the edit boundary")
    func longLineEdit() {
        let content = NSMutableString(string: String(repeating: "x", count: 500_000))
        var index = EditorGutterLineIndex(content: content)
        content.replaceCharacters(in: NSRange(location: 499_900, length: 1), with: "\n")
        index.applyEdit(
            content: content, editedRange: NSRange(location: 499_900, length: 1), changeInLength: 0)
        #expect(index.starts == [0, 499_901])
        #expect(index.operations.incrementalUTF16Units == 3)
        #expect(index.operations.fullRebuilds == 1)
    }

    private func makeEditor(_ text: String) -> (
        EditorDropForwardingScrollView, RafuTextView, EditorGutterRulerView
    ) {
        let scroll = EditorDropForwardingScrollView(
            frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let view = RafuTextView.makeTextKit1()
        view.string = text
        view.autoresizingMask = [.width]
        scroll.documentView = view
        let gutter = EditorGutterRulerView(
            scrollView: scroll, textView: view,
            style: EditorGutterStyle(theme: RafuThemeCatalog.indigo))
        scroll.verticalRulerView = gutter
        scroll.hasVerticalRuler = true
        scroll.rulersVisible = true
        scroll.tile()
        return (scroll, view, gutter)
    }

    private func drainWidthUpdate() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test("Storage edits update lookup at once and combine width work after editing")
    func storageAndWidthCoalescing() async throws {
        let (scroll, view, gutter) = makeEditor(String(repeating: "x\n", count: 98))
        let storage = try #require(view.textStorage)
        let width = gutter.ruleThickness
        let updates = gutter.thicknessUpdateCount
        let retiles = gutter.thicknessRetileCount
        for _ in 0..<3 {
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n")
            gutter.markLineIndexStale()  // Existing coordinator compatibility.
        }
        #expect(gutter.indexedLineCount == 102)
        #expect(gutter.lineNumber(forOffset: storage.length) == 102)
        #expect(gutter.ruleThickness == width)
        #expect(gutter.thicknessUpdateCount == updates)
        await drainWidthUpdate()
        #expect(gutter.thicknessUpdateCount == updates + 1)
        #expect(gutter.thicknessRetileCount == retiles + 1)
        #expect(gutter.ruleThickness > width)
        #expect(abs(scroll.contentView.frame.minX - gutter.frame.maxX) <= 0.5)
        #expect(scroll.contentView.contentInsets.left == 0)

        let operations = gutter.lineIndexOperations
        storage.addAttribute(
            .foregroundColor, value: NSColor.red, range: NSRange(location: 0, length: 1))
        for _ in 0..<5 { gutter.updateThickness() }
        await drainWidthUpdate()
        #expect(gutter.lineIndexOperations == operations)
        #expect(gutter.thicknessUpdateCount == updates + 1)
        #expect(gutter.thicknessRetileCount == retiles + 1)

        storage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "word")
        await drainWidthUpdate()
        #expect(gutter.thicknessRetileCount == retiles + 1)
        let afterEdit = gutter.lineIndexOperations
        for _ in 0..<100 {
            #expect(gutter.lineNumber(forOffset: storage.length) == 102)
            gutter.updateThickness()
        }
        #expect(gutter.lineIndexOperations == afterEdit)
    }

    @Test("Combined replacements and full same-length reloads use storage deltas")
    func combinedStorageReplacements() throws {
        let (_, view, gutter) = makeEditor("a\r\nb\n😀\n")
        let storage = try #require(view.textStorage)
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 1, length: 1), with: "")
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\r\n")
        storage.endEditing()
        let expected = foundationStarts(storage.string as NSString)
        #expect(gutter.indexedLineCount == expected.count)
        for offset in 0...storage.length {
            #expect(
                gutter.lineNumber(forOffset: offset) == expected.lastIndex(where: { $0 <= offset })!
                    + 1)
        }
        let length = storage.length
        view.string = String(repeating: "\n", count: length)
        gutter.invalidateLineIndex()
        #expect(gutter.indexedLineCount == length + 1)
        #expect(gutter.lineIndexOperations.fullRebuilds == 1)
    }

    @Test("Native text-view undo and redo keep line lookup current")
    func nativeUndoAndRedo() throws {
        let (_, view, gutter) = makeEditor("😀\r\nlast\n")
        let delegate = GutterIndexUndoDelegate()
        view.delegate = delegate
        view.allowsUndo = true
        delegate.manager.groupsByEvent = false
        delegate.manager.beginUndoGrouping()
        view.insertText("\n🧵\r", replacementRange: NSRange(location: 2, length: 2))
        delegate.manager.endUndoGrouping()
        let inserted = view.string
        #expect(delegate.manager.canUndo)
        delegate.manager.undo()
        #expect(view.string == "😀\r\nlast\n")
        #expect(gutter.indexedLineCount == 3)
        #expect(gutter.lineNumber(forOffset: 3) == 1)
        #expect(gutter.lineNumber(forOffset: 4) == 2)
        delegate.manager.redo()
        #expect(view.string == inserted)
        let content = view.string as NSString
        let expected = foundationStarts(content)
        #expect(gutter.indexedLineCount == expected.count)
        for offset in 0...content.length {
            #expect(
                gutter.lineNumber(forOffset: offset) == expected.lastIndex(where: { $0 <= offset })!
                    + 1)
        }
        #expect(gutter.lineIndexOperations.fullRebuilds == 1)
        view.delegate = nil
    }

    @Test("One editor's storage edits do not change another gutter")
    func separateStorageOwnership() throws {
        let (_, first, firstGutter) = makeEditor("one\n")
        let (_, _, secondGutter) = makeEditor("two\r\nthree")
        let operations = secondGutter.lineIndexOperations
        let storage = try #require(first.textStorage)
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n")
        #expect(firstGutter.indexedLineCount == 3)
        #expect(secondGutter.indexedLineCount == 2)
        #expect(secondGutter.lineIndexOperations == operations)
    }
}

@MainActor
private final class GutterIndexUndoDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()

    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}
