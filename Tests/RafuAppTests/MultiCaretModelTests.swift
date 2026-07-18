import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Multi-caret model")
struct MultiCaretModelTests {
    @Test("Normalization sorts, clamps, merges, deduplicates, and follows the primary")
    func normalization() {
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 8, length: 20),
                NSRange(location: 2, length: 3),
                NSRange(location: 5, length: 2),
                NSRange(location: 1, length: 0),
                NSRange(location: 1, length: 0),
            ],
            primaryIndex: 2,
            textLength: 10
        )

        #expect(
            model.ranges == [
                NSRange(location: 1, length: 0),
                NSRange(location: 2, length: 5),
                NSRange(location: 8, length: 2),
            ])
        #expect(model.primaryIndex == 1)
        #expect(model.primaryRange == NSRange(location: 2, length: 5))
    }

    @Test("Empty input becomes one safe primary caret")
    func emptyInput() {
        let model = MultiCaretModel(ranges: [], primaryIndex: 99, textLength: -10)
        #expect(model.ranges == [NSRange(location: 0, length: 0)])
        #expect(model.primaryIndex == 0)
    }

    @Test("Insertion edits are reverse sorted and final carets include cumulative shifts")
    func insertionShifting() {
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 1, length: 0),
                NSRange(location: 4, length: 0),
                NSRange(location: 8, length: 0),
            ],
            primaryIndex: 1,
            textLength: 10
        )
        let result = model.applyingReplacement("x", at: 10)

        #expect(result.edits.map(\.range.location) == [8, 4, 1])
        #expect(
            result.model.ranges == [
                NSRange(location: 2, length: 0),
                NSRange(location: 6, length: 0),
                NSRange(location: 11, length: 0),
            ])
        #expect(result.model.primaryIndex == 1)
    }

    @Test("Mixed-length replacements shift later carets by each earlier delta")
    func mixedReplacementLengths() {
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 1, length: 1),
                NSRange(location: 5, length: 3),
                NSRange(location: 10, length: 0),
            ],
            textLength: 12
        )
        let result = model.applyingReplacement("YZ", at: 12)

        #expect(result.edits.map(\.range.location) == [10, 5, 1])
        #expect(
            result.model.ranges == [
                NSRange(location: 3, length: 0),
                NSRange(location: 8, length: 0),
                NSRange(location: 12, length: 0),
            ])
    }

    @Test("Deleting mixed selections computes final coordinates")
    func selectionDeletion() {
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 1, length: 2),
                NSRange(location: 5, length: 3),
            ],
            primaryIndex: 1,
            textLength: 10
        )
        let result = model.applyingReplacement("", at: 10)

        #expect(result.edits.map(\.range.location) == [5, 1])
        #expect(
            result.model.ranges == [
                NSRange(location: 1, length: 0),
                NSRange(location: 3, length: 0),
            ])
        #expect(result.model.primaryIndex == 1)
    }

    @Test("UTF-16 surrogate pairs count as two code units in replacement math")
    func surrogatePairReplacement() {
        let text = "a😀b"
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 1, length: 2),
                NSRange(location: 4, length: 0),
            ],
            textLength: (text as NSString).length
        )
        let result = model.applyingReplacement("🙂", at: (text as NSString).length)

        #expect(result.edits.map(\.range.location) == [4, 1])
        #expect(
            result.model.ranges == [
                NSRange(location: 3, length: 0),
                NSRange(location: 6, length: 0),
            ])
    }

    @Test("Backward deletion removes a whole composed emoji")
    func backwardDeletionPreservesComposedCharacters() {
        let text = "a😀b"
        let model = MultiCaretModel(
            ranges: [NSRange(location: 3, length: 0)],
            textLength: (text as NSString).length
        )
        let result = model.applyingDeletion(.backward, in: text)

        #expect(
            result.edits == [
                MultiCaretSubedit(range: NSRange(location: 1, length: 2), replacement: "")
            ])
        #expect(result.model.primaryRange == NSRange(location: 1, length: 0))
    }

    @Test("Deletion merges carets whose targets converge")
    func deletionConvergence() {
        let text = "ab"
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 1, length: 0),
                NSRange(location: 2, length: 0),
            ],
            textLength: (text as NSString).length
        )
        let result = model.applyingDeletion(.backward, in: text)

        #expect(
            result.edits == [
                MultiCaretSubedit(range: NSRange(location: 0, length: 2), replacement: "")
            ])
        #expect(result.model.ranges == [NSRange(location: 0, length: 0)])
    }

    @Test("Forward deletion at EOF is a no-op while other carets still edit")
    func forwardDeletionBoundary() {
        let text = "ab"
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 0, length: 0),
                NSRange(location: 2, length: 0),
            ],
            primaryIndex: 1,
            textLength: (text as NSString).length
        )
        let result = model.applyingDeletion(.forward, in: text)

        #expect(
            result.edits == [
                MultiCaretSubedit(range: NSRange(location: 0, length: 1), replacement: "")
            ])
        #expect(
            result.model.ranges == [
                NSRange(location: 0, length: 0),
                NSRange(location: 1, length: 0),
            ])
        #expect(result.model.primaryIndex == 1)
    }

    @Test("Select next first expands an empty caret, then includes substring matches")
    func selectNextOccurrence() {
        let text = "foo foobar foo"
        let caret = MultiCaretModel(
            ranges: [NSRange(location: 1, length: 0)],
            textLength: (text as NSString).length
        )

        let expanded = caret.selectingNextOccurrence(in: text)
        #expect(expanded.ranges == [NSRange(location: 0, length: 3)])

        let next = expanded.selectingNextOccurrence(in: text)
        #expect(
            next.ranges == [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
            ])
    }

    @Test("Select all uses literal substring matching, not whole-word matching")
    func selectAllLiteralOccurrences() {
        let text = "foo foobar foo"
        let model = MultiCaretModel(
            ranges: [NSRange(location: 0, length: 3)],
            textLength: (text as NSString).length
        )
        let selected = model.selectingAllOccurrences(in: text)

        #expect(
            selected.ranges == [
                NSRange(location: 0, length: 3),
                NSRange(location: 4, length: 3),
                NSRange(location: 11, length: 3),
            ])
    }

    @Test("Occurrence commands on whitespace preserve the caret")
    func occurrenceWithoutIdentifier() {
        let text = "foo   bar"
        let model = MultiCaretModel(
            ranges: [NSRange(location: 4, length: 0)],
            textLength: (text as NSString).length
        )

        #expect(model.selectingNextOccurrence(in: text) == model)
        #expect(model.selectingAllOccurrences(in: text) == model)
    }

    @Test("Occurrence scans stop at the hard cap")
    func occurrenceCap() {
        let text = String(repeating: "x ", count: MultiCaretModel.occurrenceLimit + 50)
        let model = MultiCaretModel(
            ranges: [NSRange(location: 0, length: 1)],
            textLength: (text as NSString).length
        )

        #expect(model.selectingAllOccurrences(in: text).ranges.count == 1_000)
        #expect(model.selectingAllOccurrences(in: text, limit: 5_000).ranges.count == 1_000)
    }

    @Test("Column math clamps onto ragged and empty lines")
    func columnMath() {
        #expect(
            MultiCaretModel.caretLocation(
                lineStartOffset: 10,
                lineLength: 8,
                goalColumn: 3
            ) == 13)
        #expect(
            MultiCaretModel.caretLocation(
                lineStartOffset: 20,
                lineLength: 2,
                goalColumn: 7
            ) == 22)
        #expect(
            MultiCaretModel.caretLocation(
                lineStartOffset: 30,
                lineLength: 0,
                goalColumn: 4
            ) == 30)
    }

    @Test("Wrapping shifts each wrapped selection's start by the growing pair overhead")
    func wrappingSelections() {
        let text = "a bb ccc"
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 0, length: 1),
                NSRange(location: 2, length: 2),
                NSRange(location: 5, length: 3),
            ],
            primaryIndex: 1,
            textLength: (text as NSString).length
        )
        let result = model.applyingWrap(opening: "(", closing: ")", in: text)

        #expect(
            result.edits == [
                MultiCaretSubedit(range: NSRange(location: 5, length: 3), replacement: "(ccc)"),
                MultiCaretSubedit(range: NSRange(location: 2, length: 2), replacement: "(bb)"),
                MultiCaretSubedit(range: NSRange(location: 0, length: 1), replacement: "(a)"),
            ])
        #expect(
            result.model.ranges == [
                NSRange(location: 1, length: 1),
                NSRange(location: 5, length: 2),
                NSRange(location: 10, length: 3),
            ])
        #expect(result.model.primaryIndex == 1)
    }

    @Test("Wrapping leaves empty (caret-only) ranges untouched — no auto-pairing")
    func wrappingSkipsEmptyRanges() {
        let text = "ab"
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 0, length: 0),
                NSRange(location: 1, length: 1),
            ],
            textLength: (text as NSString).length
        )
        let result = model.applyingWrap(opening: "[", closing: "]", in: text)

        #expect(
            result.edits == [
                MultiCaretSubedit(range: NSRange(location: 1, length: 1), replacement: "[b]")
            ])
        #expect(
            result.model.ranges == [
                NSRange(location: 0, length: 0),
                NSRange(location: 2, length: 1),
            ])
    }

    @Test("Wrapping with no selections at all is a pass-through no-op")
    func wrappingWithNoSelections() {
        let text = "ab"
        let model = MultiCaretModel(
            ranges: [NSRange(location: 0, length: 0), NSRange(location: 2, length: 0)],
            textLength: (text as NSString).length
        )
        let result = model.applyingWrap(opening: "(", closing: ")", in: text)

        #expect(result.edits.isEmpty)
        #expect(result.model == model)
    }

    @Test("Caret toggling removes an existing secondary and collapse keeps primary")
    func toggleAndCollapse() {
        let model = MultiCaretModel(
            ranges: [
                NSRange(location: 1, length: 0),
                NSRange(location: 4, length: 0),
                NSRange(location: 8, length: 0),
            ],
            primaryIndex: 1,
            textLength: 10
        )

        let toggled = model.togglingCaret(at: 8, textLength: 10)
        #expect(toggled.ranges.count == 2)
        #expect(toggled.primaryRange == NSRange(location: 4, length: 0))
        #expect(
            toggled.collapsedToPrimary(textLength: 10).ranges == [NSRange(location: 4, length: 0)])
    }
}

@MainActor
@Test("RafuTextView keeps zero-length carets authoritative when AppKit drops them")
func textViewOwnsZeroLengthCarets() {
    let textView = RafuTextView.makeTextKit1()
    textView.frame = NSRect(x: 0, y: 0, width: 400, height: 160)
    textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
    textView.string = "alpha beta gamma"
    textView.applyCaretRanges(
        [
            NSRange(location: 1, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 12, length: 0),
        ],
        primaryIndex: 1
    )

    #expect(textView.currentCaretRanges.count == 3)
    #expect(textView.primaryCaretRange == NSRange(location: 7, length: 0))
    #expect(textView.selectedRanges.map(\.rangeValue) == [NSRange(location: 7, length: 0)])
    let overlay = textView.subviews.compactMap { $0 as? MultiCaretOverlayView }.first
    #expect(overlay?.caretRects.count == 2)
    #expect(!textView.dataWithPDF(inside: textView.bounds).isEmpty)
}

@MainActor
@Test("A plain native selection collapses the multi-caret set")
func nativeSelectionCollapsesCarets() {
    let textView = RafuTextView.makeTextKit1()
    textView.string = "alpha beta"
    textView.applyCaretRanges(
        [NSRange(location: 1, length: 0), NSRange(location: 7, length: 0)]
    )

    textView.setSelectedRange(NSRange(location: 4, length: 0))
    textView.collapseCaretSetToNativeSelectionIfNeeded()

    #expect(!textView.hasMultipleCarets)
    #expect(textView.currentCaretRanges == [NSRange(location: 4, length: 0)])
    #expect(textView.subviews.allSatisfy { !($0 is MultiCaretOverlayView) })
}

@MainActor
@Test("Reduce Motion keeps overlay carets steady")
func overlayHonorsReduceMotion() {
    let overlay = MultiCaretOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    overlay.update(
        caretRects: [NSRect(x: 10, y: 10, width: 1, height: 14)],
        color: .textColor,
        reduceMotion: true
    )

    #expect(!overlay.isBlinking)
    #expect(overlay.caretsVisible)
}

@MainActor
@Test("One multi-caret insertion is one undo group and emits one delta per caret")
func multiCaretInsertionUndoGroup() {
    let textView = RafuTextView.makeTextKit1()
    let probe = MultiCaretEditingProbe()
    textView.delegate = probe
    textView.textStorage?.delegate = probe
    textView.allowsUndo = true
    textView.string = "abcd"
    probe.processedCharacterEdits = 0
    textView.applyCaretRanges(
        [NSRange(location: 1, length: 0), NSRange(location: 3, length: 0)]
    )

    textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(textView.string == "aXbcXd")
    #expect(
        textView.currentCaretRanges == [
            NSRange(location: 2, length: 0),
            NSRange(location: 5, length: 0),
        ])
    #expect(probe.processedCharacterEdits == 2)
    #expect(probe.manager.undoActionName == "Multi-Cursor Edit")

    probe.manager.undo()
    #expect(textView.string == "abcd")
    #expect(probe.manager.redoActionName == "Multi-Cursor Edit")

    probe.manager.redo()
    #expect(textView.string == "aXbcXd")
}

@MainActor
@Test("Multi-caret backward delete preserves composed characters")
func multiCaretBackwardDelete() {
    let textView = RafuTextView.makeTextKit1()
    let probe = MultiCaretEditingProbe()
    textView.delegate = probe
    textView.textStorage?.delegate = probe
    textView.allowsUndo = true
    textView.string = "a😀 bc"
    probe.processedCharacterEdits = 0
    textView.applyCaretRanges(
        [NSRange(location: 3, length: 0), NSRange(location: 6, length: 0)]
    )

    textView.deleteBackward(nil)

    #expect(textView.string == "a b")
    #expect(
        textView.currentCaretRanges == [
            NSRange(location: 1, length: 0),
            NSRange(location: 3, length: 0),
        ])
    #expect(probe.processedCharacterEdits == 2)
    probe.manager.undo()
    #expect(textView.string == "a😀 bc")
}

@MainActor
@Test("Typing an opening bracket over a single-caret selection wraps it")
func singleCaretBracketWrap() {
    let textView = RafuTextView.makeTextKit1()
    textView.string = "let x = hello"
    textView.setSelectedRange(NSRange(location: 8, length: 5))

    textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(textView.string == "let x = (hello)")
    #expect(textView.selectedRange() == NSRange(location: 9, length: 5))
}

@MainActor
@Test("Typing an opening bracket at a bare caret still inserts it normally")
func singleCaretBracketNoSelectionInsertsLiterally() {
    let textView = RafuTextView.makeTextKit1()
    textView.string = "let x = "
    textView.setSelectedRange(NSRange(location: 8, length: 0))

    textView.insertText("(", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(textView.string == "let x = (")
    #expect(textView.selectedRange() == NSRange(location: 9, length: 0))
}

@MainActor
@Test("Typing an opening bracket over multi-caret selections wraps only the non-empty ones")
func multiCaretBracketWrap() {
    let textView = RafuTextView.makeTextKit1()
    let probe = MultiCaretEditingProbe()
    textView.delegate = probe
    textView.textStorage?.delegate = probe
    textView.allowsUndo = true
    textView.string = "aa bb"
    textView.applyCaretRanges(
        [NSRange(location: 0, length: 2), NSRange(location: 3, length: 2)]
    )

    textView.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(textView.string == "[aa] [bb]")
    #expect(
        textView.currentCaretRanges == [
            NSRange(location: 1, length: 2),
            NSRange(location: 6, length: 2),
        ])
}

@MainActor
@Test("View occurrence commands expand, add, select all, and collapse")
func viewOccurrenceCommands() {
    let textView = RafuTextView.makeTextKit1()
    textView.string = "foo foobar foo"
    textView.setSelectedRange(NSRange(location: 1, length: 0))

    textView.selectNextOccurrence()
    #expect(textView.currentCaretRanges == [NSRange(location: 0, length: 3)])

    textView.selectNextOccurrence()
    #expect(
        textView.currentCaretRanges == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
        ])

    textView.selectAllOccurrences()
    #expect(textView.currentCaretRanges.count == 3)

    textView.collapseToPrimaryCaret()
    #expect(textView.currentCaretRanges == [NSRange(location: 0, length: 3)])
}

@MainActor
@Test("Add-caret commands preserve goal column across ragged and empty lines")
func viewAddCaretColumnMath() {
    let textView = RafuTextView.makeTextKit1()
    textView.string = "1234\nx\n\nabcdef"
    textView.setSelectedRange(NSRange(location: 3, length: 0))

    textView.addCaret(direction: .below)
    textView.addCaret(direction: .below)
    textView.addCaret(direction: .below)

    #expect(
        textView.currentCaretRanges == [
            NSRange(location: 3, length: 0),
            NSRange(location: 6, length: 0),
            NSRange(location: 7, length: 0),
            NSRange(location: 11, length: 0),
        ])
}

@MainActor
@Test("Hibernation capture keeps the logical primary selection")
func hibernationCapturesPrimaryCaret() {
    let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/multi-caret.swift"))
    let coordinator = CodeEditorView.Coordinator(
        document: document,
        theme: RafuThemeCatalog.indigo,
        findState: nil
    )
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let textView = RafuTextView.makeTextKit1()
    textView.string = "foo foo foo"
    scrollView.documentView = textView
    coordinator.textView = textView
    textView.applyCaretRanges(
        [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 3),
            NSRange(location: 8, length: 3),
        ],
        primaryIndex: 1
    )

    #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
    coordinator.captureViewState(from: scrollView)
    #expect(document.restoredSelection == NSRange(location: 4, length: 3))
}

@MainActor
@Test("Escape collapses to the logical primary caret")
func escapeCollapsesCarets() throws {
    let textView = RafuTextView.makeTextKit1()
    textView.string = "foo bar"
    textView.applyCaretRanges(
        [NSRange(location: 1, length: 0), NSRange(location: 5, length: 0)],
        primaryIndex: 1
    )
    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1B}",
            charactersIgnoringModifiers: "\u{1B}",
            isARepeat: false,
            keyCode: 53
        )
    )

    textView.keyDown(with: event)

    #expect(textView.currentCaretRanges == [NSRange(location: 5, length: 0)])
}

@MainActor
private final class MultiCaretEditingProbe: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
    let manager: UndoManager = {
        let manager = UndoManager()
        manager.groupsByEvent = false
        manager.levelsOfUndo = CodeEditorView.Coordinator.undoLevelCap
        return manager
    }()

    var processedCharacterEdits = 0

    func undoManager(for view: NSTextView) -> UndoManager? {
        manager
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        true
    }

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        MainActor.assumeIsolated {
            if editedMask.contains(.editedCharacters) {
                processedCharacterEdits += 1
            }
        }
    }
}
