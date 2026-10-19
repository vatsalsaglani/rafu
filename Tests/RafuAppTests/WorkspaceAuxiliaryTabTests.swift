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

    @Test("Settings keeps dirty text, undo, and the selected file tab")
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
            #expect(session.auxiliaryTabs(in: groupID) == [.settings])
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
                first.select(document)
                #expect(first.auxiliaryTabs == [.settings])
                #expect(second.auxiliaryTabs.isEmpty)
                #expect(second.selectedAuxiliaryTab == nil)
                first.closeAuxiliaryTab(.settings)
                #expect(first.selectedDocument === document)
                #expect(first.auxiliaryTabs.isEmpty)
                first.showSettings()
                first.selectAuxiliaryTab(.settings)
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
            let after = try JSONEncoder().encode(
                EditorLayoutRestoration(layout: session.editorLayout))
            let beforeObject = try JSONSerialization.jsonObject(with: before) as? NSDictionary
            let afterObject = try JSONSerialization.jsonObject(with: after) as? NSDictionary
            #expect(beforeObject == afterObject)
            #expect(session.auxiliaryTabs == [.settings])
        }
    }

    private func openDiff(_ path: String, scope: GitDiffScope = .workingTree) -> GitOpenDiff {
        GitOpenDiff(
            title: "Diff • \((path as NSString).lastPathComponent)",
            subtitle: path,
            diff: GitFileDiff(
                path: path, originalPath: nil, isBinary: false, hunks: [], rawPatch: ""),
            identity: "Working Tree:\(path)",
            scope: scope)
    }

    @Test("A Git diff joins the file shelf and Cmd-W returns to the group's file")
    func gitDiffSharesTheFileShelf() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            session.newUntitledDocument()
            session.newUntitledDocument()
            let selected = try #require(session.selectedDocument)
            let groupID = session.editorLayout.focusedGroupID
            let fileTabs = try #require(session.editorLayout.group(id: groupID)?.tabs)
            let fileTabID = try #require(session.editorLayout.group(id: groupID)?.selectedTabID)
            #expect(fileTabs.count == 3)

            let diff = openDiff("Sources/App.swift")
            let diffTab = WorkspaceAuxiliaryTab.gitDiff(GitDiffTabReference(diff))
            session.presentGitDiff(diff)
            #expect(session.editorLayout.group(id: groupID)?.tabs == fileTabs)
            #expect(session.editorLayout.group(id: groupID)?.selectedTabID == fileTabID)
            #expect(session.auxiliaryTabs(in: groupID) == [diffTab])
            #expect(session.selectedAuxiliaryTab(in: groupID) == diffTab)
            #expect(session.selectedDocumentID == nil)
            #expect(EditorCanvasRoute.resolve(.init(session: session)) == .standaloneDiff)
            #expect(session.windowTitle.hasPrefix(diff.title))
            #expect(session.openDocuments.count == 3)

            // Selecting a file hides the diff; it keeps the diff and its tab.
            session.selectEditorTab(fileTabID, in: groupID)
            #expect(session.selectedAuxiliaryTab == nil)
            #expect(session.selectedDocument === selected)
            #expect(session.gitOpenDiff?.id == diff.id)
            #expect(session.auxiliaryTabs == [diffTab])
            #expect(EditorCanvasRoute.resolve(.init(session: session)) == .editor)

            session.selectAuxiliaryTab(diffTab)
            #expect(session.selectedAuxiliaryTab == diffTab)
            session.requestCloseActiveTab()
            #expect(session.gitOpenDiff == nil)
            #expect(session.auxiliaryTabs.isEmpty)
            #expect(!session.isGitDiffSelected)
            #expect(session.selectedDocument === selected)
            #expect(session.editorLayout.group(id: groupID)?.tabs == fileTabs)
            #expect(session.pendingCloseDocument == nil)
        }
    }

    @Test("A Git diff tab closes back to its own split's selection")
    func gitDiffCloseReturnsToItsGroup() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            let firstDocument = try #require(session.selectedDocument)
            let firstGroup = session.editorLayout.focusedGroupID
            let firstTab = try #require(session.editorLayout.group(id: firstGroup)?.selectedTabID)
            session.newUntitledDocument()
            let secondTab = try #require(session.editorLayout.group(id: firstGroup)?.selectedTabID)
            session.splitEditorTab(secondTab, at: .trailing)
            let secondGroup = session.editorLayout.focusedGroupID
            session.selectEditorTab(firstTab, in: firstGroup)
            let diff = openDiff("README.md")
            let diffTab = WorkspaceAuxiliaryTab.gitDiff(GitDiffTabReference(diff))
            session.presentGitDiff(diff)
            #expect(session.auxiliaryTabs(in: firstGroup) == [diffTab])
            #expect(session.auxiliaryTabs(in: secondGroup).isEmpty)
            session.selectEditorTab(secondTab, in: secondGroup)
            session.selectAuxiliaryTab(diffTab)
            #expect(session.editorLayout.focusedGroupID == firstGroup)
            session.closeAuxiliaryTab(diffTab)
            #expect(session.selectedDocument === firstDocument)
            #expect(session.editorLayout.focusedGroupID == firstGroup)
            #expect(session.editorLayout.group(id: secondGroup)?.selectedTabID == secondTab)
            #expect(session.gitOpenDiff == nil)
            #expect(session.auxiliaryTabs.isEmpty)
        }
    }

    @Test("One diff tab per window; a reload or Settings keeps it")
    func gitDiffReplacementAndPeers() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            let first = openDiff("a.swift")
            let second = openDiff("b.swift")
            session.presentGitDiff(first)
            session.presentGitDiff(second)
            #expect(session.auxiliaryTabs == [.gitDiff(GitDiffTabReference(second))])
            #expect(session.auxiliaryTabGroups.count == 1)
            // A hunk reload keeps the identity and therefore the same tab.
            session.gitOpenDiff = openDiff("b.swift")
            #expect(session.auxiliaryTabs == [.gitDiff(GitDiffTabReference(second))])
            #expect(session.selectedAuxiliaryTab == .gitDiff(GitDiffTabReference(second)))

            session.showSettings()
            #expect(session.selectedAuxiliaryTab == .settings)
            #expect(session.gitOpenDiff?.id == second.id)
            #expect(session.auxiliaryTabs.contains(.gitDiff(GitDiffTabReference(second))))
            session.selectAuxiliaryTab(.gitDiff(GitDiffTabReference(second)))
            #expect(session.selectedAuxiliaryTab == .gitDiff(GitDiffTabReference(second)))
            #expect(!session.settingsVisible)
            #expect(session.auxiliaryTabs.contains(.settings))

            // Every other path that drops the diff also drops its tab.
            session.gitOpenDiff = nil
            #expect(session.auxiliaryTabs == [.settings])
            #expect(!session.isGitDiffSelected)
        }
    }

    @Test("A Git diff tab never enters the restorable layout")
    func gitDiffTabIsEphemeral() async throws {
        try await withWorkspace { session in
            session.newUntitledDocument()
            let before = try JSONEncoder().encode(
                EditorLayoutRestoration(layout: session.editorLayout))
            session.presentGitDiff(openDiff("README.md"))
            let after = try JSONEncoder().encode(
                EditorLayoutRestoration(layout: session.editorLayout))
            let beforeObject = try JSONSerialization.jsonObject(with: before) as? NSDictionary
            let afterObject = try JSONSerialization.jsonObject(with: after) as? NSDictionary
            #expect(beforeObject == afterObject)
            #expect(
                session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.count == 1
            )
        }
    }

    @Test("The editor canvas keeps the layout tree for a diff")
    func diffNeverReplacesTheLayoutTree() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(
            atPath: directory.appending(path: "Package.swift").path)
        {
            try #require(directory.path != "/")
            directory = directory.deletingLastPathComponent()
        }
        let source = try String(
            contentsOf: directory.appending(path: "Sources/RafuApp/Views/EditorCanvasView.swift"),
            encoding: .utf8)
        #expect(!source.contains("GitStandaloneDiffCanvas"))
        #expect(source.contains("case .settings, .standaloneDiff:\n            return .editor"))
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
