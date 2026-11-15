import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// ADR 0023, 2026-11-15 amendment: an unsaved Terminal Group tab comes back
/// when its window reopens. Its layout, pane names, folders, tab position and
/// selection return; every pane is stopped and no process or command returns.
@Suite("Unsaved Terminal Group restoration")
@MainActor
struct TerminalUnsavedGroupRestorationTests {
    @Test("An unsaved group round-trips through workspace restoration with stopped panes")
    func unsavedGroupRoundTrip() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let sub = root.appendingPathComponent("pkg/src", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        session.terminalGroupSavedLayoutStore = TerminalGroupIntegrationStore()
        let fileURL = root.appendingPathComponent("README.md")
        _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data())
        let document = EditorDocument(url: fileURL)
        session.openDocuments = [document]
        session.editorLayout.insert(
            EditorTabState(resource: .file(fileURL)), in: session.editorLayout.focusedGroupID)

        let first = try session.terminal.insertInertSnapshot(
            try unsavedSnapshot(
                name: "Build", paneNames: ["server", "tests"],
                folders: [.root, try #require(.init("pkg"))],
                lastFolders: [TerminalWorkspaceRelativePath("pkg/src"), nil]))
        session.revealTerminalGroup(first.id)
        let second = try session.terminal.insertInertSnapshot(
            try unsavedSnapshot(name: "Logs", paneNames: ["tail"], folders: [.root]))
        session.revealTerminalGroup(second.id)
        // The user selects the first group again: selection must return.
        session.revealTerminalGroup(first.id)

        let envelope = try #require(session.terminalGroupWorkspaceRestorationForTesting())
        #expect(envelope.openGroups.map(\.groupID) == [first.id, second.id])
        #expect(envelope.openGroups.allSatisfy { $0.savedLayoutID == nil })
        let workspace = RestorableWorkspace(
            bookmark: Data([1]), rootPath: root.path, openRelativePaths: ["README.md"],
            selectedRelativePath: nil, navigatorMode: .files,
            editorLayout: EditorLayoutRestoration(
                layout: session.editorLayoutForWorkspaceRestorationForTesting()),
            terminalGroupRestoration: envelope)
        let decoded = try JSONDecoder().decode(
            RestorableWorkspace.self, from: JSONEncoder().encode(workspace))
        let groups = try #require(decoded.terminalGroupRestoration)

        let (restored, _) = try makeRestoredSession(root: root, fileURL: fileURL)
        defer { restored.teardownTerminalGroups() }
        await restored.restoreTerminalGroupInstancesForTesting(groups)
        restored.restoreEditorLayoutForTesting(
            try #require(decoded.editorLayout), terminalGroups: groups, rootURL: root)

        #expect(restored.terminal.sessions.isEmpty)
        let build = try #require(restored.terminal.terminalGroup(first.id))
        #expect(build.name.rawValue == "Build")
        #expect(build.savedLayoutID == nil)
        #expect(build.root == first.root)
        #expect(build.focusedPaneID == first.focusedPaneID)
        #expect(build.panes.map(\.explicitUserName?.rawValue) == ["server", "tests"])
        #expect(build.panes.allSatisfy { $0.status == .stopped && $0.sessionID == nil })
        #expect(build.panes.allSatisfy { $0.startAvailability == .available })
        #expect(build.panes.map(\.launchProfile?.startingFolder.rawValue) == [".", "pkg"])
        #expect(build.panes.map(\.launchProfile?.lastWorkingFolder?.rawValue) == ["pkg/src", nil])
        #expect(restored.terminal.terminalGroup(second.id)?.panes.count == 1)

        let tabs = restored.editorLayout.group(id: restored.editorLayout.focusedGroupID)?.tabs ?? []
        #expect(
            tabs.map(\.resource) == [
                .file(fileURL), .terminalGroup(groupID: first.id),
                .terminalGroup(groupID: second.id),
            ])
        #expect(restored.selectedTerminalGroupID == first.id)

        // Explicit start still works after restoration.
        restored.startAllRestartableTerminalPanes(in: first.id)
        #expect(restored.terminal.sessions.count == 2)
    }

    @Test("A closed or hidden unsaved group does not come back")
    func closedGroupDoesNotReturn() throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let kept = try session.terminal.insertInertSnapshot(
            try unsavedSnapshot(name: "Kept", paneNames: ["a"], folders: [.root]))
        session.revealTerminalGroup(kept.id)
        let closed = try session.terminal.insertInertSnapshot(
            try unsavedSnapshot(name: "Closed", paneNames: ["b"], folders: [.root]))
        session.revealTerminalGroup(closed.id)
        let hidden = try session.terminal.insertInertSnapshot(
            try unsavedSnapshot(name: "Hidden", paneNames: ["c"], folders: [.root]))
        session.revealTerminalGroup(hidden.id)

        session.requestTerminalGroupClose(closed.id)
        session.hideTerminalGroup(hidden.id)
        #expect(session.terminal.terminalGroup(closed.id) == nil)

        let envelope = try #require(session.terminalGroupWorkspaceRestorationForTesting())
        #expect(envelope.openGroups.map(\.groupID) == [kept.id])
        let layout = session.editorLayoutForWorkspaceRestorationForTesting()
        let resources = layout.groupIDs.flatMap { layout.group(id: $0)?.tabs ?? [] }
            .map(\.resource)
        #expect(resources == [.terminalGroup(groupID: kept.id)])
    }

    @Test("A group shown on an Ensemble is not duplicated as a window tab")
    func ensembleGroupIsNotDuplicated() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.unsaved-group-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: folder.appending(path: "state"))))
        defer { session.teardownTerminalGroups() }
        session.spawnsHeadlessCanvasTerminals = false
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Task"))
        session.presentCanvasBoard(board)
        _ = session.addCanvasStoppedTerminal(board.id)
        let card = try #require(board.cards.first)
        guard case .terminal(let cardGroupID) = card.content else {
            Issue.record("Expected terminal card")
            return
        }
        // The same group also opened in an editor tab.
        session.revealTerminalGroup(cardGroupID)
        #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: cardGroupID)) != nil)
        let tabGroup = try session.terminal.insertInertSnapshot(
            try unsavedSnapshot(name: "Tab", paneNames: ["a"], folders: [.root]))
        session.revealTerminalGroup(tabGroup.id)

        let envelope = try #require(session.terminalGroupWorkspaceRestorationForTesting())
        #expect(envelope.openGroups.map(\.groupID) == [tabGroup.id])
        let layout = session.editorLayoutForWorkspaceRestorationForTesting()
        let resources = layout.groupIDs.flatMap { layout.group(id: $0)?.tabs ?? [] }
            .map(\.resource)
        #expect(!resources.contains(.terminalGroup(groupID: cardGroupID)))
        #expect(resources.contains(.terminalGroup(groupID: tabGroup.id)))
        // The board's own payload still carries its card's group.
        let boardPayload = try #require(session.canvasTerminalRestoration([cardGroupID]))
        #expect(boardPayload.openGroups.map(\.groupID) == [cardGroupID])
    }

    @Test("A payload from before this change, without unsaved groups, decodes and restores")
    func oldPayloadDecodes() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        // A pre-change workspace payload with no terminal field at all.
        let bare = RestorableWorkspace(
            bookmark: Data([1]), rootPath: root.path, openRelativePaths: [],
            selectedRelativePath: nil, navigatorMode: .files,
            editorLayout: EditorLayoutRestoration(layout: EditorLayoutState()))
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        object["terminalGroupRestoration"] = nil
        let decodedBare = try JSONDecoder().decode(
            RestorableWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decodedBare.terminalGroupRestoration == nil)
        // Existing behaviour: the absent field is only a bounded diagnostic.
        #expect(decodedBare.terminalGroupRestorationDiagnostics == [.missingTerminalGroupField])

        // A pre-change open record: no savedLayoutID and no lastWorkingFolder keys.
        let snapshot = try unsavedSnapshot(name: "Old", paneNames: ["a"], folders: [.root])
        let restoration = try TerminalGroupWorkspaceRestoration(openGroups: [
            try openRecord(snapshot)
        ])
        var envelope = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(restoration))
                as? [String: Any])
        var groups = try #require(envelope["openGroups"] as? [[String: Any]])
        groups[0]["savedLayoutID"] = nil
        envelope["openGroups"] = groups
        let encoded = try JSONSerialization.data(withJSONObject: envelope)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("lastWorkingFolder"))
        let decoded = try JSONDecoder().decode(
            TerminalGroupWorkspaceRestoration.self, from: encoded)
        #expect(decoded.openGroups.first?.savedLayoutID == nil)
        #expect(decoded.schemaVersion == TerminalGroupWorkspaceRestoration.currentSchemaVersion)

        session.terminalGroupSavedLayoutStore = TerminalGroupIntegrationStore()
        await session.restoreTerminalGroupInstancesForTesting(decoded)
        #expect(session.terminal.terminalGroup(snapshot.id)?.panes.first?.status == .stopped)
    }

    @Test("Restoration keeps the window group cap and reports the overflow")
    func capsHold() async throws {
        let (session, root) = try makeTerminalGroupWorkspace()
        defer {
            session.teardownTerminalGroups()
            removeTerminalGroupWorkspace(root)
        }
        let limit = TerminalGroupWorkspaceRestoration.maximumOpenGroups
        let records = try (0...limit).map { index in
            try openRecord(
                try unsavedSnapshot(name: "G\(index)", paneNames: ["p"], folders: [.root]))
        }
        #expect(throws: TerminalGroupRestorationError.self) {
            try TerminalGroupWorkspaceRestoration(openGroups: records)
        }

        // A decoded payload may carry more (Ensemble bound); insertion keeps
        // the window cap and drops the rest with the bounded notice.
        let envelope: [String: Any] = [
            "schemaVersion": TerminalGroupWorkspaceRestoration.currentSchemaVersion,
            "openGroups": try records.map {
                try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
            },
        ]
        let decoded = try JSONDecoder().decode(
            TerminalGroupWorkspaceRestoration.self,
            from: JSONSerialization.data(withJSONObject: envelope))
        #expect(decoded.openGroups.count == limit + 1)
        session.terminalGroupSavedLayoutStore = TerminalGroupIntegrationStore()
        await session.restoreTerminalGroupInstancesForTesting(decoded)
        #expect(session.terminal.terminalGroups.count == limit)
        #expect(
            session.terminalGroupRestorationError
                == "One saved Terminal Group could not be restored.")
        #expect(session.terminal.sessions.isEmpty)
    }

    // MARK: - Helpers

    private func makeRestoredSession(root: URL, fileURL: URL) throws -> (
        WorkspaceSession, EditorDocument
    ) {
        let restored = WorkspaceSession()
        restored.descriptor = WorkspaceDescriptor(
            displayName: "Restored", location: .local(LocalWorkspaceReference(path: root.path)))
        restored.terminalGroupSavedLayoutStore = TerminalGroupIntegrationStore()
        let document = EditorDocument(url: fileURL)
        restored.openDocuments = [document]
        return (restored, document)
    }

    /// An inert, unsaved group: one pane, or two panes side by side.
    private func unsavedSnapshot(
        name: String, paneNames: [String], folders: [TerminalWorkspaceRelativePath],
        lastFolders: [TerminalWorkspaceRelativePath?] = []
    ) throws -> TerminalGroupSnapshot {
        let ids = paneNames.map { _ in TerminalPaneID() }
        let panes = try ids.indices.map { index in
            try TerminalPaneSnapshot(
                id: ids[index], sessionID: nil,
                explicitUserName: TerminalPaneName(paneNames[index]), reportedTitle: nil,
                runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell, startingFolder: folders[index]
                ).withLastWorkingFolder(
                    lastFolders.indices.contains(index) ? lastFolders[index] : nil),
                startAvailability: .available)
        }
        let root: TerminalGroupNode =
            ids.count == 1
            ? .pane(ids[0])
            : .split(
                id: TerminalGroupSplitID(), axis: .columns, fraction: 0.4,
                first: .pane(ids[0]), second: .pane(ids[1]))
        return try TerminalGroupSnapshot(
            id: TerminalGroupID(), name: try #require(TerminalGroupName(name)), root: root,
            focusedPaneID: ids[ids.count - 1], savedLayoutID: nil, panes: panes,
            retainedPaneCount: panes.count)
    }

    private func openRecord(_ snapshot: TerminalGroupSnapshot) throws
        -> TerminalGroupOpenTabRestorationRecord
    {
        try TerminalGroupOpenTabRestorationRecord(
            groupID: snapshot.id, name: snapshot.name, root: snapshot.root,
            focusedPaneID: snapshot.focusedPaneID, savedLayoutID: nil,
            panes: try snapshot.panes.map {
                try TerminalGroupOpenPaneRestorationRecord(
                    id: $0.id, explicitUserName: $0.explicitUserName, themeColor: nil,
                    kind: .ordinaryShell, launchProfile: $0.launchProfile)
            })
    }
}
