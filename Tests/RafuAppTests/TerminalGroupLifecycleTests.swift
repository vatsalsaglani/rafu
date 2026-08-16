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

@MainActor
@Test("Start All retains exited controller identities and creates only stopped controllers")
func terminalGroupStartAllRestartsExitedAndCreatesOnlyStoppedControllers() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let group = try manager.createLiveGroup(instantiation: instantiation)
    let exitedPane = try #require(group.panes.first)
    let exitedController = try #require(manager.terminalController(for: exitedPane.id))
    exitedController.processDidTerminate(exitCode: 0)
    _ = try manager.perform(.splitFocusedPane(groupID: group.id, placement: .right))
    let before = try #require(manager.terminalGroup(group.id))
    let stoppedPane = try #require(before.panes.first { $0.status == .stopped })

    let started = try manager.startAllRestartablePanes(
        in: group.id, instantiations: [stoppedPane.id: instantiation])
    let updated = try #require(manager.terminalGroup(group.id))
    let restartedPane = try #require(updated.panes.first { $0.id == exitedPane.id })
    let startedPane = try #require(updated.panes.first { $0.id == stoppedPane.id })
    #expect(manager.terminalController(for: exitedPane.id) === exitedController)
    #expect(restartedPane.sessionID == exitedController.id)
    #expect(startedPane.sessionID != nil)
    #expect(started.count == 2)
    #expect(started[0] === exitedController)
    #expect(manager.selectedID == startedPane.sessionID)
}

@MainActor
@Test("A stale manager close token shuts down nothing and keeps membership")
func terminalGroupManagerStaleFinalizeHasZeroShutdown() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let group = try manager.createLiveGroup(
        instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile))
    let pane = try #require(group.panes.first)
    let controller = try #require(manager.terminalController(for: pane.id))
    let token = try closeToken(manager.perform(.prepareClose(.group(group.id))))
    try manager.renameTerminalGroup(group.id, rawName: "Changed")

    #expect(throws: TerminalGroupValidationError.staleCloseToken) {
        try manager.perform(.finalizeClose(token))
    }
    #expect(manager.terminalGroup(group.id) != nil)
    #expect(manager.terminalController(for: pane.id) === controller)
    #expect(controller.status == .idle)
}

@MainActor
@Test("A current-generation tampered close token cannot shut an unrelated controller")
func terminalGroupManagerRejectsTamperedCurrentCloseToken() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let targetGroup = try manager.createLiveGroup(instantiation: instantiation)
    let otherGroup = try manager.createLiveGroup(instantiation: instantiation)
    let targetPane = try #require(targetGroup.panes.first)
    let otherPane = try #require(otherGroup.panes.first)
    let targetController = try #require(manager.terminalController(for: targetPane.id))
    let otherController = try #require(manager.terminalController(for: otherPane.id))
    let fresh = try closeToken(manager.perform(.prepareClose(.group(targetGroup.id))))
    let tampered = try #require(
        TerminalGroupCloseToken(
            target: fresh.target, affectedSessionIDs: [otherController.id], liveProcessCount: 0,
            generation: fresh.generation))

    #expect(throws: TerminalGroupValidationError.staleCloseToken) {
        try manager.perform(.finalizeClose(tampered))
    }
    #expect(manager.terminalGroup(targetGroup.id) != nil)
    #expect(manager.terminalGroup(otherGroup.id) != nil)
    #expect(manager.terminalController(for: targetPane.id) === targetController)
    #expect(manager.terminalController(for: otherPane.id) === otherController)
    #expect(targetController.status == .idle)
    #expect(otherController.status == .idle)
}

@MainActor
@Test("Close preparation reports only running grouped controllers")
func terminalGroupClosePreparationUsesActualProcessCount() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let group = try manager.createLiveGroup(
        instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile))
    let pane = try #require(group.panes.first)
    let controller = try #require(manager.terminalController(for: pane.id))
    controller.markRunningForTesting()
    let token = try closeToken(manager.perform(.prepareClose(.group(group.id))))
    #expect(token.liveProcessCount == 1)
    #expect(manager.terminalController(for: pane.id) === controller)
}

@MainActor
@Test("Group close returns tree-ordered session cleanup and shuts grouped controllers once")
func terminalGroupCloseUsesStableSessionOrder() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let group = try manager.createLiveGroup(instantiation: instantiation)
    let firstPane = try #require(group.panes.first)
    let firstController = try #require(manager.terminalController(for: firstPane.id))
    _ = try manager.perform(.splitFocusedPane(groupID: group.id, placement: .right))
    let secondPane = try #require(
        manager.terminalGroup(group.id)?.panes.first { $0.id != firstPane.id })
    let secondController = try manager.startPane(secondPane.id, instantiation: instantiation)
    let token = try closeToken(manager.perform(.prepareClose(.group(group.id))))
    #expect(token.affectedSessionIDs == [firstController.id, secondController.id])

    _ = try manager.perform(.finalizeClose(token))
    #expect(manager.terminalGroup(group.id) == nil)
    #expect(manager.sessions.isEmpty)
    #expect(firstController.status == .exited(code: nil))
    #expect(secondController.status == .exited(code: nil))
}

@MainActor
@Test("Shutdown All clears grouped and legacy controller ownership")
func terminalGroupShutdownAllClearsGroupedAndLegacyControllers() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    _ = try manager.createLiveGroup(
        instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile))
    let legacy = manager.newSession(startingDirectory: "/tmp", shell: shell)

    manager.shutdownAll()
    #expect(manager.sessions.isEmpty)
    #expect(manager.terminalGroups.isEmpty)
    #expect(manager.selectedID == nil)
    #expect(legacy.status == .exited(code: nil))
}

@MainActor
@Test("Manager preserves group MRU order and resolves a grouped session")
func terminalGroupManagerMRUAndSessionLookupAreStable() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let first = try manager.createLiveGroup(instantiation: instantiation)
    let second = try manager.createLiveGroup(instantiation: instantiation)
    let controller = try #require(manager.terminalController(for: first.focusedPaneID))

    _ = try manager.perform(.parkGroup(first.id))
    _ = try manager.perform(.parkGroup(second.id))
    #expect(manager.parkedTerminalGroupIDs == [second.id, first.id])
    let membership = try #require(manager.terminalGroupAndPane(containing: controller.id))
    #expect(membership.0 == first.id)
    #expect(membership.1 == first.focusedPaneID)
}

@MainActor
@Test("One natural exit reaches the manager callback and grouped pane exactly once")
func terminalGroupNaturalExitCallbackIsInstalledOnce() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    var callbackCount = 0
    manager.sessionDidExit = { _, _ in callbackCount += 1 }
    let group = try manager.createLiveGroup(
        instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile))
    let pane = try #require(group.panes.first)
    let controller = try #require(manager.terminalController(for: pane.id))
    let revision = manager.terminalGroupRevision

    controller.processDidTerminate(exitCode: 7)
    #expect(callbackCount == 1)
    #expect(manager.terminalGroup(group.id)?.panes.first?.status == .exited)
    #expect(manager.terminalGroupRevision == revision + 1)
}

@MainActor
@Test("Legacy newSession remains the documented TG-20 capacity exemption")
func terminalGroupLegacyAdapterCapacityExemptionIsExplicit() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    for _ in 0..<7 {
        _ = manager.newSession(startingDirectory: "/tmp", shell: shell)
    }
    #expect(manager.sessions.count == 7)
    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 7, requested: 1)) {
        try manager.reserveLiveSessionCapacity(1)
    }
}

@MainActor
@Test("Start All ignores unavailable saved placeholders without a controller")
func terminalGroupStartAllIgnoresUnavailablePlaceholders() throws {
    let manager = WorkspaceTerminalManager()
    let savedPaneID = SavedTerminalPaneID()
    let record = try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Unavailable")),
        root: .pane(savedPaneID), focusedPaneID: savedPaneID,
        panes: [
            try SavedTerminalPaneRecord(
                id: savedPaneID, explicitUserName: nil, themeColor: nil,
                kind: .unavailableEnsemble, launchProfile: nil)
        ])
    let group = try manager.insertStoppedSavedGroup(record)
    let before = try #require(manager.terminalGroup(group.id))
    let controllers = try manager.startAllRestartablePanes(in: group.id, instantiations: [:])
    #expect(controllers.isEmpty)
    #expect(manager.sessions.isEmpty)
    #expect(manager.terminalGroup(group.id) == before)
}

@MainActor
@Test("Generic manager start commands reject before any capacity or tree work")
func terminalGroupGenericManagerStartCommandsRejectDirectly() throws {
    let manager = WorkspaceTerminalManager()
    let groupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
    let paneID = try #require(manager.terminalGroup(groupID)?.focusedPaneID)
    let before = try #require(manager.terminalGroup(groupID))
    let revision = manager.terminalGroupRevision

    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.perform(.startPane(paneID))
    }
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.perform(.restartExitedShellPane(paneID))
    }
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.perform(.startAllRestartablePanes(groupID))
    }
    #expect(manager.terminalGroup(groupID) == before)
    #expect(manager.terminalGroupRevision == revision)
}

@MainActor
@Test("Legacy shell adoption preserves one live controller without construction or restart")
func terminalGroupAdoptsLegacyShellWithoutControllerMutation() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    var factoryCalls = 0
    var forwardedExitCount = 0
    manager.sessionDidExit = { _, _ in forwardedExitCount += 1 }
    let controller = manager.newSession(startingDirectory: "/tmp", shell: shell)
    controller.markRunningForTesting()
    controller.sessionColor = .warning
    let selectedID = manager.selectedID
    let originalExit = controller.onExit
    var preservedExitCount = 0
    controller.onExit = { sessionID, code in
        preservedExitCount += 1
        originalExit?(sessionID, code)
    }
    manager.terminalGroupControllerFactory = { _, _ in
        factoryCalls += 1
        throw TerminalGroupValidationError.unsupportedPaneStart
    }

    let group = try manager.adoptUngroupedSession(controller.id)
    let pane = try #require(group.panes.first)
    #expect(group.root == .pane(pane.id))
    #expect(pane.sessionID == controller.id)
    #expect(pane.runtimeKind == .ordinaryShell)
    #expect(pane.status == .live)
    #expect(pane.startAvailability == .notRestartable)
    #expect(pane.themeColor == .warning)
    #expect(manager.terminalController(for: pane.id) === controller)
    #expect(manager.sessions.count == 1)
    #expect(manager.selectedID == selectedID)
    #expect(controller.status == .running)
    #expect(factoryCalls == 0)

    controller.processDidTerminate(exitCode: 9)
    #expect(preservedExitCount == 1)
    #expect(forwardedExitCount == 1)
    #expect(manager.terminalGroup(group.id)?.panes.first?.status == .exited)

    let token = try closeToken(manager.perform(.prepareClose(.group(group.id))))
    _ = try manager.perform(.finalizeClose(token))
    #expect(manager.sessions.isEmpty)
    #expect(controller.status == .exited(code: nil))
}

@MainActor
@Test("Legacy classified sessions adopt into truthful nonrestartable panes")
func terminalGroupAdoptsClassifiedLegacySessions() throws {
    let manager = WorkspaceTerminalManager()
    let agent = manager.newSession(
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Codex",
            agentProvider: .codex))
    let role = manager.newSession(
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Implementor",
            outputLogURL: URL(fileURLWithPath: "/tmp/output.log")))
    let coordinator = manager.newSession(
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: "/tmp", environment: ["RAFU_ENSEMBLE_TOKEN": "opaque"],
            roleBadge: "Coordinator"))

    let agentGroup = try manager.adoptUngroupedSession(agent.id)
    let roleGroup = try manager.adoptUngroupedSession(role.id)
    let coordinatorGroup = try manager.adoptUngroupedSession(coordinator.id)
    #expect(agentGroup.panes.first?.runtimeKind == .directAgentTerminal(provider: .codex))
    #expect(roleGroup.panes.first?.runtimeKind == .ensembleRole)
    #expect(coordinatorGroup.panes.first?.runtimeKind == .ensembleCoordinator)
    #expect(
        [agentGroup, roleGroup, coordinatorGroup].allSatisfy {
            $0.panes.first?.startAvailability == .notRestartable
                && $0.panes.first?.launchProfile == nil
        })
    #expect(manager.sessions.count == 3)
}

@MainActor
@Test("Legacy adoption rejects unknown, grouped, and live-over-capacity sessions without mutation")
func terminalGroupAdoptionRejectionsAreAtomic() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let legacy = manager.newSession(startingDirectory: "/tmp", shell: shell)
    let sessionsBeforeUnknown = manager.sessions
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.adoptUngroupedSession(UUID())
    }
    #expect(manager.terminalGroups.isEmpty)
    #expect(manager.sessions.map(\.id) == sessionsBeforeUnknown.map(\.id))

    let group = try manager.adoptUngroupedSession(legacy.id)
    let revision = manager.terminalGroupRevision
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.adoptUngroupedSession(legacy.id)
    }
    #expect(manager.terminalGroup(group.id) == group)
    #expect(manager.terminalGroupRevision == revision)

    let unknownSpec = manager.newSession(
        spec: TerminalProcessSpec(
            executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
            currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Unknown"))
    let groupsBeforeMetadataFailure = manager.terminalGroups
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.adoptUngroupedSession(unknownSpec.id)
    }
    #expect(manager.terminalGroups == groupsBeforeMetadataFailure)
    #expect(manager.terminalController(sessionID: unknownSpec.id) === unknownSpec)

    let overflow = WorkspaceTerminalManager()
    for _ in 0..<7 {
        _ = overflow.newSession(startingDirectory: "/tmp", shell: shell)
    }
    let candidate = try #require(overflow.sessions.first)
    let overflowSessions = overflow.sessions.map(\.id)
    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 7, requested: 0)) {
        try overflow.adoptUngroupedSession(candidate.id)
    }
    #expect(overflow.terminalGroups.isEmpty)
    #expect(overflow.sessions.map(\.id) == overflowSessions)
    #expect(candidate.status == .idle)
}

@MainActor
@Test("Legacy adoption rejects the retained-pane boundary without mutation")
func terminalGroupAdoptionRetainedCapacityIsAtomic() throws {
    let manager = WorkspaceTerminalManager()
    for _ in 0..<TerminalGroupSnapshot.maximumRetainedPanesPerWindow {
        _ = try manager.perform(.createGroup(name: nil))
    }
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let legacy = manager.newSession(startingDirectory: "/tmp", shell: shell)
    let groupsBefore = manager.terminalGroups
    let revision = manager.terminalGroupRevision

    #expect(
        throws: TerminalGroupCapacityError.retainedPaneLimitExceeded(
            current: TerminalGroupSnapshot.maximumRetainedPanesPerWindow, requested: 1)
    ) {
        try manager.adoptUngroupedSession(legacy.id)
    }
    #expect(manager.terminalGroups == groupsBefore)
    #expect(manager.terminalGroupRevision == revision)
    #expect(manager.terminalController(sessionID: legacy.id) === legacy)
}

@MainActor
@Test("Legacy adoption keeps a prior reservation and controller state on capacity rejection")
func terminalGroupAdoptionRejectsReservedCapacityOverflowAtomically() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    for _ in 0..<5 {
        _ = try manager.createLiveGroup(instantiation: instantiation)
    }
    let reservation = try manager.reserveLiveSessionCapacity(1)
    let legacy = manager.newSession(startingDirectory: "/tmp", shell: shell)
    let originalExit = legacy.onExit
    var preservedExitCount = 0
    var managerExitCount = 0
    manager.sessionDidExit = { _, _ in managerExitCount += 1 }
    legacy.onExit = { sessionID, code in
        preservedExitCount += 1
        originalExit?(sessionID, code)
    }
    let groupsBefore = manager.terminalGroups
    let sessionIDsBefore = manager.sessions.map(\.id)
    let revision = manager.terminalGroupRevision
    let selectedID = manager.selectedID

    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 7, requested: 0)) {
        try manager.adoptUngroupedSession(legacy.id)
    }
    #expect(manager.terminalGroups == groupsBefore)
    #expect(manager.sessions.map(\.id) == sessionIDsBefore)
    #expect(manager.terminalGroupRevision == revision)
    #expect(manager.selectedID == selectedID)
    #expect(legacy.status == .idle)
    #expect(manager.terminalGroupAndPane(containing: legacy.id) == nil)

    legacy.processDidTerminate(exitCode: 0)
    #expect(preservedExitCount == 1)
    #expect(managerExitCount == 1)
    try manager.cancelLiveSessionCapacity(reservation)
}

@MainActor
@Test("Exited legacy adoption adds retained identity but consumes no live capacity")
func terminalGroupAdoptsExitedLegacySessionWithoutLiveSlot() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let controller = manager.newSession(startingDirectory: "/tmp", shell: shell)
    controller.processDidTerminate(exitCode: 0)

    let group = try manager.adoptUngroupedSession(controller.id)
    #expect(group.panes.first?.sessionID == controller.id)
    #expect(group.panes.first?.status == .exited)
    let reservation = try manager.reserveLiveSessionCapacity(6)
    try manager.cancelLiveSessionCapacity(reservation)
}
