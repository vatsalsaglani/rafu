import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A saved Terminal Group keeps the folder each shell was in at Save, and a
/// stopped group can start every pane in one action (ADR 0023). These tests
/// are process-free: a start binds a controller, and no view mounts, so no
/// shell spawns.
@Suite("Saved Terminal Group folders and Start All")
@MainActor
struct TerminalSavedGroupFolderAndStartAllTests {
    // MARK: - Save captures the shell's folder

    @Test("Save stores the folder the shell is in as the pane's starting folder")
    func saveCapturesLiveFolder() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let sub = try makeFolder("pkg/src", in: root)
        let store = TerminalGroupIntegrationStore()
        session.terminalGroupSavedLayoutStore = store
        session.newTerminalGroup()
        let groupID = try #require(session.selectedTerminalGroupID)
        let paneID = try #require(session.terminal.terminalGroup(groupID)?.focusedPaneID)
        let controller = try #require(session.terminal.terminalController(for: paneID))
        controller.updateCurrentDirectory("file://" + sub.path)

        session.requestTerminalGroupSave(groupID)
        await session.waitForTerminalGroupStoreOperationForTesting()

        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let records = try await store.listSavedLayouts(for: key)
        let profile = try #require(records.first?.panes.first?.launchProfile)
        #expect(records.count == 1)
        #expect(profile.startingFolder.rawValue == "pkg/src")
        #expect(profile.lastWorkingFolder == nil)
        // The live group is not changed by the capture.
        let live = try #require(session.terminal.terminalGroup(groupID)?.panes.first)
        #expect(live.launchProfile?.startingFolder == .root)
    }

    @Test("Update captures the shell's new folder into the same saved layout")
    func updateRecapturesFolder() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let sub = try makeFolder("pkg/src", in: root)
        let other = try makeFolder("docs", in: root)
        let store = TerminalGroupIntegrationStore()
        session.terminalGroupSavedLayoutStore = store
        session.newTerminalGroup()
        let groupID = try #require(session.selectedTerminalGroupID)
        let paneID = try #require(session.terminal.terminalGroup(groupID)?.focusedPaneID)
        let controller = try #require(session.terminal.terminalController(for: paneID))
        controller.updateCurrentDirectory("file://" + sub.path)
        session.requestTerminalGroupSave(groupID)
        await session.waitForTerminalGroupStoreOperationForTesting()
        let savedID = try #require(session.terminal.terminalGroup(groupID)?.savedLayoutID)

        controller.updateCurrentDirectory("file://" + other.path)
        session.requestTerminalGroupSave(groupID)
        await session.waitForTerminalGroupStoreOperationForTesting()

        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let records = try await store.listSavedLayouts(for: key)
        #expect(records.map(\.id) == [savedID])
        #expect(records.first?.panes.first?.launchProfile?.startingFolder.rawValue == "docs")
    }

    @Test("A shell outside the workspace keeps the pane's saved folder")
    func outsideFolderKeepsPreviousFolder() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        _ = try makeFolder("pkg/src", in: root)
        let store = TerminalGroupIntegrationStore()
        session.terminalGroupSavedLayoutStore = store
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let record = try inertSavedRecord(
            name: "Kept", folder: try #require(TerminalWorkspaceRelativePath("pkg/src")))
        await store.replace([record], for: key)
        let decoded = try TerminalGroupRestorationCodec().openNamedLayout(record)
        let group = try session.terminal.insertInertSnapshot(decoded.snapshot)
        let paneID = try #require(session.terminal.terminalGroup(group.id)?.panes.first?.id)
        session.startTerminalPane(paneID)
        let controller = try #require(session.terminal.terminalController(for: paneID))
        controller.updateCurrentDirectory("file:///")

        session.requestTerminalGroupSave(group.id)
        await session.waitForTerminalGroupStoreOperationForTesting()

        let records = try await store.listSavedLayouts(for: key)
        #expect(records.map(\.id) == [record.id])
        #expect(records.first?.panes.first?.launchProfile?.startingFolder.rawValue == "pkg/src")
    }

    @Test("The real store accepts a captured folder and writes no new key")
    func realStoreRoundTrip() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        let base = FileManager.default.temporaryDirectory
            .appending(path: "RafuSavedGroupStore.\(UUID())", directoryHint: .isDirectory)
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
            try? FileManager.default.removeItem(at: base)
        }
        let sub = try makeFolder("pkg/src", in: root)
        session.terminalGroupSavedLayoutStore = TerminalGroupSavedLayoutStore(
            identity: .lightning, baseDirectory: base)
        session.newTerminalGroup()
        let groupID = try #require(session.selectedTerminalGroupID)
        let paneID = try #require(session.terminal.terminalGroup(groupID)?.focusedPaneID)
        try #require(session.terminal.terminalController(for: paneID))
            .updateCurrentDirectory("file://" + sub.path)

        session.requestTerminalGroupSave(groupID)
        await session.waitForTerminalGroupStoreOperationForTesting()
        #expect(session.terminal.terminalGroup(groupID)?.savedLayoutID != nil)

        // A fresh actor reads the file through the strict raw inspector.
        let reread = TerminalGroupSavedLayoutStore(identity: .lightning, baseDirectory: base)
        let records = try await reread.listSavedLayouts(
            for: TerminalGroupWorkspaceKey(standardizedRoot: root))
        #expect(records.first?.panes.first?.launchProfile?.startingFolder.rawValue == "pkg/src")
        let file = try #require(
            FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }
                .first { $0.lastPathComponent == "terminal-group-layouts.json" })
        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains("lastWorkingFolder"))
        #expect(text.contains("\"schemaVersion\":1") || text.contains("\"schemaVersion\" : 1"))
    }

    // MARK: - Open

    @Test("An old layout saved at the workspace folder still opens and starts there")
    func oldRootLayoutStartsAtRoot() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let record = try inertSavedRecord(name: "Old", folder: .root)
        try await loadLibrary([record], into: session, root: root)

        session.openSavedTerminalGroup(record.id, startingAllPanes: true)

        let group = try #require(
            session.terminal.terminalGroups.first { $0.savedLayoutID == record.id })
        let pane = try #require(group.panes.first)
        let controller = try #require(session.terminal.terminalController(for: pane.id))
        #expect(standardized(controller.startingDirectory) == standardized(root.path))
    }

    @Test("A deleted saved folder opens with the fallback text and starts at the workspace")
    func deletedFolderFallsBackToRoot() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let record = try inertSavedRecord(
            name: "Gone", folder: try #require(TerminalWorkspaceRelativePath("gone/folder")))
        try await loadLibrary([record], into: session, root: root)

        session.openSavedTerminalGroup(record.id)

        let group = try #require(
            session.terminal.terminalGroups.first { $0.savedLayoutID == record.id })
        let pane = try #require(group.panes.first)
        #expect(session.terminalPanesStartingInWorkspaceFolder.contains(pane.id))
        #expect(
            TerminalPanePresentation.stoppedDescription(for: pane, startsInWorkspaceFolder: true)
                == TerminalPanePresentation.workspaceFolderFallbackDescription)
        session.startTerminalPane(pane.id)
        let controller = try #require(session.terminal.terminalController(for: pane.id))
        #expect(standardized(controller.startingDirectory) == standardized(root.path))
    }

    @Test("A plain open starts nothing; Open and Start All starts every shell pane")
    func openAndStartAll() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        _ = try makeFolder("api", in: root)
        _ = try makeFolder("web", in: root)
        let record = try mixedRecord()
        try await loadLibrary([record], into: session, root: root)

        session.openSavedTerminalGroup(record.id)
        let inert = try #require(
            session.terminal.terminalGroups.first { $0.savedLayoutID == record.id })
        #expect(inert.panes.allSatisfy { $0.sessionID == nil })
        #expect(
            inert.panes.allSatisfy { session.terminal.terminalController(for: $0.id) == nil })

        session.openSavedTerminalGroup(record.id, startingAllPanes: true)
        let started = try #require(
            session.terminal.terminalGroups.first {
                $0.savedLayoutID == record.id && $0.id != inert.id
            })
        let shells = started.panes.filter { $0.runtimeKind == .ordinaryShell }
        let placeholders = started.panes.filter { $0.runtimeKind != .ordinaryShell }
        #expect(shells.count == 2)
        #expect(shells.allSatisfy { $0.status == .live && $0.sessionID != nil })
        let folders = Set(
            shells.compactMap {
                session.terminal.terminalController(for: $0.id).map {
                    standardized($0.startingDirectory)
                }
            })
        #expect(
            folders == [
                standardized(root.appending(path: "api").path),
                standardized(root.appending(path: "web").path),
            ])
        #expect(placeholders.count == 1)
        #expect(placeholders.allSatisfy { $0.status == .unavailable && $0.sessionID == nil })
        #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: started.id)) != nil)
        // The first group stays stopped.
        #expect(
            session.terminal.terminalGroup(inert.id)?.panes.allSatisfy { $0.sessionID == nil }
                == true)
    }

    // MARK: - Start All button

    @Test("The in-tab Start All action binds one controller per stopped pane in its folder")
    func startAllViewAction() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        _ = try makeFolder("api", in: root)
        _ = try makeFolder("web", in: root)
        let decoded = try TerminalGroupRestorationCodec().openNamedLayout(try mixedRecord())
        let group = try session.terminal.insertInertSnapshot(decoded.snapshot)

        session.performTerminalGroupViewAction(.startAll(group.id))

        let panes = try #require(session.terminal.terminalGroup(group.id)?.panes)
        for pane in panes where pane.runtimeKind == .ordinaryShell {
            let controller = try #require(session.terminal.terminalController(for: pane.id))
            let folder = try #require(pane.launchProfile?.startingFolder.rawValue)
            #expect(
                standardized(controller.startingDirectory)
                    == standardized(root.appending(path: folder).path))
        }
        #expect(
            panes.filter { $0.runtimeKind != .ordinaryShell }
                .allSatisfy { session.terminal.terminalController(for: $0.id) == nil })
    }

    @Test("The Start All title counts restartable panes and needs two")
    func startAllTitle() throws {
        let ten = try snapshot(statuses: Array(repeating: .stopped, count: 10))
        #expect(TerminalPanePresentation.startAllTitle(for: ten) == "Start All 10 Panes")
        #expect(
            TerminalPanePresentation.startAllAccessibilityLabel(for: ten)
                == "Start all 10 panes in Group")
        let one = try snapshot(statuses: [.stopped])
        #expect(TerminalPanePresentation.startAllTitle(for: one) == nil)
        let mixed = try snapshot(statuses: [.stopped, .exited, .live], unavailable: 2)
        #expect(mixed.restartablePanes.count == 2)
        #expect(TerminalPanePresentation.startAllTitle(for: mixed) == "Start All 2 Panes")
        let oneWithAgents = try snapshot(statuses: [.stopped], unavailable: 3)
        #expect(TerminalPanePresentation.startAllTitle(for: oneWithAgents) == nil)
    }

    @Test("The stopped text names the saved folder")
    func stoppedDescriptionNamesFolder() throws {
        let pane = try TerminalPaneSnapshot(
            id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
            runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
            launchProfile: TerminalPaneLaunchProfile(
                shell: .preferredShell,
                startingFolder: try #require(TerminalWorkspaceRelativePath("api/services"))),
            startAvailability: .available)
        #expect(
            TerminalPanePresentation.stoppedDescription(for: pane)
                == "Start this pane when you are ready. It starts in api/services.")
    }

    // MARK: - Helpers

    private func makeFolder(_ relative: String, in root: URL) throws -> URL {
        let url = root.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func loadLibrary(
        _ records: [SavedTerminalGroupRecord], into session: WorkspaceSession, root: URL
    ) async throws {
        let store = TerminalGroupIntegrationStore()
        installTerminalGroupStore(store, on: session)
        await store.waitForSubscribers(1)
        await store.waitForListCall(1)
        await session.waitForTerminalGroupStoreOperationForTesting()
        await store.replace(records, for: TerminalGroupWorkspaceKey(standardizedRoot: root))
        await store.waitForListCall(2)
        await session.waitForTerminalGroupStoreOperationForTesting()
        #expect(session.savedTerminalGroups.map(\.id) == records.map(\.id))
    }

    /// Two shell panes in `api` and `web`, and one Agent Terminal placeholder.
    private func mixedRecord() throws -> SavedTerminalGroupRecord {
        let api = SavedTerminalPaneID()
        let web = SavedTerminalPaneID()
        let agent = SavedTerminalPaneID()
        func shell(_ id: SavedTerminalPaneID, _ folder: String) throws -> SavedTerminalPaneRecord {
            try SavedTerminalPaneRecord(
                id: id, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell,
                    startingFolder: try #require(TerminalWorkspaceRelativePath(folder))))
        }
        return try SavedTerminalGroupRecord(
            id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Mixed")),
            root: .split(
                id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                first: .pane(api),
                second: .split(
                    id: SavedTerminalGroupSplitID(), axis: .rows, fraction: 0.5,
                    first: .pane(web), second: .pane(agent))),
            focusedPaneID: api,
            panes: [
                try shell(api, "api"),
                try shell(web, "web"),
                try SavedTerminalPaneRecord(
                    id: agent, explicitUserName: nil, themeColor: nil,
                    kind: .unavailableAgentTerminal, launchProfile: nil),
            ])
    }

    /// A group of shell panes with `statuses`, plus `unavailable` Agent
    /// Terminal placeholders, in a right-leaning split tree.
    private func snapshot(statuses: [TerminalPaneStatus], unavailable: Int = 0) throws
        -> TerminalGroupSnapshot
    {
        let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        var panes = try statuses.map { status in
            try TerminalPaneSnapshot(
                id: TerminalPaneID(), sessionID: status == .live ? UUID() : nil,
                explicitUserName: nil, reportedTitle: nil, runtimeKind: .ordinaryShell,
                themeColor: nil, status: status, launchProfile: profile,
                startAvailability: .available)
        }
        panes += try (0..<unavailable).map { _ in
            try TerminalPaneSnapshot(
                id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .unavailableAgentTerminal, themeColor: nil, status: .unavailable,
                launchProfile: nil, startAvailability: .unavailable)
        }
        let ids = panes.map(\.id)
        var node = TerminalGroupNode.pane(ids[ids.count - 1])
        for id in ids.dropLast().reversed() {
            node = .split(
                id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5,
                first: .pane(id), second: node)
        }
        return try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName("Group")), root: node,
            focusedPaneID: ids[0], savedLayoutID: nil, panes: panes,
            retainedPaneCount: panes.count)
    }
}
