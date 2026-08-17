import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Test("Workspace restoration inserts saved groups inertly and preserves focused pane")
func workspaceSessionRestoresSavedGroupWithoutController() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    session.newTerminalGroup()
    session.splitFocusedTerminalPane(.right)
    let snapshot = try #require(session.terminal.terminalGroups.first)
    let record = try savedRecord(from: snapshot)
    let open = try openRecord(from: record)
    let restoration = try TerminalGroupWorkspaceRestoration(openGroups: [open])
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
    await store.replace([record], for: key)

    let restored = WorkspaceSession()
    restored.descriptor = WorkspaceDescriptor(
        displayName: "Restored", location: .local(LocalWorkspaceReference(path: root.path)))
    restored.terminalGroupSavedLayoutStore = store
    await restored.restoreTerminalGroupInstancesForTesting(restoration)
    let group = try #require(restored.terminal.terminalGroups.first)
    #expect(group.savedLayoutID == record.id)
    #expect(group.focusedPaneID == open.focusedPaneID)
    #expect(group.panes.allSatisfy { $0.sessionID == nil && $0.status == .stopped })
    #expect(restored.terminal.sessions.isEmpty)
    restored.revealTerminalGroup(group.id)
    #expect(restored.focusedTerminalPaneID == open.focusedPaneID)
}

@Test("Restoration keeps legacy terminal payloads tolerated but nonrestorable")
func workspaceSessionRetainsLegacyTerminalCompatibilityClassification() {
    let resource = EditorTabResource.terminal(sessionID: UUID())
    #expect(resource.restorationClassification(terminalGroups: nil) == .notRestorable)
    #expect(TerminalGroupWorkspaceRestoration.maximumOpenGroups == 20)
    #expect(TerminalGroupSnapshot.maximumRetainedPanesPerWindow == 200)
}

@Test("Malformed Terminal Group data keeps independent file layout data")
func workspaceSessionMalformedTerminalGroupFieldHasBoundedDiagnostic() throws {
    let workspace = RestorableWorkspace(
        bookmark: Data([1]), rootPath: "/workspace", openRelativePaths: ["README.md"],
        selectedRelativePath: "README.md", navigatorMode: .files,
        editorLayout: EditorLayoutRestoration(layout: EditorLayoutState()))
    let encoded = try JSONEncoder().encode(workspace)
    var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    object["terminalGroupRestoration"] = "invalid"
    let decoded = try JSONDecoder().decode(
        RestorableWorkspace.self, from: JSONSerialization.data(withJSONObject: object))

    #expect(decoded.openRelativePaths == ["README.md"])
    #expect(decoded.terminalGroupRestoration == nil)
    #expect(decoded.terminalGroupRestorationDiagnostics == [.malformedTerminalGroupField])
}

@MainActor
@Test("An invalid open record warning survives a later successful saved-library refresh")
func workspaceSessionRetainsRestorationWarningAcrossLibraryRefresh() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let snapshot = try #require(session.terminal.terminalGroups.first)
    let record = try savedRecord(from: snapshot)
    let open = try openRecord(from: record)
    let restoration = try TerminalGroupWorkspaceRestoration(openGroups: [open])
    let store = TerminalGroupIntegrationStore()
    let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
    await store.replace([record], for: key)
    session.terminalGroupSavedLayoutStore = store
    session.beginTerminalGroupLibraryForTesting()
    await store.waitForSubscribers(1)
    await store.waitForListCall(1)
    await session.waitForTerminalGroupStoreOperationForTesting()

    // Insert the same runtime ID after the library settled so restoration
    // rejects the record without clearing its durable diagnostic channel.
    let duplicate = try TerminalGroupRestorationCodec().restoreOpenInstance(open).snapshot
    _ = try session.terminal.insertInertSnapshot(duplicate)

    await session.restoreTerminalGroupInstancesForTesting(restoration)
    #expect(
        session.terminalGroupRestorationError == "One saved Terminal Group could not be restored.")
    await store.replace([record], for: key)
    await store.waitForListCall(2)
    await session.waitForTerminalGroupStoreOperationForTesting()
    #expect(session.terminalGroupStoreError == "One saved Terminal Group could not be restored.")
}

@MainActor
@Test("Workspace persistence retains only groups associated with a saved layout")
func workspaceSessionPersistsOnlySavedTerminalGroups() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    session.newTerminalGroup()
    let savedGroupID = try #require(session.selectedTerminalGroupID)
    session.requestTerminalGroupSave(savedGroupID)
    await session.waitForTerminalGroupStoreOperationForTesting()
    let savedLayoutID = try #require(session.terminal.terminalGroup(savedGroupID)?.savedLayoutID)
    session.newTerminalGroup()
    let unsavedGroupID = try #require(session.selectedTerminalGroupID)

    let envelope = try #require(session.terminalGroupWorkspaceRestorationForTesting())
    #expect(envelope.openGroups.map(\.groupID) == [savedGroupID])
    #expect(envelope.openGroups.map(\.savedLayoutID) == [savedLayoutID])
    #expect(!envelope.openGroups.contains { $0.groupID == unsavedGroupID })
}

@MainActor
@Test("Invalid restored group tabs are removed without changing surviving file selection")
func workspaceSessionRepairsInvalidRestoredGroupWithoutDroppingFileSelection() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let fileURL = root.appendingPathComponent("README.md")
    _ = FileManager.default.createFile(atPath: fileURL.path, contents: Data())
    let document = EditorDocument(url: fileURL)
    session.openDocuments = [document]
    let fileTab = EditorTabState(resource: .file(fileURL))
    let invalidGroupID = TerminalGroupID()
    let invalidTab = EditorTabState(resource: .terminalGroup(groupID: invalidGroupID))
    session.editorLayout.insert(fileTab, in: session.editorLayout.focusedGroupID)
    session.editorLayout.insert(invalidTab, in: session.editorLayout.focusedGroupID)
    session.editorLayout.select(fileTab.id, in: session.editorLayout.focusedGroupID)
    let restoration = EditorLayoutRestoration(layout: session.editorLayout)

    session.restoreEditorLayoutForTesting(
        restoration,
        terminalGroups: try TerminalGroupWorkspaceRestoration(openGroups: []),
        rootURL: root)

    let tabs = session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs ?? []
    #expect(tabs.map(\.resource) == [.file(fileURL)])
    #expect(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.selectedTabID
            == fileTab.id)
    #expect(session.selectedDocumentID == document.id)
}
