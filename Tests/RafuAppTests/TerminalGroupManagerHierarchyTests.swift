import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal Group manager hierarchy")
struct TerminalGroupManagerHierarchyTests {
    @MainActor
    @Test("Current saved-layout load state changes only when the list completes")
    func savedLayoutLoadingStateTracksCurrentList() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let store = TerminalGroupIntegrationStore()
        await store.suspendListCall(1)
        installTerminalGroupStore(store, on: session)
        await store.waitForSubscribers(1)
        await store.waitForListStart(1)
        #expect(session.isTerminalGroupStoreLoading == true)
        await store.releaseListCall(1)
        await session.waitForTerminalGroupStoreOperationForTesting()
        #expect(session.isTerminalGroupStoreLoading == false)
        #expect(session.savedTerminalGroups.isEmpty)
    }

    @MainActor
    @Test("Ungrouped legacy sessions remain one manager row")
    func ungroupedLegacySessionRemainsVisible() {
        let manager = WorkspaceTerminalManager()
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let legacy = manager.newSession(startingDirectory: "/tmp", shell: shell)
        let rows = TerminalsPanelModel.hierarchyRows(
            groups: manager.terminalGroups, presentedGroupIDs: [], currentGroupID: nil,
            controllers: manager.sessions, presentedLegacySessionIDs: [legacy.id],
            currentLegacySessionID: legacy.id, workspaceRoot: "/tmp")
        let legacyRows = rows.compactMap { row -> (TerminalSessionRow, Bool)? in
            guard case .legacy(let value, let isCurrent) = row else { return nil }
            return (value, isCurrent)
        }
        #expect(legacyRows.map { $0.0.id } == [legacy.id])
        #expect(legacyRows.first?.0.isParked == false)
        #expect(legacyRows.first?.0.directoryLabel == ".")
        #expect(legacyRows.first?.1 == true)
    }

    @MainActor
    @Test("Revealing and focusing one pane restores one outer group tab")
    func revealAndFocusPaneDoesNotDuplicateGroupTab() throws {
        let session = WorkspaceSession()
        session.newTerminalGroup()
        let groupID = try #require(session.selectedTerminalGroupID)
        let paneID = try #require(session.terminal.terminalGroup(groupID)?.focusedPaneID)
        session.hideTerminalGroup(groupID)

        session.revealTerminalGroup(groupID)
        session.focusTerminalPane(paneID, in: groupID)

        let tabs = session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs ?? []
        #expect(tabs.count { $0.resource == .terminalGroup(groupID: groupID) } == 1)
        #expect(session.terminal.terminalGroup(groupID)?.focusedPaneID == paneID)
    }

    @MainActor
    @Test("Opening a saved layout twice creates independent groups and delete detaches both")
    func savedOpenTwiceAndDeleteDetach() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let store = TerminalGroupIntegrationStore()
        installTerminalGroupStore(store, on: session)
        await store.waitForSubscribers(1)
        await store.waitForListCall(1)
        await session.waitForTerminalGroupStoreOperationForTesting()

        session.newTerminalGroup()
        let originalID = try #require(session.selectedTerminalGroupID)
        let source = try #require(session.terminal.terminalGroup(originalID))
        let savedRecord = try savedRecord(from: source)
        let workspaceKey = TerminalGroupWorkspaceKey(standardizedRoot: root)
        await store.replace([savedRecord], for: workspaceKey)
        await store.waitForListCall(2)
        await session.waitForTerminalGroupStoreOperationForTesting()
        let savedID = savedRecord.id

        session.openSavedTerminalGroup(savedID)
        let firstOpenedID = try #require(session.selectedTerminalGroupID)
        session.openSavedTerminalGroup(savedID)
        let secondOpenedID = try #require(session.selectedTerminalGroupID)
        #expect(firstOpenedID != secondOpenedID)
        #expect(session.terminal.terminalGroup(firstOpenedID)?.savedLayoutID == savedID)
        #expect(session.terminal.terminalGroup(secondOpenedID)?.savedLayoutID == savedID)

        session.deleteSavedTerminalGroup(savedID)
        await session.waitForTerminalGroupStoreOperationForTesting()
        await store.waitForListCall(3)
        await session.waitForTerminalGroupStoreOperationForTesting()
        #expect(session.terminal.terminalGroup(firstOpenedID)?.savedLayoutID == nil)
        #expect(session.terminal.terminalGroup(secondOpenedID)?.savedLayoutID == nil)
    }

    @MainActor
    @Test("Derived rows preserve group state and pane runtime state")
    func derivedRowsPreserveGroupAndPaneState() throws {
        let manager = WorkspaceTerminalManager()
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
        let first = try manager.createLiveGroup(
            name: TerminalGroupName("Build"),
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        let second = try manager.createLiveGroup(
            name: TerminalGroupName("Tests"),
            instantiation: .ordinaryShell(startingDirectory: "/tmp", shell: shell, profile: profile)
        )
        let firstPane = try #require(first.panes.first)
        let firstController = try #require(manager.terminalController(for: firstPane.id))
        firstController.markRunningForTesting()
        firstController.noteBell()
        _ = try manager.perform(.parkGroup(first.id))

        let rows = TerminalsPanelModel.hierarchyRows(
            groups: manager.terminalGroups,
            presentedGroupIDs: [second.id],
            currentGroupID: second.id,
            controllers: manager.sessions, presentedLegacySessionIDs: [],
            currentLegacySessionID: nil, workspaceRoot: "/tmp")
        let groupRows = rows.compactMap { row -> TerminalsPanelModel.TerminalGroupRow? in
            guard case .group(let group) = row else { return nil }
            return group
        }
        let paneRows = rows.compactMap { row -> TerminalsPanelModel.TerminalPaneRow? in
            guard case .pane(let pane) = row else { return nil }
            return pane
        }

        #expect(groupRows.count == 2)
        #expect(groupRows.first { $0.id == first.id }?.isParked == true)
        #expect(groupRows.first { $0.id == second.id }?.isCurrent == true)
        #expect(groupRows.first { $0.id == first.id }?.attentionCount == 1)
        #expect(paneRows.first { $0.id == firstPane.id }?.hasAttention == true)
        #expect(paneRows.first { $0.id == firstPane.id }?.providerOrShell == "zsh")
        #expect(paneRows.first { $0.id == firstPane.id }?.folder == ".")
    }

    @MainActor
    @Test("Inert unavailable panes preserve the fixed saved-profile message")
    func unavailablePaneUsesAuthoritativeMessage() throws {
        let manager = WorkspaceTerminalManager()
        let paneID = TerminalPaneID()
        let group = try manager.insertInertSnapshot(
            TerminalGroupSnapshot(
                id: TerminalGroupID(), name: try #require(TerminalGroupName("Saved")),
                root: .pane(paneID), focusedPaneID: paneID, savedLayoutID: SavedTerminalGroupID(),
                panes: [
                    try TerminalPaneSnapshot(
                        id: paneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                        runtimeKind: .unavailableAgentTerminal, themeColor: nil,
                        status: .unavailable,
                        launchProfile: nil, startAvailability: .unavailable)
                ], retainedPaneCount: 1))
        let rows = TerminalsPanelModel.hierarchyRows(
            groups: manager.terminalGroups, presentedGroupIDs: [], currentGroupID: nil,
            controllers: manager.sessions, presentedLegacySessionIDs: [],
            currentLegacySessionID: nil, workspaceRoot: "/tmp")
        let pane = try #require(
            rows.compactMap { row -> TerminalsPanelModel.TerminalPaneRow? in
                guard case .pane(let pane) = row, pane.groupID == group.id else { return nil }
                return pane
            }.first)
        #expect(pane.unavailableMessage == "Agent Terminal profiles are not saved in this version.")
        #expect(pane.canStart == false)
        #expect(pane.canRestart == false)
        #expect(
            TerminalPanePresentation.unavailableMessage(for: .unavailableEnsemble)
                == "Ensemble terminal profiles are not saved in this version.")
    }

    @MainActor
    @Test("Exited shells without a safe restart profile do not offer restart")
    func unavailableExitedShellDoesNotOfferRestart() throws {
        let paneID = TerminalPaneID()
        let snapshot = try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Unavailable shell")),
            root: .pane(paneID), focusedPaneID: paneID, savedLayoutID: nil,
            panes: [
                try TerminalPaneSnapshot(
                    id: paneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                    runtimeKind: .ordinaryShell, themeColor: nil, status: .exited,
                    launchProfile: TerminalPaneLaunchProfile(
                        shell: .preferredShell, startingFolder: .root),
                    startAvailability: .unavailable)
            ], retainedPaneCount: 1)
        let rows = TerminalsPanelModel.hierarchyRows(
            groups: [snapshot], presentedGroupIDs: [], currentGroupID: nil,
            controllers: [], presentedLegacySessionIDs: [],
            currentLegacySessionID: nil, workspaceRoot: "/tmp")
        let pane = try #require(
            rows.compactMap { row -> TerminalsPanelModel.TerminalPaneRow? in
                guard case .pane(let pane) = row else { return nil }
                return pane
            }.first)
        #expect(pane.canRestart == false)
    }

    @MainActor
    @Test("Start All includes only safe stopped shells while exited shells retain pane restart")
    func groupStartAllEligibilityExcludesExitedShells() throws {
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        let exitedPaneID = TerminalPaneID()
        let exitedGroup = try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Exited")),
            root: .pane(exitedPaneID), focusedPaneID: exitedPaneID, savedLayoutID: nil,
            panes: [
                try TerminalPaneSnapshot(
                    id: exitedPaneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                    runtimeKind: .ordinaryShell, themeColor: nil, status: .exited,
                    launchProfile: profile, startAvailability: .available)
            ], retainedPaneCount: 1)
        let stoppedPaneID = TerminalPaneID()
        let stoppedGroup = try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Stopped")),
            root: .pane(stoppedPaneID), focusedPaneID: stoppedPaneID, savedLayoutID: nil,
            panes: [
                try TerminalPaneSnapshot(
                    id: stoppedPaneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                    runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                    launchProfile: profile, startAvailability: .available)
            ], retainedPaneCount: 1)

        let rows = TerminalsPanelModel.hierarchyRows(
            groups: [exitedGroup, stoppedGroup], presentedGroupIDs: [], currentGroupID: nil,
            controllers: [], presentedLegacySessionIDs: [],
            currentLegacySessionID: nil, workspaceRoot: "/tmp")
        let groups = rows.compactMap { row -> TerminalsPanelModel.TerminalGroupRow? in
            guard case .group(let group) = row else { return nil }
            return group
        }
        let panes = rows.compactMap { row -> TerminalsPanelModel.TerminalPaneRow? in
            guard case .pane(let pane) = row else { return nil }
            return pane
        }

        #expect(groups.first { $0.id == exitedGroup.id }?.hasRestartablePane == false)
        #expect(panes.first { $0.id == exitedPaneID }?.canRestart == true)
        #expect(groups.first { $0.id == stoppedGroup.id }?.hasRestartablePane == true)
    }

    @Test("Saved-layout presentation does not mistake an initial load for empty")
    func savedLayoutPresentationStatesAreTruthful() {
        #expect(
            TerminalGroupSavedLayoutsPresentation.state(
                hasWorkspace: true, isLoading: true, error: nil, recordCount: 0) == .loading)
        #expect(
            TerminalGroupSavedLayoutsPresentation.state(
                hasWorkspace: true, isLoading: false, error: nil, recordCount: 0) == .empty)
        #expect(
            TerminalGroupSavedLayoutsPresentation.state(
                hasWorkspace: true, isLoading: false, error: "Disk unavailable", recordCount: 0)
                == .error("Disk unavailable"))
        #expect(
            TerminalGroupSavedLayoutsPresentation.state(
                hasWorkspace: true, isLoading: false, error: nil, recordCount: 1) == .records)
    }

    @Test("Hierarchy rows use stable group and pane identifiers")
    func hierarchyRowsHaveDistinctStableIdentity() {
        let groupID = TerminalGroupID()
        let paneID = TerminalPaneID()
        #expect(
            TerminalsPanelModel.HierarchyRow.group(
                .init(
                    id: groupID, name: "Build", paneCount: 2, livePaneCount: 1,
                    attentionCount: 0, isParked: false, isCurrent: true, isSaved: false,
                    hasRestartablePane: false
                )
            ).id == "group-\(groupID)")
        #expect(
            TerminalsPanelModel.HierarchyRow.pane(
                .init(
                    id: paneID, groupID: groupID, name: "Shell", detail: "zsh · Live",
                    status: .live, hasAttention: false, isFocused: true,
                    isUnavailable: false, sessionID: nil, sessionColor: nil,
                    folder: ".", providerOrShell: "zsh", canStart: false, canRestart: false
                )
            ).id == "pane-\(paneID)")
    }

    @Test("Manager source routes group and exact-pane actions through WorkspaceSession")
    func managerSourceUsesFrozenWorkspaceActions() throws {
        let source = try source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        #expect(source.contains("session.revealTerminalGroup(group.id)"))
        #expect(source.contains("session.hideTerminalGroup(group.id)"))
        #expect(source.contains("session.requestTerminalGroupClose(group.id)"))
        #expect(source.contains("session.revealTerminalGroup(pane.groupID)"))
        #expect(source.contains("session.focusTerminalPane(pane.id, in: pane.groupID)"))
        #expect(source.contains("TerminalGroupSavedLayoutsSection(session: session)"))
    }

    private func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appending(path: "Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
