import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Test("Terminal Group presentation requests are window-scoped and cancel cleanly")
func terminalGroupPresentationRequestsAreWindowScoped() throws {
    let first = WorkspaceSession()
    let second = WorkspaceSession()
    first.newTerminalGroup()
    second.newTerminalGroup()
    let firstID = try #require(first.selectedTerminalGroupID)

    first.requestTerminalGroupRename(firstID)
    #expect(first.pendingTerminalGroupRenameRequest?.id == firstID)
    #expect(second.pendingTerminalGroupRenameRequest == nil)
    #expect(first.isTerminalGroupModalInputBlocked)
    first.cancelPendingTerminalGroupRename()
    #expect(first.pendingTerminalGroupRenameRequest == nil)
    #expect(!first.isTerminalGroupModalInputBlocked)
}

@MainActor
@Test("Terminal Group rename request completes through the existing workspace route")
func terminalGroupRenameRequestCompletes() throws {
    let session = WorkspaceSession()
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    session.requestTerminalGroupRename(groupID)
    session.updatePendingTerminalGroupRename("Build logs")
    session.completePendingTerminalGroupRename()
    #expect(session.pendingTerminalGroupRenameRequest == nil)
    #expect(session.terminal.terminalGroup(groupID)?.name.rawValue == "Build logs")
}

@MainActor
@Test("Terminal Group folder request blocks other group commands until cancellation")
func terminalPaneFolderRequestBlocksCommands() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let paneID = try #require(session.focusedTerminalPaneID)
    session.requestTerminalPaneStartingFolder(paneID)
    #expect(session.pendingTerminalPaneStartingFolderRequest?.id == paneID)
    #expect(session.isTerminalGroupModalInputBlocked)
    session.requestTerminalGroupSaveAs(try #require(session.selectedTerminalGroupID))
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    session.cancelPendingTerminalPaneStartingFolder()
    #expect(session.pendingTerminalPaneStartingFolderRequest == nil)
}

@MainActor
@Test("Terminal Group folder request completes through existing validation")
func terminalPaneFolderRequestCompletes() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RafuTG41Folder.\(UUID().uuidString)", isDirectory: true)
    let child = root.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: "TG-41", location: .local(LocalWorkspaceReference(path: root.path)))
    session.newTerminalGroup()
    let paneID = try #require(session.focusedTerminalPaneID)
    session.requestTerminalPaneStartingFolder(paneID)
    session.completePendingTerminalPaneStartingFolder(child)
    #expect(session.pendingTerminalPaneStartingFolderRequest == nil)
    let groupID = try #require(session.selectedTerminalGroupID)
    #expect(
        session.terminal.terminalGroup(groupID)?.panes
            .first(where: { $0.id == paneID })?.launchProfile?.startingFolder.rawValue == "child")
}

@MainActor
private func assertModalBlocksTerminalGroupCommands(
    _ session: WorkspaceSession, groupID: TerminalGroupID
) {
    let before = session.terminal.terminalGroup(groupID)
    let presented = session.presentedTerminalGroupIDs
    session.toggleTerminal()
    session.newTerminalGroup()
    session.splitFocusedTerminalPane(.right)
    session.splitFocusedTerminalPane(.down)
    session.focusTerminalPane(.left)
    session.requestTerminalGroupSave(groupID)
    session.requestTerminalGroupSaveAs(groupID)
    if let paneID = session.focusedTerminalPaneID { session.closeTerminalPane(paneID) }
    session.requestTerminalGroupClose(groupID)
    session.requestCloseActiveTab()
    #expect(session.terminal.terminalGroup(groupID) == before)
    #expect(session.presentedTerminalGroupIDs == presented)
    #expect(session.terminal.terminalGroups.count == 1)
}

@MainActor
@Test("Each Terminal Group modal owner blocks all group command routes")
func terminalGroupModalOwnersBlockCommands() throws {
    let (saveSession, saveRoot) = try makeTerminalGroupWorkspace()
    defer {
        saveSession.teardownTerminalGroups()
        removeTerminalGroupWorkspace(saveRoot)
    }
    saveSession.newTerminalGroup()
    let saveID = try #require(saveSession.selectedTerminalGroupID)
    saveSession.requestTerminalGroupSaveAs(saveID)
    assertModalBlocksTerminalGroupCommands(saveSession, groupID: saveID)
    #expect(saveSession.pendingTerminalGroupSaveRequest?.id == saveID)

    let (renameSession, renameRoot) = try makeTerminalGroupWorkspace()
    defer {
        renameSession.teardownTerminalGroups()
        removeTerminalGroupWorkspace(renameRoot)
    }
    renameSession.newTerminalGroup()
    let renameID = try #require(renameSession.selectedTerminalGroupID)
    renameSession.requestTerminalGroupRename(renameID)
    assertModalBlocksTerminalGroupCommands(renameSession, groupID: renameID)
    #expect(renameSession.pendingTerminalGroupRenameRequest?.id == renameID)

    let (folderSession, folderRoot) = try makeTerminalGroupWorkspace()
    defer {
        folderSession.teardownTerminalGroups()
        removeTerminalGroupWorkspace(folderRoot)
    }
    folderSession.newTerminalGroup()
    let folderID = try #require(folderSession.selectedTerminalGroupID)
    folderSession.requestTerminalPaneStartingFolder(
        try #require(folderSession.focusedTerminalPaneID))
    assertModalBlocksTerminalGroupCommands(folderSession, groupID: folderID)
    #expect(folderSession.pendingTerminalPaneStartingFolderRequest != nil)

    let (closeSession, closeRoot) = try makeTerminalGroupWorkspace()
    defer {
        closeSession.teardownTerminalGroups()
        removeTerminalGroupWorkspace(closeRoot)
    }
    closeSession.newTerminalGroup()
    let closeID = try #require(closeSession.selectedTerminalGroupID)
    let closePane = try #require(closeSession.focusedTerminalPaneID)
    closeSession.terminal.terminalController(for: closePane)?.markRunningForTesting()
    closeSession.requestTerminalGroupClose(closeID)
    let token = try #require(closeSession.pendingTerminalGroupClose)
    assertModalBlocksTerminalGroupCommands(closeSession, groupID: closeID)
    #expect(closeSession.pendingTerminalGroupClose == token)
}

@MainActor
@Test("Terminal Group action availability reports outer edges and no group")
func terminalGroupActionAvailabilityReportsEdges() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    #expect(
        session.terminalGroupPresentationAvailability(.save).reason == "Select a Terminal Group.")
    session.newTerminalGroup()
    for direction in [TerminalPaneFocusDirection.left, .right, .up, .down] {
        #expect(session.terminalGroupPresentationAvailability(.focus(direction)).isEnabled == false)
        #expect(
            session.terminalGroupPresentationAvailability(.focus(direction)).reason
                == "No Terminal Pane exists in that direction.")
    }
    #expect(
        session.terminalGroupPresentationAvailability(.startPane).reason
            == "Select a stopped ordinary-shell pane with a safe profile.")

    session.splitFocusedTerminalPane(.right)
    #expect(session.terminalGroupPresentationAvailability(.focus(.left)).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.focus(.right)).isEnabled == false)
    session.splitFocusedTerminalPane(.down)
    #expect(session.terminalGroupPresentationAvailability(.focus(.up)).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.focus(.down)).isEnabled == false)
}

@MainActor
@Test("Live and parked Terminal Group availability stays action-specific")
func terminalGroupLiveAndParkedAvailability() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    #expect(session.terminalGroupPresentationAvailability(.hide).isEnabled)
    #expect(
        session.terminalGroupPresentationAvailability(.startPane).reason
            == "Select a stopped ordinary-shell pane with a safe profile.")
    session.hideTerminalGroup(groupID)
    #expect(
        session.terminalGroupPresentationAvailability(.hide).reason == "Select a Terminal Group.")
}

@MainActor
private func insertAvailabilitySnapshot(
    _ session: WorkspaceSession, pane: TerminalPaneSnapshot
) throws -> TerminalGroupID {
    let groupID = TerminalGroupID()
    let snapshot = try TerminalGroupSnapshot(
        id: groupID, name: try #require(TerminalGroupName("Availability")), root: .pane(pane.id),
        focusedPaneID: pane.id, savedLayoutID: nil, panes: [pane], retainedPaneCount: 1)
    _ = try session.terminal.insertInertSnapshot(snapshot)
    session.revealTerminalGroup(groupID)
    return groupID
}

@MainActor
@Test("Inert ordinary-shell availability enables safe start and folder actions")
func stoppedAndExitedShellAvailability() throws {
    let (stopped, stoppedRoot) = try makeTerminalGroupWorkspace()
    defer {
        stopped.teardownTerminalGroups()
        removeTerminalGroupWorkspace(stoppedRoot)
    }
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let pane = try TerminalPaneSnapshot(
        id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped, launchProfile: profile,
        startAvailability: .available)
    _ = try insertAvailabilitySnapshot(stopped, pane: pane)
    #expect(stopped.terminalGroupPresentationAvailability(.setFolder).isEnabled)
    #expect(stopped.terminalGroupPresentationAvailability(.startPane).isEnabled)
    #expect(stopped.terminalGroupPresentationAvailability(.startAll).isEnabled)
}

@MainActor
@Test("Unavailable saved panes retain their fixed folder reasons")
func unavailableSavedPaneFolderReasons() throws {
    let (agent, agentRoot) = try makeTerminalGroupWorkspace()
    let (ensemble, ensembleRoot) = try makeTerminalGroupWorkspace()
    defer {
        agent.teardownTerminalGroups()
        ensemble.teardownTerminalGroups()
        removeTerminalGroupWorkspace(agentRoot)
        removeTerminalGroupWorkspace(ensembleRoot)
    }
    let agentPane = try TerminalPaneSnapshot(
        id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .unavailableAgentTerminal, themeColor: nil, status: .unavailable,
        launchProfile: nil, startAvailability: .unavailable)
    let ensemblePane = try TerminalPaneSnapshot(
        id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .unavailableEnsemble, themeColor: nil, status: .unavailable,
        launchProfile: nil, startAvailability: .unavailable)
    _ = try insertAvailabilitySnapshot(agent, pane: agentPane)
    _ = try insertAvailabilitySnapshot(ensemble, pane: ensemblePane)
    #expect(
        agent.terminalGroupPresentationAvailability(.setFolder).reason
            == "Agent Terminal profiles are not saved in this version.")
    #expect(
        ensemble.terminalGroupPresentationAvailability(.setFolder).reason
            == "Ensemble terminal profiles are not saved in this version.")
}

@MainActor
@Test("Exited ordinary shell is not a Start All target")
func exitedShellDisablesStartAll() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let paneID = try #require(session.focusedTerminalPaneID)
    session.terminal.terminalController(for: paneID)?.markRunningForTesting()
    session.terminal.terminalController(for: paneID)?.processDidTerminate(exitCode: 0)
    #expect(
        session.terminalGroupPresentationAvailability(.startAll).reason
            == "No restartable Terminal Panes are available.")
}

@MainActor
@Test("Live classified panes report their exact folder restrictions")
func liveClassifiedPaneFolderReasons() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
        currentDirectoryPath: root.path, environment: [:], roleBadge: "Agent", agentProvider: .codex
    )
    _ = try session.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) {}
    #expect(
        session.terminalGroupPresentationAvailability(.setFolder).reason
            == "Agent Terminal panes cannot set a saved starting folder.")
    #expect(session.terminalGroupPresentationAvailability(.splitRight).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.splitDown).isEnabled)
    session.splitFocusedTerminalPane(.right)
    let groupID = try #require(session.selectedTerminalGroupID)
    let group = try #require(session.terminal.terminalGroup(groupID))
    let newPane = try #require(group.panes.first(where: { $0.id == session.focusedTerminalPaneID }))
    #expect(newPane.runtimeKind == .ordinaryShell)
    #expect(newPane.launchProfile?.startingFolder == .root)

    let role = session.terminal.newSession(
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: root.path, environment: [:], roleBadge: "Implementor",
            outputLogURL: URL(fileURLWithPath: "/tmp/tg41-role.log")))
    let roleGroup = try session.terminal.adoptUngroupedSession(role.id)
    session.revealTerminalGroup(roleGroup.id)
    #expect(
        session.terminalGroupPresentationAvailability(.setFolder).reason
            == "Ensemble terminal panes cannot set a saved starting folder.")
    #expect(session.terminalGroupPresentationAvailability(.splitRight).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.splitDown).isEnabled)
    session.splitFocusedTerminalPane(.down)
    let ensembleFallback = try #require(
        session.terminal.terminalGroup(roleGroup.id)?.panes.first(where: {
            $0.id == session.focusedTerminalPaneID
        }))
    #expect(ensembleFallback.runtimeKind == .ordinaryShell)
    #expect(ensembleFallback.launchProfile?.startingFolder == .root)

    let coordinator = session.terminal.newSession(
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: root.path, environment: ["RAFU_ENSEMBLE_TOKEN": "opaque"],
            roleBadge: "Coordinator"))
    let coordinatorGroup = try session.terminal.adoptUngroupedSession(coordinator.id)
    session.revealTerminalGroup(coordinatorGroup.id)
    #expect(
        session.terminalGroupPresentationAvailability(.setFolder).reason
            == "Ensemble terminal panes cannot set a saved starting folder.")
}

@MainActor
@Test("Terminal pane folder picker seeds, accepts root, and cancels without mutation")
func terminalPaneFolderPickerSeedRootAndCancel() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    let child = root.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let paneID = try #require(session.focusedTerminalPaneID)
    session.setTerminalPaneStartingFolder(paneID, to: child)
    session.requestTerminalPaneStartingFolder(paneID)
    #expect(session.pendingTerminalPaneStartingFolderRequest?.initialDirectory == child)
    session.cancelPendingTerminalPaneStartingFolder()
    #expect(session.pendingTerminalPaneStartingFolderRequest == nil)
    session.requestTerminalPaneStartingFolder(paneID)
    session.completePendingTerminalPaneStartingFolder(root)
    let groupID = try #require(session.selectedTerminalGroupID)
    #expect(
        session.terminal.terminalGroup(groupID)?.panes.first?.launchProfile?.startingFolder == .root
    )
}

@MainActor
@Test("Terminal pane folder picker rejects outside and symlink escape selections")
func terminalPaneFolderPickerRejectsEscape() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
        "RafuTG41Outside.\(UUID().uuidString)", isDirectory: true)
    let link = root.appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
        try? FileManager.default.removeItem(at: outside)
    }
    session.newTerminalGroup()
    let paneID = try #require(session.focusedTerminalPaneID)
    let groupID = try #require(session.selectedTerminalGroupID)
    let before = try #require(session.terminal.terminalGroup(groupID))
    session.requestTerminalPaneStartingFolder(paneID)
    session.completePendingTerminalPaneStartingFolder(outside)
    #expect(session.pendingTerminalPaneStartingFolderRequest == nil)
    #expect(session.terminal.terminalGroup(groupID) == before)
    #expect(session.isOpenFolderErrorPresented)
    session.requestTerminalPaneStartingFolder(paneID)
    session.completePendingTerminalPaneStartingFolder(link)
    #expect(session.terminal.terminalGroup(groupID) == before)
    #expect(session.isOpenFolderErrorPresented)
}

@MainActor
@Test("Saved-layout mutation disables only Terminal Group save actions")
func terminalGroupSaveMutationAvailability() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    await store.suspendNextSave()
    let saveStarted = Task { await store.waitForSaveStart() }
    session.requestTerminalGroupSave(groupID)
    await saveStarted.value
    #expect(session.terminalGroupPresentationAvailability(.save).isEnabled == false)
    #expect(
        session.terminalGroupPresentationAvailability(.save).reason
            == "A Terminal Group save is in progress.")
    #expect(session.terminalGroupPresentationAvailability(.saveAs).isEnabled == false)
    #expect(
        session.terminalGroupPresentationAvailability(.saveAs).reason
            == "A Terminal Group save is in progress.")
    #expect(session.terminalGroupPresentationAvailability(.closeGroup).isEnabled)
    await store.releaseSave()
    await session.waitForTerminalGroupStoreOperationForTesting()
}

@MainActor
private func insertStoppedGroup(_ session: WorkspaceSession, panes count: Int) throws
    -> TerminalGroupID
{
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let panes = try (0..<count).map { _ in
        try TerminalPaneSnapshot(
            id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
            runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped, launchProfile: profile,
            startAvailability: .available)
    }
    var node = TerminalGroupNode.pane(panes[0].id)
    for pane in panes.dropFirst() {
        node = .split(
            id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5, first: node,
            second: .pane(pane.id))
    }
    let id = TerminalGroupID()
    _ = try session.terminal.insertInertSnapshot(
        TerminalGroupSnapshot(
            id: id,
            name: try #require(TerminalGroupName("Stopped \(id.rawValue.uuidString.prefix(4))")),
            root: node, focusedPaneID: panes[0].id, savedLayoutID: nil, panes: panes,
            retainedPaneCount: session.retainedTerminalPaneCount + count))
    return id
}

@MainActor
@Test("Ten-pane group disables both split directions")
func tenPaneGroupDisablesSplits() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    for _ in 0..<9 { session.splitFocusedTerminalPane(.right) }
    #expect(
        session.terminalGroupPresentationAvailability(.splitRight).reason
            == "This Terminal Group has reached its pane limit.")
    #expect(
        session.terminalGroupPresentationAvailability(.splitDown).reason
            == "This Terminal Group has reached its pane limit.")
}

@MainActor
@Test("Live Terminal capacity disables new and start actions")
func liveCapacityDisablesNewAndStartActions() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    for _ in 0..<9 { session.splitFocusedTerminalPane(.right) }
    let stopped = try insertStoppedGroup(session, panes: 1)
    session.revealTerminalGroup(stopped)
    #expect(session.terminalGroupPresentationAvailability(.newGroup).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.startPane).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.startAll).isEnabled)
}

@MainActor
@Test("Retained pane capacity disables new Terminal Group")
func retainedCapacityDisablesNewGroup() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    for _ in 0..<20 { _ = try insertStoppedGroup(session, panes: 10) }
    #expect(session.retainedTerminalPaneCount == 200)
    #expect(session.terminalGroupPresentationAvailability(.newGroup).isEnabled == false)
    #expect(
        session.terminalGroupPresentationAvailability(.newGroup).reason
            == "The window has reached its Terminal Group limit.")
}

@MainActor
@Test("Terminal Group contextual command availability preserves scope")
func terminalGroupContextualCommandAvailability() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    #expect(session.terminalGroupPresentationAvailability(.newGroup).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.splitRight).isEnabled == false)
    #expect(session.terminalGroupPresentationAvailability(.splitDown).isEnabled == false)
    #expect(session.terminalGroupPresentationAvailability(.toggle).isEnabled)
    session.newTerminalGroup()
    #expect(session.terminalGroupPresentationAvailability(.splitRight).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.splitDown).isEnabled)
    #expect(session.terminalGroupPresentationAvailability(.newGroup).isEnabled)
    session.requestTerminalGroupSaveAs(try #require(session.selectedTerminalGroupID))
    #expect(session.terminalGroupPresentationAvailability(.newGroup).isEnabled == false)
    #expect(session.terminalGroupPresentationAvailability(.toggle).isEnabled == false)
}

@Test("Terminal Group commands and palette retain the shortcut contract")
func terminalGroupCommandAndPaletteShortcutAudit() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let commands = try String(
        contentsOf: root.appending(path: "Sources/RafuApp/App/RafuAppCommands.swift"),
        encoding: .utf8)
    let palette = try String(
        contentsOf: root.appending(path: "Sources/RafuApp/Views/CommandPaletteView.swift"),
        encoding: .utf8)
    for text in [
        ".keyboardShortcut(\"t\", modifiers: .command)",
        ".keyboardShortcut(\"t\", modifiers: [.command, .shift])",
        ".keyboardShortcut(\"`\", modifiers: [.control, .shift])",
        ".keyboardShortcut(\"`\", modifiers: [.control])",
        ".keyboardShortcut(\"s\", modifiers: .command)",
        ".keyboardShortcut(\"s\", modifiers: [.command, .shift])",
        ".keyboardShortcut(.tab, modifiers: [.control])",
        ".keyboardShortcut(\"a\", modifiers: [.command, .shift])",
        ".keyboardShortcut(\"e\", modifiers: [.command, .shift])",
    ] {
        #expect(commands.contains(text))
    }
    #expect(
        commands.components(separatedBy: ".keyboardShortcut(\"t\", modifiers: .command)").count == 2
    )
    for text in [
        ".keyboardShortcut(.leftArrow, modifiers: [.control, .command])",
        ".keyboardShortcut(.rightArrow, modifiers: [.control, .command])",
        ".keyboardShortcut(.upArrow, modifiers: [.control, .command])",
        ".keyboardShortcut(.downArrow, modifiers: [.control, .command])",
        ".keyboardShortcut(.upArrow, modifiers: [.command, .option])",
        ".keyboardShortcut(.downArrow, modifiers: [.command, .option])",
        ".keyboardShortcut(\"j\", modifiers: [.control, .command])",
        ".keyboardShortcut(\"r\", modifiers: [.control, .command])",
    ] {
        #expect(commands.contains(text))
    }
    for title in [
        "Toggle Terminal Group", "Focus Terminal Pane Left", "Focus Terminal Pane Right",
        "Focus Terminal Pane Up", "Focus Terminal Pane Down", "Split Terminal Down",
        "Save Terminal Group As…",
    ] {
        #expect(palette.contains(title))
    }
    #expect(palette.contains(".disabled(!row.isEnabled)"))
    #expect(palette.contains("availability(contextualAction).reason"))
    for shortcut in ["⌘T", "⌘⇧T", "⌃⇧`", "⌃`", "⌃⌘←", "⌃⌘→", "⌃⌘↑", "⌃⌘↓", "⌘S", "⌘⇧S"] {
        #expect(palette.contains(shortcut))
    }
}

@MainActor
@Test("Two windows keep rename and folder requests independent")
func terminalGroupRequestsAreIndependentAcrossWindows() throws {
    let (first, firstRoot) = try makeTerminalGroupWorkspace()
    let (second, secondRoot) = try makeTerminalGroupWorkspace()
    defer {
        removeTerminalGroupWorkspace(firstRoot)
        removeTerminalGroupWorkspace(secondRoot)
    }
    first.newTerminalGroup()
    second.newTerminalGroup()
    first.requestTerminalGroupRename(try #require(first.selectedTerminalGroupID))
    second.requestTerminalPaneStartingFolder(try #require(second.focusedTerminalPaneID))
    #expect(first.pendingTerminalGroupRenameRequest != nil)
    #expect(first.pendingTerminalPaneStartingFolderRequest == nil)
    #expect(second.pendingTerminalGroupRenameRequest == nil)
    #expect(second.pendingTerminalPaneStartingFolderRequest != nil)
    first.cancelPendingTerminalGroupRename()
    #expect(second.pendingTerminalPaneStartingFolderRequest != nil)
}
