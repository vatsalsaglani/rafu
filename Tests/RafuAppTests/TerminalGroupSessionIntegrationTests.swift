import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Isolated saved-layout authority for WorkspaceSession integration tests.
/// It models the one shared actor, including the registered-before-list
/// stream contract, without reading Application Support.
actor TerminalGroupIntegrationStore: TerminalGroupSavedLayoutStoring {
    // Load-bearing under the RafuApp target's Swift 6.2 default-MainActor
    // mode: an implicit actor initializer inherits the nonisolated protocol
    // declaration and is rejected as an invalid nonisolated synchronous
    // actor initializer. Keep this initializer explicit.
    init() {}

    private var records:
        [TerminalGroupWorkspaceKey: [SavedTerminalGroupID: SavedTerminalGroupRecord]] = [:]
    private var revisions: [TerminalGroupWorkspaceKey: UInt64] = [:]
    private var listeners:
        [TerminalGroupWorkspaceKey: [AsyncStream<TerminalGroupSavedLayoutStoreChange>.Continuation]] =
            [:]
    private var listWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var changeWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var listCallCount = 0
    private var holdNextSave = false
    private var saveGate: CheckedContinuation<Void, Never>?
    private var saveStarted: CheckedContinuation<Void, Never>?
    private var didStartSave = false
    private var holdNextDelete = false
    private var deleteGate: CheckedContinuation<Void, Never>?
    private var deleteStarted: CheckedContinuation<Void, Never>?
    private var didStartDelete = false
    private var suspendedListCalls: Set<Int> = []
    private var listGates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var listStartedWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func loadSavedLayouts(for key: TerminalGroupWorkspaceKey) async throws
        -> TerminalGroupSavedLayoutEnvelope
    {
        try TerminalGroupSavedLayoutEnvelope(workspaceKey: key, groups: records[key] ?? [:])
    }

    func listSavedLayouts(for key: TerminalGroupWorkspaceKey) async throws
        -> [SavedTerminalGroupRecord]
    {
        listCallCount += 1
        let call = listCallCount
        let captured = (records[key] ?? [:]).values.sorted { $0.name.rawValue < $1.name.rawValue }
        resumeListWaiters()
        if suspendedListCalls.remove(call) != nil {
            await withCheckedContinuation { continuation in
                listGates[call] = continuation
                let waiters = listStartedWaiters.removeValue(forKey: call) ?? []
                for waiter in waiters { waiter.resume() }
            }
        }
        return captured
    }

    func saveSavedLayout(_ request: TerminalGroupSavedLayoutSaveRequest) async throws
        -> TerminalGroupSavedLayoutSaveResult
    {
        if holdNextSave {
            holdNextSave = false
            didStartSave = true
            saveStarted?.resume()
            saveStarted = nil
            await withCheckedContinuation { saveGate = $0 }
        }
        var value = records[request.workspaceKey] ?? [:]
        let record: SavedTerminalGroupRecord
        let disposition: TerminalGroupSavedLayoutSaveDisposition
        switch request.operation {
        case .firstSave, .saveAs:
            let id = SavedTerminalGroupID()
            record = try SavedTerminalGroupRecord(
                id: id, name: request.group.name, root: request.group.root,
                focusedPaneID: request.group.focusedPaneID, panes: request.group.panes)
            disposition = .created
        case .save(let id):
            guard value[id] != nil else { throw TerminalGroupPersistenceError.savedLayoutNotFound }
            record = request.group
            disposition = .updated
        }
        if value.values.contains(where: { $0.id != record.id && $0.name == record.name }) {
            throw TerminalGroupPersistenceError.nameConflict
        }
        value[record.id] = record
        records[request.workspaceKey] = value
        emit(for: request.workspaceKey)
        return TerminalGroupSavedLayoutSaveResult(
            savedLayoutID: record.id, disposition: disposition)
    }

    func deleteSavedLayout(_ request: TerminalGroupSavedLayoutDeleteRequest) async throws
        -> TerminalGroupSavedLayoutDeleteResult
    {
        if holdNextDelete {
            holdNextDelete = false
            didStartDelete = true
            deleteStarted?.resume()
            deleteStarted = nil
            await withCheckedContinuation { deleteGate = $0 }
        }
        guard records[request.workspaceKey]?.removeValue(forKey: request.savedLayoutID) != nil
        else {
            throw TerminalGroupPersistenceError.savedLayoutNotFound
        }
        emit(for: request.workspaceKey)
        return TerminalGroupSavedLayoutDeleteResult(removedSavedLayoutID: request.savedLayoutID)
    }

    func changes(for key: TerminalGroupWorkspaceKey) async -> AsyncStream<
        TerminalGroupSavedLayoutStoreChange
    > {
        let (stream, continuation) = AsyncStream<TerminalGroupSavedLayoutStoreChange>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        listeners[key, default: []].append(continuation)
        resumeChangeWaiters()
        continuation.yield(.init(workspaceKey: key, revision: revisions[key, default: 0]))
        return stream
    }

    func replace(_ values: [SavedTerminalGroupRecord], for key: TerminalGroupWorkspaceKey) {
        records[key] = Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0) })
        emit(for: key)
    }

    func savedRecords(for key: TerminalGroupWorkspaceKey) -> [SavedTerminalGroupRecord] {
        (records[key] ?? [:]).values.sorted { $0.name.rawValue < $1.name.rawValue }
    }

    func waitForListCall(_ minimum: Int = 1) async {
        guard listCallCount < minimum else { return }
        await withCheckedContinuation { listWaiters[minimum, default: []].append($0) }
    }

    func suspendListCall(_ call: Int) { suspendedListCalls.insert(call) }

    func waitForListStart(_ call: Int) async {
        guard listGates[call] == nil else { return }
        await withCheckedContinuation { listStartedWaiters[call, default: []].append($0) }
    }

    func releaseListCall(_ call: Int) {
        listGates.removeValue(forKey: call)?.resume()
    }

    func waitForSubscribers(_ minimum: Int) async {
        guard listeners.values.reduce(0, { $0 + $1.count }) < minimum else { return }
        await withCheckedContinuation { changeWaiters[minimum, default: []].append($0) }
    }

    func suspendNextSave() { holdNextSave = true }

    func waitForSaveStart() async {
        guard !didStartSave else { return }
        await withCheckedContinuation { saveStarted = $0 }
    }

    func releaseSave() {
        saveGate?.resume()
        saveGate = nil
    }

    func suspendNextDelete() { holdNextDelete = true }

    func waitForDeleteStart() async {
        guard !didStartDelete else { return }
        await withCheckedContinuation { deleteStarted = $0 }
    }

    func releaseDelete() {
        deleteGate?.resume()
        deleteGate = nil
    }

    private func emit(for key: TerminalGroupWorkspaceKey) {
        revisions[key, default: 0] &+= 1
        let change = TerminalGroupSavedLayoutStoreChange(
            workspaceKey: key, revision: revisions[key, default: 0])
        for listener in listeners[key, default: []] {
            listener.yield(change)
        }
    }

    private func resumeListWaiters() {
        let ready = listWaiters.filter { $0.key <= listCallCount }
        for (minimum, waiters) in ready {
            listWaiters.removeValue(forKey: minimum)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }

    private func resumeChangeWaiters() {
        let count = listeners.values.reduce(0) { $0 + $1.count }
        let ready = changeWaiters.filter { count >= $0.key }
        for (minimum, waiters) in ready {
            changeWaiters.removeValue(forKey: minimum)
            for waiter in waiters {
                waiter.resume()
            }
        }
    }
}

actor TerminalGroupIntegrationSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        signalled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        guard !signalled else { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor
func makeTerminalGroupWorkspace() throws -> (WorkspaceSession, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RafuTerminalGroupTests.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: "Terminal Group Test",
        location: .local(LocalWorkspaceReference(path: root.path)))
    return (session, root)
}

@MainActor
func removeTerminalGroupWorkspace(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

@MainActor
func installTerminalGroupStore(
    _ store: TerminalGroupIntegrationStore, on session: WorkspaceSession
) {
    session.terminalGroupSavedLayoutStore = store
    session.beginTerminalGroupLibraryForTesting()
}

func savedRecord(from snapshot: TerminalGroupSnapshot) throws -> SavedTerminalGroupRecord {
    try TerminalGroupRestorationCodec().savedRecord(
        from: snapshot, savedLayoutID: SavedTerminalGroupID())
}

func openRecord(from record: SavedTerminalGroupRecord) throws
    -> TerminalGroupOpenTabRestorationRecord
{
    let instantiation = try TerminalGroupSavedLayoutInstantiation(savedGroup: record)
    return try TerminalGroupOpenTabRestorationRecord(
        groupID: instantiation.groupID, name: instantiation.name, root: instantiation.root,
        focusedPaneID: instantiation.focusedPaneID, savedLayoutID: instantiation.savedLayoutID,
        panes: instantiation.panes)
}

func inertSavedRecord(name: String, folder: TerminalWorkspaceRelativePath) throws
    -> SavedTerminalGroupRecord
{
    let paneID = SavedTerminalPaneID()
    return try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(), name: try #require(TerminalGroupName(name)),
        root: .pane(paneID),
        focusedPaneID: paneID,
        panes: [
            try SavedTerminalPaneRecord(
                id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: .init(shell: .preferredShell, startingFolder: folder))
        ])
}

@MainActor
@Test("New terminal creates one compound outer tab and one child controller")
func workspaceSessionCreatesOneTerminalGroupOuterTab() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }

    session.newTerminalGroup()

    #expect(session.terminal.sessions.count == 1)
    #expect(session.terminal.terminalGroups.count == 1)
    let tab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.first)
    guard case .terminalGroup(let groupID) = tab.resource else {
        Issue.record("Expected one compound Terminal Group editor resource")
        return
    }
    #expect(session.selectedTerminalGroupID == groupID)
    #expect(session.terminal.terminalGroup(groupID)?.panes.count == 1)
    #expect(session.focusedTerminalSession?.id == session.terminal.sessions.first?.id)
}

@MainActor
@Test("Right and down splits keep one outer tab and focus their new pane")
func workspaceSessionSplitsInsideTerminalGroup() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let outerTabCount = session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs
        .count

    session.splitFocusedTerminalPane(.right)
    let rightFocused = try #require(session.focusedTerminalPaneID)
    session.splitFocusedTerminalPane(.down)

    let snapshot = try #require(session.terminal.terminalGroup(groupID))
    #expect(snapshot.panes.count == 3)
    #expect(session.terminal.sessions.count == 3)
    #expect(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.count
            == outerTabCount)
    #expect(snapshot.focusedPaneID != rightFocused)
    #expect(
        session.focusedTerminalSession?.id
            == session.terminal.terminalController(for: snapshot.focusedPaneID)?.id)
}

@MainActor
@Test("Changing a pane folder is inherited by its split child")
func workspaceSessionInheritsChangedFolderWhenSplitting() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let paneID = try #require(session.focusedTerminalPaneID)

    session.setTerminalPaneStartingFolder(paneID, to: child)
    session.splitFocusedTerminalPane(.right)

    let expected = try #require(TerminalWorkspaceRelativePath("child"))
    #expect(
        session.terminal.terminalGroup(groupID)?.panes.allSatisfy {
            $0.launchProfile?.startingFolder == expected
        } == true)
}

@MainActor
@Test("A legacy ungrouped session adopts one compound group on reveal")
func workspaceSessionAdoptsLegacySessionOnReveal() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let shell = TerminalShell(path: "/bin/zsh", name: "zsh", isDefault: true)
    let controller = session.terminal.newSession(startingDirectory: root.path, shell: shell)

    session.revealTerminalSession(controller.id)

    let groupID = try #require(session.terminal.terminalGroupAndPane(containing: controller.id)?.0)
    #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: groupID)) != nil)
    #expect(
        session.editorTabSwitcherCandidates.filter {
            $0.destination == .terminalGroup(groupID: groupID)
        }.count == 1)
}

@MainActor
@Test("Non-last pane close collapses, and last pane requests group close")
func workspaceSessionClosesPaneThenGroup() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    session.splitFocusedTerminalPane(.right)
    let paneID = try #require(session.focusedTerminalPaneID)

    session.closeTerminalPane(paneID)
    #expect(session.terminal.terminalGroup(groupID)?.panes.count == 1)
    #expect(session.pendingTerminalGroupClose == nil)

    let remaining = try #require(session.terminal.terminalGroup(groupID)?.panes.first?.id)
    try #require(session.terminal.terminalController(for: remaining)).markRunningForTesting()
    session.closeTerminalPane(remaining)
    #expect(session.pendingTerminalGroupClose != nil)
    session.confirmTerminalGroupClose()
    #expect(session.terminal.terminalGroup(groupID) == nil)
}

@MainActor
@Test("Grouped child sessions are not repeated as legacy parked candidates")
func workspaceSessionDoesNotDuplicateGroupedChildrenInLegacyParking() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let childIDs = Set(session.terminal.terminalGroup(groupID)?.panes.compactMap(\.sessionID) ?? [])

    #expect(session.presentedTerminalSessionIDs == childIDs)
    #expect(session.parkedTerminalSessions.isEmpty)
    session.hideTerminalGroup(groupID)
    #expect(session.parkedTerminalGroupIDs == [groupID])
    #expect(session.parkedTerminalSessions.isEmpty)
    #expect(
        session.editorTabSwitcherCandidates.filter {
            $0.destination == .terminalGroup(groupID: groupID)
        }.count == 1)
}

@MainActor
@Test("A selected in-root file directory becomes the new group folder")
func workspaceSessionUsesSelectedInRootDirectoryForNewGroup() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let child = root.appendingPathComponent("child", isDirectory: true)
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let file = child.appendingPathComponent("a.swift")
    FileManager.default.createFile(atPath: file.path, contents: Data())
    let document = EditorDocument(url: file)
    session.openDocuments = [document]
    session.selectedDocumentID = document.id

    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let profile = try #require(session.terminal.terminalGroup(groupID)?.panes.first?.launchProfile)
    #expect(profile.startingFolder == TerminalWorkspaceRelativePath("child"))
}

@MainActor
@Test("Outside or missing selected paths fall back to the workspace root")
func workspaceSessionFallsBackToRootForUnsafeSelectedDirectory() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let outside = FileManager.default.temporaryDirectory
        .appendingPathComponent("RafuOutside.\(UUID().uuidString).swift")
    FileManager.default.createFile(atPath: outside.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: outside) }
    let document = EditorDocument(url: outside)
    session.openDocuments = [document]
    session.selectedDocumentID = document.id

    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let profile = try #require(session.terminal.terminalGroup(groupID)?.panes.first?.launchProfile)
    #expect(profile.startingFolder == .root)
}

@MainActor
@Test("A symlink escape and a missing selected directory both fall back to root")
func workspaceSessionFallsBackToRootForMissingAndSymlinkSelectedDirectory() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let link = root.appendingPathComponent("escape", isDirectory: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let file = link.appendingPathComponent("a.swift")
    let document = EditorDocument(url: file)
    session.openDocuments = [document]
    session.selectedDocumentID = document.id

    session.newTerminalGroup()
    let first = try #require(session.selectedTerminalGroupID)
    #expect(
        session.terminal.terminalGroup(first)?.panes.first?.launchProfile?.startingFolder == .root)

    session.openDocuments = [EditorDocument(url: root.appendingPathComponent("missing/a.swift"))]
    session.selectedDocumentID = session.openDocuments.first?.id
    session.newTerminalGroup()
    let second = try #require(session.selectedTerminalGroupID)
    #expect(
        session.terminal.terminalGroup(second)?.panes.first?.launchProfile?.startingFolder == .root)
}

@MainActor
@Test("Saved layouts open inertly twice with distinct runtime identities")
func workspaceSessionOpensSavedLayoutTwiceInertly() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    let store = TerminalGroupIntegrationStore()
    installTerminalGroupStore(store, on: session)
    let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
    await store.waitForSubscribers(1)
    await store.waitForListCall(1)
    await session.waitForTerminalGroupStoreOperationForTesting()
    session.newTerminalGroup()
    let source = try #require(session.terminal.terminalGroups.first)
    let record = try savedRecord(from: source)
    await store.replace([record], for: key)
    await store.waitForListCall(2)
    await session.waitForTerminalGroupStoreOperationForTesting()

    session.openSavedTerminalGroup(record.id)
    session.openSavedTerminalGroup(record.id)
    let copies = session.terminal.terminalGroups.filter { $0.savedLayoutID == record.id }
    #expect(copies.count == 2)
    #expect(Set(copies.map(\.id)).count == 2)
    #expect(
        copies.allSatisfy { $0.panes.allSatisfy { $0.sessionID == nil && $0.status == .stopped } })
}

@MainActor
@Test("Two workspace sessions bind one store but keep editor state independent")
func workspaceSessionWindowsShareLibraryWithoutSharingSelection() async throws {
    let (first, root) = try makeTerminalGroupWorkspace()
    let (second, secondRoot) = try makeTerminalGroupWorkspace()
    defer {
        first.teardownTerminalGroups()
        second.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
        removeTerminalGroupWorkspace(secondRoot)
    }
    second.descriptor = WorkspaceDescriptor(
        displayName: "Same", location: .local(LocalWorkspaceReference(path: root.path)))
    let store = TerminalGroupIntegrationStore()
    installTerminalGroupStore(store, on: first)
    installTerminalGroupStore(store, on: second)
    await store.waitForSubscribers(2)
    await store.waitForListCall(2)
    await first.waitForTerminalGroupStoreOperationForTesting()
    await second.waitForTerminalGroupStoreOperationForTesting()
    let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
    first.newTerminalGroup()
    let record = try savedRecord(from: try #require(first.terminal.terminalGroups.first))
    await store.replace([record], for: key)
    await store.waitForListCall(4)
    await first.waitForTerminalGroupStoreOperationForTesting()
    await second.waitForTerminalGroupStoreOperationForTesting()

    #expect(first.savedTerminalGroups.map(\.id) == [record.id])
    #expect(second.savedTerminalGroups.map(\.id) == [record.id])
    #expect(second.terminal.terminalGroups.isEmpty)
    #expect(first.selectedTerminalGroupID != nil)
    #expect(second.selectedTerminalGroupID == nil)

    let firstGroupID = try #require(first.selectedTerminalGroupID)
    first.requestTerminalGroupSaveAs(firstGroupID)
    #expect(first.pendingTerminalGroupSaveRequest != nil)
    #expect(second.pendingTerminalGroupSaveRequest == nil)
    second.newTerminalGroup()
    let secondPane = try #require(second.focusedTerminalPaneID)
    let secondGroupID = try #require(second.selectedTerminalGroupID)
    second.terminal.terminalController(for: secondPane)?.markRunningForTesting()
    second.requestTerminalGroupClose(secondGroupID)
    #expect(second.pendingTerminalGroupClose != nil)
    #expect(first.pendingTerminalGroupClose == nil)

    var firstLifecycleCount = 0
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/bin/echo"), arguments: [],
        currentDirectoryPath: root.path, environment: [:], roleBadge: "Agent", agentProvider: .codex
    )
    let classified = try first.insertClassifiedTerminalSession(
        spec: spec, kind: .directAgentTerminal(provider: .codex)
    ) { firstLifecycleCount += 1 }
    second.teardownTerminalGroups()
    #expect(firstLifecycleCount == 0)
    first.ownerHandledTerminalLifecycleClose(classified)
}

@MainActor
@Test("A same-generation old list result cannot overwrite a newer list result")
func workspaceSessionRejectsOutOfOrderSameGenerationLists() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    let store = TerminalGroupIntegrationStore()
    let key = TerminalGroupWorkspaceKey(standardizedRoot: root)
    await store.suspendListCall(1)
    installTerminalGroupStore(store, on: session)
    await store.waitForListStart(1)

    session.newTerminalGroup()
    let record = try savedRecord(from: try #require(session.terminal.terminalGroups.first))
    await store.replace([record], for: key)
    await store.waitForListCall(2)
    await session.waitForTerminalGroupStoreOperationForTesting()
    #expect(session.savedTerminalGroups.map(\.id) == [record.id])

    let oldListFinished = TerminalGroupIntegrationSignal()
    session.terminalGroupListFinishedForTesting = { epoch in
        if epoch == 1 { Task { await oldListFinished.signal() } }
    }
    await store.releaseListCall(1)
    await oldListFinished.wait()
    #expect(session.savedTerminalGroups.map(\.id) == [record.id])
    #expect(session.terminalGroupStoreError == nil)
}

@MainActor
@Test("Save, Save As, and Delete use one mutation at a time and detach open instances")
func workspaceSessionSavesAndDeletesThroughItsInjectedStore() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)

    session.requestTerminalGroupSave(groupID)
    #expect(session.isTerminalGroupStoreMutationInFlight)
    await session.waitForTerminalGroupStoreOperationForTesting()
    let savedID = try #require(session.terminal.terminalGroup(groupID)?.savedLayoutID)
    #expect(!session.isTerminalGroupStoreMutationInFlight)

    session.requestTerminalGroupSaveAs(groupID)
    #expect(session.pendingTerminalGroupSaveRequest?.kind == .saveAs)
    session.updatePendingTerminalGroupSaveName("Copy")
    await store.suspendNextSave()
    let saveStarted = Task { await store.waitForSaveStart() }
    session.completePendingTerminalGroupSave()
    await saveStarted.value
    #expect(session.isTerminalGroupStoreMutationInFlight)
    session.requestTerminalGroupSaveAs(groupID)
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    await store.releaseSave()
    await session.waitForTerminalGroupStoreOperationForTesting()
    let replacement = try #require(session.terminal.terminalGroup(groupID))
    let replacementID = try #require(replacement.savedLayoutID)
    #expect(replacementID != savedID)
    #expect(replacement.name.rawValue == "Copy")
    let savedRecords = await store.savedRecords(
        for: TerminalGroupWorkspaceKey(standardizedRoot: root))
    #expect(Set(savedRecords.map(\.id)) == Set([savedID, replacementID]))

    session.deleteSavedTerminalGroup(replacementID)
    await session.waitForTerminalGroupStoreOperationForTesting()
    #expect(session.terminal.terminalGroup(groupID)?.savedLayoutID == nil)
}

@MainActor
@Test("A stale Save completion cannot commit after workspace teardown")
func workspaceSessionRejectsStaleSaveCompletion() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    await store.suspendNextSave()
    let started = Task { await store.waitForSaveStart() }
    session.requestTerminalGroupSave(groupID)
    await started.value
    #expect(session.isTerminalGroupStoreMutationInFlight)

    session.teardownTerminalGroups()
    await store.releaseSave()
    #expect(session.terminal.terminalGroups.isEmpty)
    #expect(!session.isTerminalGroupStoreMutationInFlight)
}

@MainActor
@Test("Stale Save As and Delete completions cannot mutate a replacement workspace")
func workspaceSessionRejectsStaleSaveAsAndDeleteCompletions() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    let replacementRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "RafuTerminalGroupReplacement.\(UUID().uuidString)", isDirectory: true)
    let finalRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("RafuTerminalGroupFinal.\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: replacementRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: finalRoot, withIntermediateDirectories: true)
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
        removeTerminalGroupWorkspace(replacementRoot)
        removeTerminalGroupWorkspace(finalRoot)
    }
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    session.requestTerminalGroupSave(groupID)
    await session.waitForTerminalGroupStoreOperationForTesting()
    let originalSavedID = try #require(session.terminal.terminalGroup(groupID)?.savedLayoutID)

    await store.suspendNextSave()
    let saveStarted = Task { await store.waitForSaveStart() }
    session.requestTerminalGroupSaveAs(groupID)
    session.updatePendingTerminalGroupSaveName("Stale copy")
    session.completePendingTerminalGroupSave()
    await saveStarted.value
    session.openLocalWorkspace(at: replacementRoot)
    await store.releaseSave()
    #expect(session.terminal.terminalGroups.isEmpty)
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    #expect(session.terminalGroupStoreError == nil)

    session.newTerminalGroup()
    _ = try #require(session.selectedTerminalGroupID)
    await store.suspendNextDelete()
    let deleteStarted = Task { await store.waitForDeleteStart() }
    session.deleteSavedTerminalGroup(originalSavedID)
    await deleteStarted.value
    session.openLocalWorkspace(at: finalRoot)
    session.newTerminalGroup()
    let newGroupID = try #require(session.selectedTerminalGroupID)
    let newGroupName = try #require(session.terminal.terminalGroup(newGroupID)?.name)
    await store.releaseDelete()
    await Task.yield()

    let replacement = try #require(session.terminal.terminalGroup(newGroupID))
    #expect(replacement.id == newGroupID)
    #expect(replacement.name == newGroupName)
    #expect(replacement.savedLayoutID == nil)
    #expect(session.terminalGroupStoreError == nil)
}

@MainActor
@Test("A shared Delete refresh detaches another window and retains its own state")
func workspaceSessionExternalDeleteDetachesMatchingOpenGroup() async throws {
    let (first, root) = try makeTerminalGroupWorkspace()
    let second = WorkspaceSession()
    second.descriptor = WorkspaceDescriptor(
        displayName: "Second", location: .local(LocalWorkspaceReference(path: root.path)))
    defer {
        first.teardownTerminalGroups()
        second.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    let store = TerminalGroupIntegrationStore()
    installTerminalGroupStore(store, on: first)
    installTerminalGroupStore(store, on: second)
    await store.waitForSubscribers(2)
    await store.waitForListCall(2)
    await first.waitForTerminalGroupStoreOperationForTesting()
    await second.waitForTerminalGroupStoreOperationForTesting()
    first.newTerminalGroup()
    let groupID = try #require(first.selectedTerminalGroupID)
    first.requestTerminalGroupSave(groupID)
    await first.waitForTerminalGroupStoreOperationForTesting()
    let savedID = try #require(first.terminal.terminalGroup(groupID)?.savedLayoutID)
    await store.waitForListCall(4)
    await second.waitForTerminalGroupStoreOperationForTesting()
    second.openSavedTerminalGroup(savedID)
    let secondGroupID = try #require(second.selectedTerminalGroupID)
    #expect(second.terminal.terminalGroup(secondGroupID)?.savedLayoutID == savedID)

    first.deleteSavedTerminalGroup(savedID)
    await first.waitForTerminalGroupStoreOperationForTesting()
    await store.waitForListCall(6)
    await second.waitForTerminalGroupStoreOperationForTesting()
    #expect(second.terminal.terminalGroup(secondGroupID)?.savedLayoutID == nil)
    #expect(second.terminal.terminalGroup(secondGroupID) != nil)
    #expect(
        second.terminalGroupWorkspaceRestorationForTesting()?.openGroups.contains {
            $0.groupID == secondGroupID
        } == false)
}

@MainActor
@Test("WorkspaceSession preserves editor state when live or retained capacity rejects a new group")
func workspaceSessionCapacityFailuresDoNotMutateEditorState() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    for _ in 0..<6 { session.newTerminalGroup() }
    let liveTabs = session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.count
    #expect(session.liveTerminalSessionCount == 6)
    session.newTerminalGroup()
    #expect(session.liveTerminalSessionCount == 6)
    #expect(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs.count == liveTabs)

    let (retainedSession, retainedRoot) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(retainedRoot) }
    for _ in 0..<TerminalGroupSnapshot.maximumRetainedPanesPerWindow {
        _ = try retainedSession.terminal.perform(.createGroup(name: nil))
    }
    let retainedTabs = retainedSession.editorLayout.group(
        id: retainedSession.editorLayout.focusedGroupID)?.tabs.count
    retainedSession.newTerminalGroup()
    #expect(retainedSession.retainedTerminalPaneCount == 24)
    #expect(
        retainedSession.editorLayout.group(id: retainedSession.editorLayout.focusedGroupID)?.tabs
            .count == retainedTabs)
}

@MainActor
@Test("Start All rejects a saved symlink escape before it reveals or starts a pane")
func workspaceSessionStartAllRejectsEscapedFolderWithoutMutation() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    let link = root.appendingPathComponent("linked", isDirectory: true)
    let inside = root.appendingPathComponent("inside", isDirectory: true)
    try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: inside)
    let record = try inertSavedRecord(
        name: "Saved", folder: try #require(TerminalWorkspaceRelativePath("linked")))
    let decoded = try TerminalGroupRestorationCodec().openNamedLayout(record)
    let group = try session.terminal.insertInertSnapshot(decoded.snapshot)

    // The saved profile was valid when stored. Repointing the symlink before
    // Start All proves that the action revalidates at use time.
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

    session.startAllRestartableTerminalPanes(in: group.id)
    #expect(
        session.terminal.terminalGroup(group.id)?.panes.allSatisfy { $0.sessionID == nil } == true)
    #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: group.id)) == nil)
}

@MainActor
@Test("Start Pane starts an inert ordinary shell before revealing its group")
func workspaceSessionStartsStoppedPaneBeforeReveal() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let record = try inertSavedRecord(name: "Start", folder: .root)
    let decoded = try TerminalGroupRestorationCodec().openNamedLayout(record)
    let group = try session.terminal.insertInertSnapshot(decoded.snapshot)
    let paneID = try #require(session.terminal.terminalGroup(group.id)?.panes.first?.id)

    session.startTerminalPane(paneID)

    let pane = try #require(session.terminal.terminalGroup(group.id)?.panes.first)
    #expect(pane.sessionID != nil)
    #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: group.id)) != nil)
}

@MainActor
@Test("Start All validates stopped and exited panes before revealing the group")
func workspaceSessionStartAllHandlesStoppedAndExitedShellPanes() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer { removeTerminalGroupWorkspace(root) }
    let first = SavedTerminalPaneID()
    let second = SavedTerminalPaneID()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let record = try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Start all")),
        root: .split(
            id: SavedTerminalGroupSplitID(), axis: .columns, fraction: 0.5,
            first: .pane(first), second: .pane(second)),
        focusedPaneID: first,
        panes: [
            try SavedTerminalPaneRecord(
                id: first, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: profile),
            try SavedTerminalPaneRecord(
                id: second, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: profile),
        ])
    let decoded = try TerminalGroupRestorationCodec().openNamedLayout(record)
    let group = try session.terminal.insertInertSnapshot(decoded.snapshot)
    let firstPane = try #require(session.terminal.terminalGroup(group.id)?.panes.first?.id)
    session.startTerminalPane(firstPane)
    let firstController = try #require(session.terminal.terminalController(for: firstPane))
    let firstSessionID = firstController.id
    firstController.processDidTerminate(exitCode: 0)
    session.hideTerminalGroup(group.id)

    session.startAllRestartableTerminalPanes(in: group.id)

    let panes = try #require(session.terminal.terminalGroup(group.id)?.panes)
    #expect(
        panes.contains {
            $0.id == firstPane && $0.status == .live && $0.sessionID == firstSessionID
        })
    #expect(panes.contains { $0.id != firstPane && $0.status == .live && $0.sessionID != nil })
    #expect(session.editorLayout.tab(matching: .terminalGroup(groupID: group.id)) != nil)
}
