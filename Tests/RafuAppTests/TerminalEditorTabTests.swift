import Foundation
import Testing

@testable import RafuApp

/// Issue #4: the terminal presents as an ordinary editor tab. These tests
/// exercise `WorkspaceSession`'s tab-layout side of that contract — session
/// lifecycle (process spawn/teardown) is `WorkspaceTerminalManager`'s job and
/// stays untouched by `newTerminalTab()`/`closeTerminalTab(_:)` beyond
/// creating/removing the `WorkspaceTerminalController` record itself, which
/// is safe to exercise in a unit test: the underlying shell process spawns
/// lazily only when an AppKit `LocalProcessTerminalView` actually mounts
/// (`WorkspaceTerminalController.makeOrReuseView`), never from these
/// session-level calls.
@MainActor
@Test("New terminal tab inserts and selects a .terminal tab, same as a file tab")
func newTerminalTabOpensAndSelectsEditorTab() throws {
    let session = WorkspaceSession()
    #expect(!session.hasAnyEditorTabs)

    session.newTerminalTab()

    #expect(session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)
    let controller = try #require(session.terminal.sessions.first)
    let group = session.editorLayout.group(id: session.editorLayout.focusedGroupID)
    let tab = try #require(group?.tabs.first)
    guard case .terminal(let sessionID) = tab.resource else {
        Issue.record("Expected the inserted tab to be a .terminal resource")
        return
    }
    #expect(sessionID == controller.id)
    #expect(group?.selectedTabID == tab.id)
    // A terminal tab carries no document/file selection.
    #expect(session.selectedDocumentID == nil)
}

@MainActor
@Test("Closing a terminal tab removes it from the layout AND terminates its session")
func closingTerminalTabRemovesLayoutAndSession() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let tab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first)

    session.closeTerminalTab(tab.id)

    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.isEmpty)
}

@MainActor
@Test("closeTerminalTab is a no-op for a tab that is not a terminal")
func closeTerminalTabIgnoresNonTerminalTab() throws {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/a.swift")
    let document = EditorDocument(url: url)
    session.openDocuments = [document]
    session.editorLayout.insert(
        EditorTabState(resource: .file(url)), in: session.editorLayout.focusedGroupID)
    let fileTab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first)

    session.closeTerminalTab(fileTab.id)

    #expect(session.hasAnyEditorTabs)
}

@MainActor
@Test("Toggle Terminal opens a new tab, then closes the focused terminal tab it opened")
func toggleTerminalOpensThenClosesFocusedTerminalTab() {
    let session = WorkspaceSession()

    session.toggleTerminal()
    #expect(session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)

    session.toggleTerminal()
    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.isEmpty)
}

@MainActor
@Test("Toggle Terminal opens a second tab when a file tab (not a terminal) is focused")
func toggleTerminalOpensNewTabWhenNonTerminalIsSelected() {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/a.swift")
    session.openDocuments = [EditorDocument(url: url)]
    session.editorLayout.insert(
        EditorTabState(resource: .file(url)), in: session.editorLayout.focusedGroupID)

    session.toggleTerminal()

    let group = session.editorLayout.group(id: session.editorLayout.focusedGroupID)
    #expect(group?.tabs.count == 2)
    #expect(session.terminal.sessions.count == 1)
}

@MainActor
@Test("Full-file blame annotations toggle is off by default and flips independently")
func fileBlameAnnotationsToggleIsIndependent() {
    let session = WorkspaceSession()
    #expect(!session.isFileBlameAnnotationsEnabled)
    #expect(!session.isInlineBlameEnabled)

    session.toggleFileBlameAnnotations()
    #expect(session.isFileBlameAnnotationsEnabled)
    #expect(!session.isInlineBlameEnabled)

    session.toggleInlineBlame()
    #expect(session.isFileBlameAnnotationsEnabled)
    #expect(session.isInlineBlameEnabled)

    session.toggleFileBlameAnnotations()
    #expect(!session.isFileBlameAnnotationsEnabled)
    #expect(session.isInlineBlameEnabled)
}
