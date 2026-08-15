import Foundation
import Testing

@testable import RafuApp

@Test("A prepared close is nonmutating and a stale close token has no effect")
func terminalGroupClosePreparationIsGenerationChecked() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let paneID = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    let effect = try runtime.perform(.prepareClose(.pane(paneID)))
    guard case .requestCloseConfirmation(let token) = effect else {
        Issue.record("Expected a close confirmation token")
        return
    }
    #expect(runtime.snapshot(groupID: groupID)?.panes.count == 1)

    _ = try runtime.perform(
        .renameGroup(groupID: groupID, name: try #require(TerminalGroupName("Changed"))))
    #expect(throws: TerminalGroupValidationError.staleCloseToken) {
        try runtime.perform(.finalizeClose(token))
    }
    #expect(runtime.snapshot(groupID: groupID)?.panes.count == 1)
}

@Test("Closing a pane collapses a split and closing its last leaf removes the group")
func terminalGroupCloseCollapsesTreeAndRemovesRoot() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let first = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let second = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)

    let firstToken = try closeToken(runtime.perform(.prepareClose(.pane(first))))
    _ = try runtime.perform(.finalizeClose(firstToken))
    #expect(runtime.snapshot(groupID: groupID)?.root == .pane(second))

    let secondToken = try closeToken(runtime.perform(.prepareClose(.pane(second))))
    #expect(try runtime.perform(.finalizeClose(secondToken)) == .removeEditorTab(groupID: groupID))
    #expect(runtime.snapshot(groupID: groupID) == nil)
}

@Test("Group park order is most-recent-first and shutdown clears runtime state")
func terminalGroupParkOrderAndShutdown() throws {
    var runtime = TerminalGroupRuntime()
    let first = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let second = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    _ = try runtime.perform(.parkGroup(first))
    _ = try runtime.perform(.parkGroup(second))
    #expect(runtime.parkedGroupIDs == [second, first])
    runtime.shutdown()
    #expect(runtime.snapshots.isEmpty)
    #expect(runtime.parkedGroupIDs.isEmpty)
}

private func closeToken(_ effect: TerminalGroupEffect) throws -> TerminalGroupCloseToken {
    guard case .requestCloseConfirmation(let token) = effect else {
        throw TerminalGroupValidationError.staleCloseToken
    }
    return token
}

@MainActor
@Test("Saved layouts insert inert stopped and unavailable runtime panes")
func terminalGroupSavedLayoutInsertionIsInert() throws {
    let manager = WorkspaceTerminalManager()
    let ordinaryID = SavedTerminalPaneID()
    let unavailableID = SavedTerminalPaneID()
    let ordinary = try SavedTerminalPaneRecord(
        id: ordinaryID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
        launchProfile: TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root))
    let unavailable = try SavedTerminalPaneRecord(
        id: unavailableID, explicitUserName: nil, themeColor: nil, kind: .unavailableAgentTerminal,
        launchProfile: nil)
    let record = try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Saved")),
        root: .split(
            id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
            first: .pane(ordinaryID), second: .pane(unavailableID)),
        focusedPaneID: ordinaryID, panes: [ordinary, unavailable])

    let group = try manager.insertStoppedSavedGroup(record)
    #expect(manager.sessions.isEmpty)
    #expect(group.panes.map(\.status).contains(.stopped))
    #expect(group.panes.map(\.status).contains(.unavailable))
    #expect(group.panes.allSatisfy { $0.sessionID == nil })
}

@MainActor
@Test("A grouped controller exits, restarts with its same session, and closes once")
func terminalGroupControllerLifecycleKeepsMembershipStable() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let group = try manager.createLiveGroup(instantiation: instantiation)
    let pane = try #require(group.panes.first)
    let controller = try #require(manager.terminalController(for: pane.id))
    #expect(manager.terminalController(sessionID: controller.id) === controller)

    controller.processDidTerminate(exitCode: 0)
    #expect(manager.terminalGroup(group.id)?.panes.first?.status == .exited)
    try manager.restartExitedPane(pane.id)
    #expect(manager.terminalController(for: pane.id) === controller)
    #expect(manager.terminalGroup(group.id)?.panes.first?.status == .live)

    let token = try closeToken(manager.perform(.prepareClose(.group(group.id))))
    #expect(token.liveProcessCount == 0)
    _ = try manager.perform(.finalizeClose(token))
    #expect(manager.terminalGroup(group.id) == nil)
    #expect(manager.sessions.isEmpty)
}
