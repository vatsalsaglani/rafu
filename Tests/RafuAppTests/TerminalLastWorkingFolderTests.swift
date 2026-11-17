import Darwin
import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// A stopped terminal starts in the folder its shell was last in (ADR 0023,
/// last working folder). These tests cover the OSC 7 host rule, the
/// workspace folder normaliser, the start-folder fallbacks, the Codable
/// shape, named layouts, and one Ensemble close and reopen.
@Suite("Terminal last working folder")
@MainActor
struct TerminalLastWorkingFolderTests {
    // MARK: - OSC 7

    @Test("OSC 7 accepts an empty host, localhost, and this Mac's names; not another host")
    func osc7HostRule() {
        let local: Set<String> = ["mac.local", "mac"]
        #expect(
            TerminalWorkingDirectoryReport.localPath("file:///Users/a/x", localHostNames: local)
                == "/Users/a/x")
        #expect(
            TerminalWorkingDirectoryReport.localPath(
                "file://localhost/Users/a/x", localHostNames: local) == "/Users/a/x")
        #expect(
            TerminalWorkingDirectoryReport.localPath(
                "file://MAC.local/Users/a/x", localHostNames: local) == "/Users/a/x")
        #expect(
            TerminalWorkingDirectoryReport.localPath("file://mac/Users/a/x", localHostNames: local)
                == "/Users/a/x")
        #expect(
            TerminalWorkingDirectoryReport.localPath(
                "file://build-server/home/a/x", localHostNames: local) == nil)
        #expect(
            TerminalWorkingDirectoryReport.localPath(
                "file:///Users/a/with%20space", localHostNames: local) == "/Users/a/with space")
        #expect(
            TerminalWorkingDirectoryReport.localPath("/bare/path", localHostNames: local)
                == "/bare/path")
        #expect(TerminalWorkingDirectoryReport.localPath("relative", localHostNames: local) == nil)
        #expect(TerminalWorkingDirectoryReport.localPath("", localHostNames: local) == nil)
        #expect(TerminalWorkingDirectoryReport.hostNames("Mac.Local") == ["mac.local", "mac"])
    }

    @Test("A remote OSC 7 report keeps the last local folder")
    func controllerIgnoresRemoteReport() {
        let controller = WorkspaceTerminalController(
            index: 1, startingDirectory: "/tmp",
            shell: TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true))
        controller.updateCurrentDirectory("file:///tmp/local")
        #expect(controller.currentDirectoryPath == "/tmp/local")
        controller.updateCurrentDirectory("file://some-other-host.example/srv")
        #expect(controller.currentDirectoryPath == "/tmp/local")
        controller.updateCurrentDirectory(nil)
        #expect(controller.currentDirectoryPath == nil)
    }

    // MARK: - Process inspector

    @Test("The Darwin inspector reads a process's current directory")
    func inspectorReadsCurrentDirectory() throws {
        let inspector = DarwinTerminalProcessInspector()
        let path = try #require(inspector.currentDirectory(processID: getpid()))
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        #expect(URL(fileURLWithPath: path).resolvingSymlinksInPath().path == expected)
        #expect(inspector.currentDirectory(processID: 0) == nil)
        #expect(inspector.currentDirectory(processID: 1) == nil)
    }

    // MARK: - Normaliser

    @Test("The normaliser accepts folders inside the root and refuses everything else")
    func normaliser() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        #expect(TerminalWorkspaceFolder.relative(path: root.path, root: root) == .root)
        #expect(
            TerminalWorkspaceFolder.relative(path: fixture.sub.path, root: root)?.rawValue
                == "a/b")
        // The temporary directory is itself below a symlink (/var). Both
        // sides resolve, so the resolved form of a path is accepted too.
        #expect(
            TerminalWorkspaceFolder.relative(
                path: fixture.sub.resolvingSymlinksInPath().path, root: root)?.rawValue == "a/b")
        #expect(TerminalWorkspaceFolder.relative(path: fixture.outside.path, root: root) == nil)
        #expect(
            TerminalWorkspaceFolder.relative(path: root.path + "/a/../../", root: root) == nil)
        #expect(
            TerminalWorkspaceFolder.relative(path: root.path + "/missing", root: root) == nil)
        #expect(TerminalWorkspaceFolder.relative(path: fixture.file.path, root: root) == nil)
        // A link inside the workspace that points outside it is refused.
        #expect(TerminalWorkspaceFolder.relative(path: fixture.escape.path, root: root) == nil)
    }

    // MARK: - Resolver

    @Test("A start uses the last folder, then the starting folder, then the workspace folder")
    func resolverFallbacks() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.root
        let usable = { (folder: TerminalWorkspaceRelativePath) in
            TerminalWorkspaceFolder.isUsable(folder, root: root)
        }
        let gone = { (folder: TerminalWorkspaceRelativePath) in
            TerminalWorkspaceFolder.isMissing(folder, root: root)
        }
        let sub = try #require(TerminalWorkspaceRelativePath("a/b"))
        let a = try #require(TerminalWorkspaceRelativePath("a"))
        let missing = try #require(TerminalWorkspaceRelativePath("gone"))
        let escape = try #require(TerminalWorkspaceRelativePath("escape"))

        let withLast = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: a, lastWorkingFolder: sub)
        #expect(
            TerminalStartFolderResolver.resolve(withLast, isUsable: usable, isMissing: gone) == sub)

        let deleted = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: a, lastWorkingFolder: missing)
        #expect(
            TerminalStartFolderResolver.resolve(deleted, isUsable: usable, isMissing: gone) == a)

        let escaping = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: .root, lastWorkingFolder: escape)
        #expect(
            TerminalStartFolderResolver.resolve(escaping, isUsable: usable, isMissing: gone)
                == .root)

        let noStart = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: missing, lastWorkingFolder: nil)
        // ADR 0023, 2026-11-15 amendment: a gone saved folder falls back to
        // the workspace folder instead of refusing the start.
        #expect(
            TerminalStartFolderResolver.resolve(noStart, isUsable: usable, isMissing: gone) == .root
        )
        #expect(
            TerminalStartFolderResolver.fallsBackToWorkspaceFolder(
                noStart, isUsable: usable, isMissing: gone))
        #expect(
            !TerminalStartFolderResolver.fallsBackToWorkspaceFolder(
                deleted, isUsable: usable, isMissing: gone))
        // A starting folder that exists but escapes the workspace is not
        // "gone": the start still refuses.
        let escapedStart = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: escape, lastWorkingFolder: nil)
        #expect(
            TerminalStartFolderResolver.resolve(escapedStart, isUsable: usable, isMissing: gone)
                == nil)

        #expect(
            TerminalStartFolderResolver.revalidated(deleted, isUsable: usable)
                .lastWorkingFolder
                == nil)
        #expect(
            TerminalStartFolderResolver.revalidated(withLast, isUsable: usable)
                == withLast)
    }

    @Test("The persisted folder follows the observation; outside or remote clears it")
    func persistedLastFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let stored = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: .root,
            lastWorkingFolder: TerminalWorkspaceRelativePath("a"))
        let resolver = TerminalStartFolderResolver.self
        #expect(
            resolver.persistedLastFolder(
                stored: stored, observedPath: fixture.sub.path, root: fixture.root
            ).lastWorkingFolder?.rawValue == "a/b")
        #expect(
            resolver.persistedLastFolder(stored: stored, observedPath: nil, root: fixture.root)
                == stored)
        #expect(
            resolver.persistedLastFolder(
                stored: stored, observedPath: fixture.outside.path, root: fixture.root
            ).lastWorkingFolder == nil)
        #expect(
            resolver.persistedLastFolder(stored: stored, observedPath: fixture.sub.path, root: nil)
                .lastWorkingFolder == nil)
        // The starting folder itself is not stored twice.
        #expect(
            resolver.persistedLastFolder(
                stored: stored, observedPath: fixture.root.path, root: fixture.root
            ).lastWorkingFolder == nil)
    }

    // MARK: - Codable

    @Test("Old profile data decodes; a round trip keeps the last folder; nil is not written")
    func codable() throws {
        let old = Data(#"{"shell":"preferred","startingFolder":"src"}"#.utf8)
        let decoded = try JSONDecoder().decode(TerminalPaneLaunchProfile.self, from: old)
        #expect(decoded.startingFolder.rawValue == "src")
        #expect(decoded.lastWorkingFolder == nil)
        #expect(
            !String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
                .contains("lastWorkingFolder"))

        let profile = TerminalPaneLaunchProfile(
            shell: .preferredShell, startingFolder: .root,
            lastWorkingFolder: TerminalWorkspaceRelativePath("Sources/RafuApp"))
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(TerminalPaneLaunchProfile.self, from: data) == profile)

        let absolute = Data(
            #"{"shell":"preferred","startingFolder":".","lastWorkingFolder":"/etc"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TerminalPaneLaunchProfile.self, from: absolute)
        }
        let traversal = Data(
            #"{"shell":"preferred","startingFolder":".","lastWorkingFolder":"a/../.."}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TerminalPaneLaunchProfile.self, from: traversal)
        }
    }

    // MARK: - Named saved layouts

    @Test("A named saved layout folds the last folder into its starting folder")
    func namedLayoutExcludesLastFolder() throws {
        let paneID = TerminalPaneID()
        let base = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
        func snapshot(_ profile: TerminalPaneLaunchProfile) throws -> TerminalGroupSnapshot {
            try TerminalGroupSnapshot(
                id: TerminalGroupID(), name: try #require(TerminalGroupName("Saved")),
                root: .pane(paneID), focusedPaneID: paneID, savedLayoutID: nil,
                panes: [
                    try TerminalPaneSnapshot(
                        id: paneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                        runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                        launchProfile: profile, startAvailability: .available)
                ], retainedPaneCount: 1)
        }
        let savedID = SavedTerminalGroupID()
        let codec = TerminalGroupRestorationCodec()
        let clean = try codec.savedRecord(from: snapshot(base), savedLayoutID: savedID)
        let moved = try codec.savedRecord(
            from: snapshot(base.withLastWorkingFolder(TerminalWorkspaceRelativePath("src"))),
            savedLayoutID: savedID)
        #expect(clean.panes.first?.launchProfile?.startingFolder == .root)
        #expect(moved.panes.first?.launchProfile?.startingFolder.rawValue == "src")
        #expect(moved.panes.first?.launchProfile?.lastWorkingFolder == nil)
        let encoded = String(decoding: try JSONEncoder().encode(moved), as: UTF8.self)
        #expect(!encoded.contains("lastWorkingFolder"))
    }

    @Test("Workspace restoration of a saved group carries the shell's folder; its layout does not")
    func workspaceRestorationCarriesLastFolder() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let sub = root.appendingPathComponent("pkg/src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let store = TerminalGroupIntegrationStore()
        session.terminalGroupSavedLayoutStore = store
        session.newTerminalGroup()
        let groupID = try #require(session.selectedTerminalGroupID)
        session.requestTerminalGroupSave(groupID)
        await session.waitForTerminalGroupStoreOperationForTesting()
        let savedLayoutID = try #require(session.terminal.terminalGroup(groupID)?.savedLayoutID)
        let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
        let before = try await store.listSavedLayouts(for: key)

        let paneID = try #require(session.terminal.terminalGroup(groupID)?.focusedPaneID)
        let controller = try #require(session.terminal.terminalController(for: paneID))
        controller.updateCurrentDirectory("file://" + sub.path)

        let envelope = try #require(session.terminalGroupWorkspaceRestorationForTesting())
        let profile = try #require(envelope.openGroups.first?.panes.first?.launchProfile)
        #expect(profile.lastWorkingFolder?.rawValue == "pkg/src")
        #expect(session.terminal.terminalGroup(groupID)?.savedLayoutID == savedLayoutID)
        // The library still holds the same record: nothing saved the layout.
        #expect(try await store.listSavedLayouts(for: key) == before)
        #expect(before.first?.panes.first?.launchProfile?.lastWorkingFolder == nil)

        controller.updateCurrentDirectory("file:///")
        let outside = try #require(session.terminalGroupWorkspaceRestorationForTesting())
        #expect(outside.openGroups.first?.panes.first?.launchProfile?.lastWorkingFolder == nil)
    }

    @Test("A split pane takes the starting folder, not the source's last folder")
    func splitDropsLastFolder() throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let record = try inertSavedRecord(name: "Split", folder: .root)
        var decoded = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot
        decoded = try withLastFolder(decoded, TerminalWorkspaceRelativePath("sub"))
        let group = try session.terminal.insertInertSnapshot(decoded)
        session.startAllRestartableTerminalPanes(in: group.id)
        session.revealTerminalGroup(group.id)
        session.splitFocusedTerminalPane(.right)
        let panes = try #require(session.terminal.terminalGroup(group.id)?.panes)
        #expect(panes.count == 2)
        let split = try #require(panes.last)
        #expect(split.launchProfile?.lastWorkingFolder == nil)
    }

    // MARK: - Start

    @Test("Start Pane uses the last folder and falls back when it was deleted")
    func startUsesLastFolder() throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let sub = root.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let record = try inertSavedRecord(name: "Start", folder: .root)
        let base = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot

        let first = try session.terminal.insertInertSnapshot(
            try withLastFolder(base, TerminalWorkspaceRelativePath("sub")))
        session.startTerminalPane(first.focusedPaneID)
        let controller = try #require(session.terminal.terminalController(for: first.focusedPaneID))
        #expect(controller.startingDirectory == sub.standardizedFileURL.path)

        let second = try session.terminal.insertInertSnapshot(
            try withLastFolder(
                try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot,
                TerminalWorkspaceRelativePath("deleted")))
        session.startAllRestartableTerminalPanes(in: second.id)
        let fallback = try #require(
            session.terminal.terminalController(for: second.focusedPaneID))
        #expect(fallback.startingDirectory == root.standardizedFileURL.path)
    }

    @Test("Restoration drops a last folder that no longer exists, so the label is honest")
    func restorationRevalidatesLastFolder() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer { removeTerminalGroupWorkspace(root) }
        let record = try inertSavedRecord(name: "Gone", folder: .root)
        let open = try openRecord(from: record)
        let pane = try #require(open.panes.first)
        let moved = try TerminalGroupOpenTabRestorationRecord(
            groupID: open.groupID, name: open.name, root: open.root,
            focusedPaneID: open.focusedPaneID, savedLayoutID: open.savedLayoutID,
            panes: [
                try TerminalGroupOpenPaneRestorationRecord(
                    id: pane.id, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                    launchProfile: pane.launchProfile?.withLastWorkingFolder(
                        TerminalWorkspaceRelativePath("deleted")))
            ])
        let store = TerminalGroupIntegrationStore()
        await store.replace([record], for: TerminalGroupWorkspaceKey(standardizedRoot: root))
        session.terminalGroupSavedLayoutStore = store
        await session.restoreTerminalGroupInstancesForTesting(
            try TerminalGroupWorkspaceRestoration(openGroups: [moved]))
        let restored = try #require(session.terminal.terminalGroups.first?.panes.first)
        #expect(restored.launchProfile?.lastWorkingFolder == nil)
        #expect(restored.startAvailability == .available)
        #expect(TerminalPanePresentation.folderLabel(for: restored) == ".")
    }

    // MARK: - Labels

    @Test("The empty states name the folder a start uses")
    func labels() throws {
        let paneID = TerminalPaneID()
        func pane(_ last: String?) throws -> TerminalPaneSnapshot {
            try TerminalPaneSnapshot(
                id: paneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell, startingFolder: .root,
                    lastWorkingFolder: last.flatMap { TerminalWorkspaceRelativePath($0) }),
                startAvailability: .available)
        }
        let atRoot = try pane(nil)
        let moved = try pane("Sources/RafuApp")
        #expect(TerminalPanePresentation.folderLabel(for: atRoot) == ".")
        #expect(TerminalPanePresentation.folderLabel(for: moved) == "Sources/RafuApp")
        #expect(
            CanvasCardPresentation.folderName(
                try #require(atRoot.launchProfile).preferredStartFolder.rawValue)
                == "Workspace folder")
        #expect(
            CanvasCardPresentation.folderName(
                try #require(moved.launchProfile).preferredStartFolder.rawValue)
                == "Sources/RafuApp")
        #expect(
            TerminalPanePresentation.stoppedDescription(for: atRoot)
                == "Start this pane when you are ready. It starts in the workspace folder.")
        #expect(
            TerminalPanePresentation.stoppedDescription(for: moved)
                == "Start this pane when you are ready. It starts in Sources/RafuApp.")
    }

    // MARK: - Ensemble close and reopen

    @Test("An Ensemble terminal reopens in the folder its shell was in")
    func ensembleReopenStartsInLastFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let sub = folder.appending(path: "work/tree", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let disk = CanvasPersistenceStore(directory: folder.appending(path: "state"))
        let session = makeCanvasSession(disk)
        session.spawnsHeadlessCanvasTerminals = false
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Task"))
        session.presentCanvasBoard(board)
        _ = session.addCanvasStoppedTerminal(board.id)
        let card = try #require(board.cards.first)
        guard case .terminal(let groupID) = card.content else {
            Issue.record("Expected terminal card")
            return
        }
        let paneID = try #require(session.terminal.terminalGroup(groupID)?.focusedPaneID)
        session.startTerminalPane(paneID, background: true)
        let controller = try #require(session.terminal.terminalController(for: paneID))
        controller.updateCurrentDirectory("file://" + sub.path)
        #expect(await session.canvas.save(board.id))
        session.teardownTerminalGroups()

        let other = makeCanvasSession(disk)
        other.spawnsHeadlessCanvasTerminals = false
        other.descriptor = session.descriptor
        #expect(await other.canvas.configure(root: folder))
        let reopened = try #require(await other.canvas.open(board.id))
        other.restoreCanvasTerminalReferences(reopened)
        let pane = try #require(other.terminal.terminalGroup(groupID)?.panes.first)
        #expect(pane.status == .stopped)
        #expect(pane.launchProfile?.lastWorkingFolder?.rawValue == "work/tree")
        #expect(other.terminal.sessions.isEmpty)
        other.startTerminalPane(pane.id, background: true)
        let restarted = try #require(other.terminal.terminalController(for: pane.id))
        #expect(restarted.startingDirectory == sub.standardizedFileURL.path)
        other.teardownTerminalGroups()
    }

    // MARK: - Helpers

    private func makeCanvasSession(_ disk: CanvasPersistenceStore) -> WorkspaceSession {
        WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.last-folder-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(persistence: disk))
    }

    private func withLastFolder(
        _ snapshot: TerminalGroupSnapshot, _ folder: TerminalWorkspaceRelativePath?
    ) throws -> TerminalGroupSnapshot {
        let panes = try snapshot.panes.map { pane in
            try TerminalPaneSnapshot(
                id: pane.id, sessionID: pane.sessionID, explicitUserName: pane.explicitUserName,
                reportedTitle: pane.reportedTitle, runtimeKind: pane.runtimeKind,
                themeColor: pane.themeColor, status: pane.status,
                launchProfile: pane.launchProfile?.withLastWorkingFolder(folder),
                startAvailability: pane.startAvailability)
        }
        return try TerminalGroupSnapshot(
            id: snapshot.id, name: snapshot.name, root: snapshot.root,
            focusedPaneID: snapshot.focusedPaneID, savedLayoutID: snapshot.savedLayoutID,
            panes: panes, retainedPaneCount: panes.count)
    }

    /// root/a/b, root/file, an outside folder, and root/escape -> outside.
    private struct Fixture {
        let root: URL
        let sub: URL
        let file: URL
        let outside: URL
        let escape: URL

        init() throws {
            let manager = FileManager.default
            let base = manager.temporaryDirectory.appending(path: "RafuLastFolder.\(UUID())")
            root = base.appending(path: "root", directoryHint: .isDirectory)
            sub = root.appending(path: "a/b", directoryHint: .isDirectory)
            file = root.appending(path: "file")
            outside = base.appending(path: "outside", directoryHint: .isDirectory)
            escape = root.appending(path: "escape", directoryHint: .isDirectory)
            try manager.createDirectory(at: sub, withIntermediateDirectories: true)
            try manager.createDirectory(at: outside, withIntermediateDirectories: true)
            _ = manager.createFile(atPath: file.path, contents: Data())
            try manager.createSymbolicLink(at: escape, withDestinationURL: outside)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
        }
    }
}
