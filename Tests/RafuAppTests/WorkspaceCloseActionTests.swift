import AppKit
import Foundation
import Testing

@testable import RafuApp

/// Regression for "Cmd+W over an empty focused window quits every open
/// workspace window": `requestCloseActiveTab()` must resolve the FOCUSED
/// group's selected tab first (file, terminal, or restorable placeholder —
/// mirroring the tab strip's own close semantics), then an editor-hosted Git
/// diff, and only fall back to the empty-window branch when truly nothing is
/// open. That branch must close only the current window when other
/// workspace windows remain, and preserve the existing last-window
/// quit-confirmation UX otherwise — verified here via the pure
/// `WorkspaceSession.resolveEmptyWindowCloseAction` decision rather than by
/// driving a real `NSWindow.performClose`, which crashed intermittently
/// under swift-testing's parallel test execution in this environment.
@MainActor
private func makeTestWindow() -> NSWindow {
    NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
}

@MainActor
@Test("A selected clean file tab closes the document, never quits")
func fileTabClosesDocument() throws {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/a.swift")
    let document = EditorDocument(url: url)
    session.openDocuments = [document]
    session.editorLayout.insert(
        EditorTabState(resource: .file(url)), in: session.editorLayout.focusedGroupID)

    session.requestCloseActiveTab()

    #expect(session.openDocuments.isEmpty)
    #expect(!session.hasAnyEditorTabs)
    #expect(!session.isQuitConfirmationPresented)
}

@MainActor
@Test("A selected dirty file tab opens the save confirmation instead of closing outright")
func dirtyFileTabDefersToSaveConfirmation() throws {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/a.swift")
    let document = EditorDocument(url: url)
    document.isDirty = true
    session.openDocuments = [document]
    session.editorLayout.insert(
        EditorTabState(resource: .file(url)), in: session.editorLayout.focusedGroupID)

    session.requestCloseActiveTab()

    #expect(session.pendingCloseDocument === document)
    #expect(session.hasAnyEditorTabs)
    #expect(!session.isQuitConfirmationPresented)
}

@MainActor
@Test("A selected terminal-only tab closes the tab and terminates its session")
func terminalOnlyTabClosesAndTerminatesSession() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()

    session.requestCloseActiveTab()

    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.isEmpty)
    #expect(!session.isQuitConfirmationPresented)
}

@MainActor
@Test("A selected restorable placeholder tab is removed")
func restorableTabIsRemoved() throws {
    let session = WorkspaceSession()
    session.editorLayout.insert(
        EditorTabState(resource: .restorable(kind: "search", key: "k", title: "Search")),
        in: session.editorLayout.focusedGroupID)
    #expect(session.hasAnyEditorTabs)

    session.requestCloseActiveTab()

    #expect(!session.hasAnyEditorTabs)
    #expect(!session.isQuitConfirmationPresented)
}

@MainActor
@Test(
    "Empty-window resolver closes only this window when other workspace windows remain open",
    arguments: [true, false]
)
func emptyWindowResolverClosesWindowWhenOthersRemain(
    quitWithoutEmptyWindowConfirmation: Bool
) {
    let action = WorkspaceSession.resolveEmptyWindowCloseAction(
        hasOtherWorkspaceWindows: true,
        quitWithoutEmptyWindowConfirmation: quitWithoutEmptyWindowConfirmation
    )
    #expect(action == .closeWindow)
}

@MainActor
@Test("Empty-window resolver falls back to quit UX for the last remaining window")
func emptyWindowResolverFallsBackToQuitUXForLastWindow() {
    #expect(
        WorkspaceSession.resolveEmptyWindowCloseAction(
            hasOtherWorkspaceWindows: false,
            quitWithoutEmptyWindowConfirmation: false
        ) == .presentQuitConfirmation)
    #expect(
        WorkspaceSession.resolveEmptyWindowCloseAction(
            hasOtherWorkspaceWindows: false,
            quitWithoutEmptyWindowConfirmation: true
        ) == .quitWithoutConfirmation)
}

@MainActor
@Test("liveWorkspaceWindowCount reflects registered sessions and prunes on deregister")
func liveWorkspaceWindowCountTracksRegisteredSessions() {
    let sessionA = WorkspaceSession()
    let sessionB = WorkspaceSession()
    let windowA = makeTestWindow()
    let windowB = makeTestWindow()
    defer {
        WorkspaceWindowRegistry.shared.deregister(session: sessionA)
        WorkspaceWindowRegistry.shared.deregister(session: sessionB)
    }

    WorkspaceWindowRegistry.shared.register(session: sessionA, window: windowA, rootURL: { nil })
    WorkspaceWindowRegistry.shared.register(session: sessionB, window: windowB, rootURL: { nil })
    #expect(WorkspaceWindowRegistry.shared.liveWorkspaceWindowCount() == 2)

    WorkspaceWindowRegistry.shared.deregister(session: sessionB)
    #expect(WorkspaceWindowRegistry.shared.liveWorkspaceWindowCount() == 1)
}
