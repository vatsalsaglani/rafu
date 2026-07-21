import Darwin
import Foundation
import Testing

@testable import RafuApp

/// Issue #4 / terminal-manager.md T-A: the terminal presents as an ordinary
/// editor tab, and hiding a tab is a different verb from closing it —
/// hiding parks the session (alive in `WorkspaceTerminalManager`, no
/// `.terminal` tab in the layout); closing terminates it. Session lifecycle
/// (process spawn/teardown) is `WorkspaceTerminalManager`'s job and stays
/// untouched by these session-level layout calls beyond
/// creating/removing/parking the `WorkspaceTerminalController` record
/// itself, which is safe to exercise in a unit test: the underlying shell
/// process spawns lazily only when an AppKit `LocalProcessTerminalView`
/// actually mounts (`WorkspaceTerminalController.makeOrReuseView`), never
/// from these session-level calls.
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

// MARK: - A0-A3: toggle hides (parks) rather than closes

@MainActor
@Test("Toggle Terminal parks a selected terminal tab, then reveals the same session")
func toggleTerminalParksThenRevealsFocusedTerminalTab() throws {
    let session = WorkspaceSession()

    session.toggleTerminal()
    #expect(session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)
    let controller = try #require(session.terminal.sessions.first)

    // A1: toggling away parks — no `.terminal` tab in the layout, but the
    // session survives in the manager.
    session.toggleTerminal()
    #expect(!session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)
    #expect(session.parkedTerminalSessions.count == 1)
    #expect(session.parkedTerminalSessions.first?.id == controller.id)

    // A2: toggling again reveals the SAME session as a tab — no new one.
    session.toggleTerminal()
    #expect(session.hasAnyEditorTabs)
    #expect(session.terminal.sessions.count == 1)
    let group = session.editorLayout.group(id: session.editorLayout.focusedGroupID)
    guard case .terminal(let sessionID) = group?.tabs.first?.resource else {
        Issue.record("Expected the revealed tab to be a .terminal resource")
        return
    }
    #expect(sessionID == controller.id)
    #expect(session.parkedTerminalSessions.isEmpty)
}

@MainActor
@Test("Parked sessions surface in most-recently-parked-first order")
func parkedTerminalSessionsOrderByMostRecentlyParked() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let firstController = try #require(session.terminal.sessions.first)
    let firstTabID = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first?.id)

    // A second terminal tab opens in a new focused group's tab strip since
    // `newTerminalTab` always inserts+selects into the focused group — same
    // group here, so both live side by side until parked.
    session.newTerminalTab()
    let secondController = try #require(
        session.terminal.sessions.first { $0.id != firstController.id })
    let secondTab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs
            .first { $0.resource == .terminal(sessionID: secondController.id) })

    // Park the first-created session, then the second — MRU order should
    // list the second (parked last) first. Asserted directly on the derived
    // ordering rather than by driving reveals (deterministic).
    session.hideTerminalTab(firstTabID)
    session.hideTerminalTab(secondTab.id)

    let ids = session.parkedTerminalSessions.map(\.id)
    #expect(ids == [secondController.id, firstController.id])
}

@MainActor
@Test("hideTerminalTab is a no-op for a tab that is not a terminal")
func hideTerminalTabIgnoresNonTerminalTab() throws {
    let session = WorkspaceSession()
    let url = URL(fileURLWithPath: "/tmp/a.swift")
    session.openDocuments = [EditorDocument(url: url)]
    session.editorLayout.insert(
        EditorTabState(resource: .file(url)), in: session.editorLayout.focusedGroupID)
    let fileTab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first)

    session.hideTerminalTab(fileTab.id)

    #expect(session.hasAnyEditorTabs)
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

// MARK: - A6: manager-level shutdown

@MainActor
@Test("shutdownAll clears every session and resets selection")
func shutdownAllClearsSessionsAndSelection() {
    // Exercises `WorkspaceTerminalManager` directly rather than going
    // through `WorkspaceSession.openWorkspace(_:)` (the production caller,
    // `WorkspaceSession.swift`'s workspace-open path) since that does file
    // I/O and starts an FSEvents watcher — out of scope for a unit test.
    let manager = WorkspaceTerminalManager()
    let defaultShell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    manager.newSession(startingDirectory: "/tmp", shell: defaultShell)
    manager.newSession(startingDirectory: "/tmp", shell: defaultShell)
    #expect(manager.sessions.count == 2)

    manager.shutdownAll()

    #expect(manager.sessions.isEmpty)
    #expect(manager.selectedID == nil)
}

// MARK: - A8-A9: natural exit lingers, releases the view, unregisters

@MainActor
@Test("A shell that exits naturally lingers as .exited with its tab kept")
func naturalExitLingersAsExitedAndKeepsTab() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let tab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first)

    controller.processDidTerminate(exitCode: 3)

    #expect(controller.status == .exited(code: 3))
    #expect(!controller.isRunning)
    // Coordinator decision: keep the tab AND the session.
    #expect(session.terminal.sessions.contains { $0.id == controller.id })
    #expect(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs
            .contains { $0.id == tab.id } == true)
}

@MainActor
@Test("Natural exit unregisters the session from ProcessResourceRegistry")
func naturalExitUnregistersFromProcessResourceRegistry() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    await ProcessResourceRegistry.shared.register(
        id: controller.id, name: "Terminal test", kind: .terminalShell, pid: getpid())
    let beforeExit = await ProcessResourceRegistry.shared.sample()
    #expect(beforeExit.contains { $0.id == controller.id })

    controller.processDidTerminate(exitCode: nil)

    // `processDidTerminate` unregisters via its own detached `Task`, not
    // synchronously — poll cooperatively (never a fixed sleep) until the
    // registry actor has processed it.
    var unregistered = false
    for _ in 0..<20_000 {
        let samples = await ProcessResourceRegistry.shared.sample()
        if !samples.contains(where: { $0.id == controller.id }) {
            unregistered = true
            break
        }
        await Task.yield()
    }
    #expect(unregistered)
}

// MARK: - A10-A11: session-level close/reveal (parked/exited sessions, T-B panel)

@MainActor
@Test("closeTerminalSession removes a parked session; no-op for an unknown id")
func closeTerminalSessionRemovesParkedSessionOrNoOps() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let tab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first)
    session.hideTerminalTab(tab.id)
    #expect(session.parkedTerminalSessions.count == 1)

    session.closeTerminalSession(controller.id)

    #expect(session.terminal.sessions.isEmpty)
    #expect(session.parkedTerminalSessions.isEmpty)

    // No-op for an id that was never a session.
    session.closeTerminalSession(UUID())
}

@MainActor
@Test("revealTerminalSession on an already-presented session selects it without duplicating")
func revealTerminalSessionSelectsExistingTabWithoutDuplicating() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let url = URL(fileURLWithPath: "/tmp/a.swift")
    session.openDocuments = [EditorDocument(url: url)]
    session.editorLayout.insert(
        EditorTabState(resource: .file(url)), in: session.editorLayout.focusedGroupID)
    #expect(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.count == 2)

    session.revealTerminalSession(controller.id)

    let group = session.editorLayout.group(id: session.editorLayout.focusedGroupID)
    #expect(group?.tabs.count == 2)
    #expect(session.terminal.sessions.count == 1)
    let selectedTab = group?.tabs.first(where: { $0.id == group?.selectedTabID })
    guard case .terminal(let sessionID) = selectedTab?.resource else {
        Issue.record("Expected the selected tab to be the revealed terminal")
        return
    }
    #expect(sessionID == controller.id)

    // terminal-manager.md T-B: the panel's `isParked` derivation must agree
    // — a session already presented as a tab is never parked, reveal or not.
    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )
    #expect(rows.first { $0.id == controller.id }?.isParked == false)
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
