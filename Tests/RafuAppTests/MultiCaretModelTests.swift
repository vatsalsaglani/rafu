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
