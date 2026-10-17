import AppKit
import RafuCore
import Testing

@testable import RafuApp

@Suite("Workspace auxiliary tabs", .serialized)
@MainActor
struct WorkspaceAuxiliaryTabTests {
    private func withWorkspace(
        _ body: (WorkspaceSession) async throws -> Void
    ) async throws {
        let suite = "dev.rafu.auxiliary-tabs.\(UUID().uuidString)"
        let store = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        let session = WorkspaceSession(restorationStore: store)
        session.descriptor = WorkspaceDescriptor(
            displayName: "Auxiliary tabs",
            location: .local(LocalWorkspaceReference(path: "/tmp/\(suite)")))
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        do {
            try await body(session)
        } catch {
            await session.flushWorkspaceState()?.value
            throw error
        }
        await session.flushWorkspaceState()?.value
    }

    @Test("Settings and Ensemble keep dirty text, undo, and the selected file tab")
    func dirtyEditorSurvivesAuxiliarySelection() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            let document = try #require(session.selectedDocument)
            let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
            let coordinator = editor.makeCoordinator()
            await coordinator.loadTask?.value
            let host = editor.makeHost(coordinator: coordinator)
            defer {
                CodeEditorView.dismantleNSView(host, coordinator: coordinator)
                document.editorResources?.release()
            }
            let resources = try #require(document.editorResources)
            let textView = try #require(coordinator.textView)
            let undo = try #require(textView.undoManager)
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            textView.insertText("keep my work", replacementRange: NSRange(location: 0, length: 0))
            undo.endUndoGrouping()
            textView.setSelectedRange(NSRange(location: 4, length: 2))
            let groupID = session.editorLayout.focusedGroupID
            let fileTabID = try #require(session.editorLayout.group(id: groupID)?.selectedTabID)

            session.showSettings()
            session.showEnsembleNewRun()
            #expect(session.auxiliaryTabs(in: groupID) == [.settings, .ensembleNewRun])
            #expect(session.editorLayout.group(id: groupID)?.selectedTabID == fileTabID)
            session.selectEditorTab(fileTabID, in: groupID)
            #expect(session.selectedAuxiliaryTab == nil)
            #expect(session.selectedDocument === document)
            #expect(document.editorResources === resources)
            #expect(textView.string == "keep my work")
            #expect(textView.selectedRange() == NSRange(location: 4, length: 2))
            #expect(document.isDirty)
            #expect(undo.canUndo)
            undo.undo()
            #expect(textView.string.isEmpty)
            undo.redo()
            #expect(textView.string == "keep my work")
            #expect(session.pendingCloseDocument == nil)
            #expect(session.terminal.sessions.isEmpty)
        }
    }

    @Test("Auxiliary tabs retain their group and Cmd-W returns to that group's file")
    func splitOwnershipAndClose() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            let firstDocument = try #require(session.selectedDocument)
            let firstGroup = session.editorLayout.focusedGroupID
            let firstTab = try #require(session.editorLayout.group(id: firstGroup)?.selectedTabID)
            session.newUntitledDocument()
            let secondDocument = try #require(session.selectedDocument)
            let secondTab = try #require(session.editorLayout.group(id: firstGroup)?.selectedTabID)
            session.splitEditorTab(secondTab, at: .trailing)
            let secondGroup = session.editorLayout.focusedGroupID
            #expect(firstGroup != secondGroup)
            session.selectEditorTab(firstTab, in: firstGroup)
            session.showSettings()
            #expect(session.selectedAuxiliaryTab(in: firstGroup) == .settings)
            #expect(session.selectedAuxiliaryTab(in: secondGroup) == nil)
            #expect(session.editorLayout.group(id: secondGroup)?.selectedTabID == secondTab)
            session.selectEditorTab(secondTab, in: secondGroup)
            #expect(session.selectedDocument === secondDocument)
            session.selectAuxiliaryTab(.settings)
            #expect(session.editorLayout.focusedGroupID == firstGroup)
            session.requestCloseActiveTab()
            #expect(session.selectedDocument === firstDocument)
            #expect(session.editorLayout.focusedGroupID == firstGroup)
            #expect(session.editorLayout.group(id: secondGroup)?.selectedTabID == secondTab)
            #expect(session.openDocuments.count == 2)
            #expect(session.auxiliaryTabs.isEmpty)
            #expect(session.pendingCloseDocument == nil)
        }
    }

    @Test("Closing an inactive auxiliary tab leaves the active file unchanged")
    func inactiveCloseAndWindowIsolation() async throws {
        try await withWorkspace { first in
            try await withWorkspace { second in
                first.newUntitledDocument()
                let document = try #require(first.selectedDocument)
                first.showSettings()
                first.showEnsembleStart()
                first.select(document)
                first.closeAuxiliaryTab(.settings)
                #expect(first.selectedDocument === document)
                #expect(first.auxiliaryTabs == [.ensembleStart])
                #expect(second.auxiliaryTabs.isEmpty)
                #expect(second.selectedAuxiliaryTab == nil)
                first.selectAuxiliaryTab(.ensembleStart)
                first.requestCloseActiveTab()
                #expect(first.selectedDocument === document)
                #expect(first.auxiliaryTabs.isEmpty)
                #expect(first.terminal.sessions.isEmpty)
            }
        }
    }

    @Test("Auxiliary tabs never enter the restorable layout")
    func auxiliaryTabsAreEphemeral() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            let before = try JSONEncoder().encode(
                EditorLayoutRestoration(layout: session.editorLayout))
            session.showSettings()
            session.showEnsembleStart()
            let after = try JSONEncoder().encode(
                EditorLayoutRestoration(layout: session.editorLayout))
            let beforeObject = try JSONSerialization.jsonObject(with: before) as? NSDictionary
            let afterObject = try JSONSerialization.jsonObject(with: after) as? NSDictionary
            #expect(beforeObject == afterObject)
            #expect(session.auxiliaryTabs == [.settings, .ensembleStart])
        }
    }

    @Test("Hidden auxiliary focus belongs only to its own native subtree")
    func auxiliaryResponderOwnership() {
        let host = NSView()
        let field = AuxiliaryFieldOwner()
        host.addSubview(field)
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.delegate = field
        #expect(AuxiliaryEditorFocusOwnership.owns(editor, in: host))
        #expect(AuxiliaryEditorFocusOwnership.owns(field, in: host))
        #expect(!AuxiliaryEditorFocusOwnership.owns(NSTextView(), in: host))
        #expect(!AuxiliaryEditorFocusOwnership.owns(editor, in: NSView()))
        editor.delegate = nil
        #expect(!AuxiliaryEditorFocusOwnership.owns(editor, in: host))
    }

    @Test("Hidden auxiliary resignation preserves another pane's new responder")
    func auxiliaryResignationIsWindowScoped() throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let contentView = try #require(window.contentView)
        let root = NSView(frame: contentView.bounds)
        window.contentView = root
        let auxiliary = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let hiddenEditor = NSTextView(frame: auxiliary.bounds)
        auxiliary.addSubview(hiddenEditor)
        root.addSubview(auxiliary)
        let fileEditor = NSTextView(frame: NSRect(x: 200, y: 0, width: 200, height: 200))
        root.addSubview(fileEditor)
        #expect(window.makeFirstResponder(hiddenEditor))
        AuxiliaryEditorFocusOwnership.resignResponder(in: auxiliary)
        #expect(window.firstResponder !== hiddenEditor)
        #expect(window.makeFirstResponder(fileEditor))
        AuxiliaryEditorFocusOwnership.resignResponder(in: auxiliary)
        #expect(window.firstResponder === fileEditor)
        AuxiliaryEditorFocusOwnership.resignResponder(in: NSView())
        #expect(window.firstResponder === fileEditor)
    }

}

@MainActor
private final class AuxiliaryFieldOwner: NSView, NSTextViewDelegate {}
