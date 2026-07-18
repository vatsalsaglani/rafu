import Foundation
import Testing

@testable import RafuApp

@MainActor
@Suite("Untitled documents (issue #6)")
struct EditorDocumentUntitledTests {
    @Test("An untitled document starts blank, unsaved, and numbered")
    func untitledDocumentIdentity() {
        let first = EditorDocument(untitledNumber: 1)
        #expect(first.isUntitled)
        #expect(first.displayName == "Untitled")

        let second = EditorDocument(untitledNumber: 2)
        #expect(second.isUntitled)
        #expect(second.displayName == "Untitled 2")
    }

    @Test("A normal file-backed document is never untitled")
    func fileBackedDocumentIsNotUntitled() {
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/example.swift"))
        #expect(!document.isUntitled)
    }

    @Test("Assigning a saved URL converts an untitled document to file-backed")
    func assigningSavedURLClearsUntitled() {
        let document = EditorDocument(untitledNumber: 1)
        let destination = URL(fileURLWithPath: "/tmp/rafu-untitled-save-test/notes.md")

        document.assignSavedURL(destination)

        #expect(!document.isUntitled)
        #expect(document.url == destination)
        #expect(document.displayName == "notes.md")
    }
}

@MainActor
@Suite("Untitled document session wiring (issues #6, #14)")
struct WorkspaceUntitledDocumentSessionTests {
    @Test("New untitled document is appended, selected, and sequentially numbered")
    func newUntitledDocumentOpensAndSelects() {
        let session = WorkspaceSession()

        session.newUntitledDocument()
        session.newUntitledDocument()

        #expect(session.openDocuments.count == 2)
        #expect(session.openDocuments.map(\.displayName) == ["Untitled", "Untitled 2"])
        #expect(session.openDocuments.allSatisfy { $0.isUntitled })
        #expect(session.selectedDocument === session.openDocuments.last)
    }

    @Test("Save routes a normal document straight through its save action")
    func saveSelectedDocumentUsesSaveActionForNormalDocument() {
        let session = WorkspaceSession()
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/example.swift"))
        var savedViaAction = false
        document.saveAction = { savedViaAction = true }
        session.openDocuments = [document]
        session.selectedDocumentID = document.id

        session.saveSelectedDocument()

        #expect(savedViaAction)
    }

    @Test("Save is a no-op with no selected document")
    func saveSelectedDocumentNoSelection() {
        let session = WorkspaceSession()
        session.saveSelectedDocument()
        #expect(session.selectedDocument == nil)
    }

    @Test("Saving an untitled document without a mounted editor is a no-op")
    func saveUntitledDocumentWithoutMountedEditorIsNoOp() {
        let session = WorkspaceSession()
        let document = EditorDocument(untitledNumber: 1)
        // No `saveAction` set — mirrors an untitled tab whose `CodeEditorView`
        // hasn't mounted yet. `presentSavePanel`'s guard must reject this
        // before ever constructing an `NSSavePanel`.
        session.openDocuments = [document]
        session.selectedDocumentID = document.id

        session.saveUntitledDocument(document)

        #expect(document.isUntitled)
        #expect(document.url.lastPathComponent == "Untitled")
    }

    @Test("Toggling the sidebar flips the session's collapsed flag")
    func toggleSidebarFlipsFlag() {
        let session = WorkspaceSession()
        #expect(!session.isSidebarCollapsed)

        session.toggleSidebar()
        #expect(session.isSidebarCollapsed)

        session.toggleSidebar()
        #expect(!session.isSidebarCollapsed)
    }
}
