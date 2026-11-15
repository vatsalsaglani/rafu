import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// ADR 0023, 2026-11-15 amendment: when a terminal's saved folder is gone, a
/// start uses the workspace folder, and the stopped pane and Ensemble card say
/// so. A remote workspace has no local root and keeps its refusal.
@Suite("Terminal workspace-folder fallback")
@MainActor
struct TerminalWorkspaceFolderFallbackTests {
    @Test("Missing last and starting folders resolve to the workspace folder")
    func resolverFallsBackToRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "RafuFolderFallback.\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let usable = { (folder: TerminalWorkspaceRelativePath) in
            TerminalWorkspaceFolder.isUsable(folder, root: root)
        }
        let gone = { (folder: TerminalWorkspaceRelativePath) in
            TerminalWorkspaceFolder.isMissing(folder, root: root)
        }
        let profile = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: try #require(.init("gone")),
            lastWorkingFolder: TerminalWorkspaceRelativePath("also/gone"))

        #expect(
            TerminalStartFolderResolver.resolve(profile, isUsable: usable, isMissing: gone) == .root
        )
        #expect(
            TerminalStartFolderResolver.fallsBackToWorkspaceFolder(
                profile, isUsable: usable, isMissing: gone))
    }

    @Test("With no usable workspace folder (a remote workspace) the start still refuses")
    func remoteKeepsRefusal() throws {
        let profile = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: try #require(.init("gone")))
        let noLocalRoot = { (_: TerminalWorkspaceRelativePath) in false }

        #expect(
            TerminalStartFolderResolver.resolve(
                profile, isUsable: noLocalRoot, isMissing: { _ in true }) == nil)
        #expect(
            !TerminalStartFolderResolver.fallsBackToWorkspaceFolder(
                profile, isUsable: noLocalRoot, isMissing: { _ in true }))
    }

    @Test("A remote workspace session refuses a start; it does not use a local folder")
    func remoteSessionStartRefuses() throws {
        let session = WorkspaceSession()
        session.descriptor = WorkspaceDescriptor(
            displayName: "Remote",
            location: .ssh(SSHWorkspaceReference(hostAlias: "build-server", rootPath: "/srv")))
        #expect(session.rootURL == nil)
        let record = try inertSavedRecord(name: "Remote", folder: try #require(.init("gone")))
        let group = try session.terminal.insertInertSnapshot(
            try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot)

        session.startTerminalPane(group.focusedPaneID)

        #expect(session.terminal.terminalController(for: group.focusedPaneID) == nil)
        #expect(session.isTerminalGroupErrorPresented)
    }

    @Test("The labels say the saved folder is gone and name the workspace folder")
    func labels() throws {
        let profile = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: try #require(.init("gone")))
        let pane = try TerminalPaneSnapshot(
            id: TerminalPaneID(), sessionID: nil, explicitUserName: nil, reportedTitle: nil,
            runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
            launchProfile: profile, startAvailability: .available)

        #expect(
            TerminalPanePresentation.stoppedDescription(for: pane, startsInWorkspaceFolder: true)
                == "Start this pane when you are ready. Its saved folder is gone, so it starts in the workspace folder."
        )
        #expect(
            TerminalPanePresentation.stoppedDescription(for: pane)
                == "Start this pane when you are ready. It starts in gone.")
        #expect(
            CanvasCardPresentation.terminalStartFolderLine(profile, startsInWorkspaceFolder: true)
                == "Saved folder is gone. Starts in the workspace folder.")
        #expect(
            CanvasCardPresentation.terminalStartFolderLine(profile, startsInWorkspaceFolder: false)
                == "gone")
    }

    @Test("A restored pane whose folders are gone is startable and starts in the workspace folder")
    func restoredPaneStartsInWorkspaceFolder() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let record = try inertSavedRecord(name: "Gone", folder: try #require(.init("gone")))
        let open = try openRecord(from: record)
        let pane = try #require(open.panes.first)
        let bothGone = try TerminalGroupOpenTabRestorationRecord(
            groupID: open.groupID, name: open.name, root: open.root,
            focusedPaneID: open.focusedPaneID, savedLayoutID: open.savedLayoutID,
            panes: [
                try TerminalGroupOpenPaneRestorationRecord(
                    id: pane.id, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                    launchProfile: pane.launchProfile?.withLastWorkingFolder(.init("gone/too")))
            ])
        let store = TerminalGroupIntegrationStore()
        await store.replace([record], for: TerminalGroupWorkspaceKey(standardizedRoot: root))
        session.terminalGroupSavedLayoutStore = store

        await session.restoreTerminalGroupInstancesForTesting(
            try TerminalGroupWorkspaceRestoration(openGroups: [bothGone]))

        let restored = try #require(session.terminal.terminalGroups.first?.panes.first)
        #expect(restored.status == .stopped)
        #expect(restored.startAvailability == .available)
        #expect(restored.launchProfile?.lastWorkingFolder == nil)
        #expect(session.terminalPanesStartingInWorkspaceFolder == [restored.id])
        #expect(session.terminal.sessions.isEmpty)

        session.startTerminalPane(restored.id)
        let controller = try #require(session.terminal.terminalController(for: restored.id))
        #expect(
            URL(fileURLWithPath: controller.startingDirectory).standardizedFileURL.path
                == root.standardizedFileURL.path)
        #expect(!session.isTerminalGroupErrorPresented)
        #expect(session.terminalPanesStartingInWorkspaceFolder.isEmpty)
        // The user's starting folder is kept: the folder may come back.
        #expect(
            session.terminal.terminalGroup(open.groupID)?.panes.first?.launchProfile?
                .startingFolder.rawValue == "gone")
    }

    @Test("A restored pane with a usable starting folder does not fall back")
    func usableFolderDoesNotFallBack() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let record = try inertSavedRecord(name: "Here", folder: .root)
        let store = TerminalGroupIntegrationStore()
        await store.replace([record], for: TerminalGroupWorkspaceKey(standardizedRoot: root))
        session.terminalGroupSavedLayoutStore = store

        await session.restoreTerminalGroupInstancesForTesting(
            try TerminalGroupWorkspaceRestoration(openGroups: [try openRecord(from: record)]))

        #expect(session.terminal.terminalGroups.count == 1)
        #expect(session.terminalPanesStartingInWorkspaceFolder.isEmpty)
    }
}
