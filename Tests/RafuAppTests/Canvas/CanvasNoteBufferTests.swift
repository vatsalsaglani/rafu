import AppKit
import Foundation
import Testing

@testable import RafuApp

@MainActor
@Suite("Canvas note buffer")
struct CanvasNoteBufferTests {
    @Test("Toggling a task edits the TextKit buffer and updates the progress count")
    func toggleThroughBuffer() throws {
        let note = CanvasNoteBuffer(snapshot: "- [ ] a\n- [x] b\n")
        #expect(note.model.progressText == "1/2")
        #expect(note.toggleTask(at: 0))
        #expect(try note.snapshot() == "- [x] a\n- [x] b\n")
        #expect(note.revision > 0)
        note.model.refreshSummary()
        #expect(note.model.progressText == "2/2")
        #expect(!note.toggleTask(at: 5))
        #expect(try note.snapshot() == "- [x] a\n- [x] b\n")
    }

    @Test("Format commands edit the selection through the buffer")
    func formatThroughBuffer() throws {
        let note = CanvasNoteBuffer(snapshot: "hello world")
        note.textView.setSelectedRange(NSRange(location: 0, length: 5))
        note.perform(.bold)
        #expect(try note.snapshot() == "**hello** world")
        #expect(note.textView.selectedRange() == NSRange(location: 2, length: 5))
    }

    @Test("A task toggle never exceeds the note size limit")
    func limitStillApplies() {
        let note = CanvasNoteBuffer(snapshot: "- [ ] a")
        let tooBig = String(repeating: "x", count: CanvasLimits.noteBytes)
        #expect(!note.replace(NSRange(location: 0, length: 0), with: tooBig))
        #expect(note.markdown == "- [ ] a")
    }

    @Test("The summary model reports the first heading and excerpt")
    func summaryModel() {
        let note = CanvasNoteBuffer(snapshot: "# Plan\n\nShip it.\n")
        #expect(note.model.derivedTitle == "Plan")
        #expect(note.model.excerpt == "Ship it.")
        #expect(note.model.progressText == nil)
        #expect(!note.model.isEditing)
    }
}
