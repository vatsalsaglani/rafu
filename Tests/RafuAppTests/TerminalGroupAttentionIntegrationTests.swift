import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Test("Terminal Group focus clears only the focused child attention")
func workspaceSessionClearsOnlyFocusedTerminalGroupAttention() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let first = try #require(session.focusedTerminalPaneID)
    session.splitFocusedTerminalPane(.right)
    let second = try #require(session.focusedTerminalPaneID)
    let firstController = try #require(session.terminal.terminalController(for: first))
    let secondController = try #require(session.terminal.terminalController(for: second))
    firstController.markRunningForTesting()
    secondController.markRunningForTesting()
    firstController.noteBell()
    secondController.noteBell()

    #expect(firstController.status == .bell)
    #expect(secondController.status == .bell)
    session.focusTerminalPane(second, in: groupID)
    #expect(secondController.status == .running)
    #expect(firstController.status == .bell)
    #expect(session.focusedTerminalSession?.id == secondController.id)
}

@MainActor
@Test("A selected group routes session focus to its runtime pane")
func workspaceSessionGroupFocusRoutesToSelectedPane() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    session.splitFocusedTerminalPane(.down)
    let focused = try #require(session.focusedTerminalPaneID)
    let controller = try #require(session.terminal.terminalController(for: focused))

    #expect(session.focusedTerminalSession?.id == controller.id)
    #expect(session.presentedTerminalSessionIDs.contains(controller.id))
    #expect(
        session.editorTabSwitcherCandidates.filter {
            $0.destination == .terminalGroup(groupID: groupID)
        }.count == 1)
}
