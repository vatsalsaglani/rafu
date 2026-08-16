import Foundation
import Testing

@testable import RafuApp

@MainActor
private final class TerminalGroupSaveCompletionSignal {
    private var didComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !didComplete else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func complete() {
        didComplete = true
        let currentWaiters = waiters
        waiters = []
        for waiter in currentWaiters {
            waiter.resume()
        }
    }
}

@Test("Terminal Group sheet name validation trims and bounds names")
func terminalGroupSheetNameValidation() {
    #expect(TerminalGroupSheetPresentation.validatedName("  Build  ") == .valid("Build"))
    #expect(
        TerminalGroupSheetPresentation.validatedName("   ")
            == .invalid("Enter a Terminal Group name of 80 Unicode scalars or fewer."))
    #expect(
        TerminalGroupSheetPresentation.validatedName(String(repeating: "x", count: 81))
            == .invalid("Enter a Terminal Group name of 80 Unicode scalars or fewer."))
    let multiScalar = String(repeating: "e\u{301}", count: 41)
    #expect(
        TerminalGroupSheetPresentation.validatedName(multiScalar)
            == .invalid("Enter a Terminal Group name of 80 Unicode scalars or fewer."))
    #expect(
        TerminalGroupSheetPresentation.validatedName(
            "  " + String(repeating: "x", count: 80) + "  ")
            == .valid(String(repeating: "x", count: 80)))
}

@Test("Terminal Group sheet layout summaries stay metadata-only")
func terminalGroupSheetLayoutSummaries() {
    let first = TerminalPaneID()
    let second = TerminalPaneID()
    let third = TerminalPaneID()
    let one = TerminalGroupNode.pane(first)
    let columns = TerminalGroupNode.split(
        id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5, first: .pane(first),
        second: .pane(second))
    let rows = TerminalGroupNode.split(
        id: TerminalGroupSplitID(), axis: .rows, fraction: 0.5, first: .pane(first),
        second: .pane(second))
    let nested = TerminalGroupNode.split(
        id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5, first: .pane(first),
        second: .split(
            id: TerminalGroupSplitID(), axis: .rows, fraction: 0.5, first: .pane(second),
            second: .pane(third)))
    #expect(TerminalGroupSheetPresentation.layoutSummary(one) == "1 pane")
    #expect(TerminalGroupSheetPresentation.layoutSummary(columns) == "2 panes, 1 side-by-side")
    #expect(TerminalGroupSheetPresentation.layoutSummary(rows) == "2 panes, 1 stacked")
    #expect(
        TerminalGroupSheetPresentation.layoutSummary(nested) == "3 panes, 1 side-by-side, 1 stacked"
    )
    #expect(
        !TerminalGroupSheetPresentation.layoutSummary(nested).contains(first.rawValue.uuidString))
}

@MainActor
@Test("Save and Rename cancellation preserves the open group")
func terminalGroupSheetRequestCancellationPreservesGroup() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let before = try #require(session.terminal.terminalGroup(groupID))
    session.requestTerminalGroupSaveAs(groupID)
    session.cancelPendingTerminalGroupSave()
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    #expect(session.terminal.terminalGroup(groupID) == before)
    session.requestTerminalGroupRename(groupID)
    session.cancelPendingTerminalGroupRename()
    #expect(session.pendingTerminalGroupRenameRequest == nil)
    #expect(session.terminal.terminalGroup(groupID) == before)
}

@MainActor
@Test("Save sheet keeps its request until the submitted save succeeds")
func terminalGroupSaveSheetSubmissionDismissesOnlyAfterSuccess() async throws {
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
    session.requestTerminalGroupSaveAs(groupID)
    session.updatePendingTerminalGroupSaveName("Saved layout")
    session.completePendingTerminalGroupSave()
    await saveStarted.value
    #expect(session.pendingTerminalGroupSaveRequest?.id == groupID)
    #expect(session.isPendingTerminalGroupSaveSubmission)
    await store.releaseSave()
    await session.waitForTerminalGroupStoreOperationForTesting()
    let saved = try #require(session.terminal.terminalGroup(groupID))
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    #expect(!session.isPendingTerminalGroupSaveSubmission)
    #expect(saved.name.rawValue == "Saved layout")
    #expect(saved.savedLayoutID != nil)
}

@MainActor
@Test("Save sheet retains its request and group state after a name conflict")
func terminalGroupSaveSheetConflictKeepsRequestAndGroup() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    let store = TerminalGroupIntegrationStore()
    session.terminalGroupSavedLayoutStore = store
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let firstID = try #require(session.selectedTerminalGroupID)
    session.requestTerminalGroupSaveAs(firstID)
    session.updatePendingTerminalGroupSaveName("Shared layout")
    session.completePendingTerminalGroupSave()
    await session.waitForTerminalGroupStoreOperationForTesting()
    session.newTerminalGroup()
    let secondID = try #require(session.selectedTerminalGroupID)
    let before = try #require(session.terminal.terminalGroup(secondID))
    session.requestTerminalGroupSaveAs(secondID)
    session.updatePendingTerminalGroupSaveName("Shared layout")
    session.completePendingTerminalGroupSave()
    await session.waitForTerminalGroupStoreOperationForTesting()
    #expect(session.pendingTerminalGroupSaveRequest?.id == secondID)
    #expect(!session.isPendingTerminalGroupSaveSubmission)
    #expect(session.terminal.terminalGroup(secondID) == before)
    #expect(session.terminalGroupStoreError?.isEmpty == false)
}

@MainActor
@Test("Save sheet cancellation before submission preserves group state")
func terminalGroupSaveSheetCancellationBeforeSubmitPreservesState() throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    let before = try #require(session.terminal.terminalGroup(groupID))
    session.requestTerminalGroupSaveAs(groupID)
    session.updatePendingTerminalGroupSaveName("Not saved")
    session.cancelPendingTerminalGroupSave()
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    #expect(!session.isPendingTerminalGroupSaveSubmission)
    #expect(session.terminal.terminalGroup(groupID) == before)
}

@MainActor
@Test("A stale save completion cannot dismiss a newer window request")
func staleTerminalGroupSaveCompletionKeepsNewerRequest() async throws {
    let (session, root) = try makeTerminalGroupWorkspace()
    let store = TerminalGroupIntegrationStore()
    let staleCompletion = TerminalGroupSaveCompletionSignal()
    session.terminalGroupSavedLayoutStore = store
    session.terminalGroupSaveTaskFinishedForTesting = {
        staleCompletion.complete()
    }
    defer {
        session.teardownTerminalGroups()
        removeTerminalGroupWorkspace(root)
    }
    session.newTerminalGroup()
    let firstID = try #require(session.selectedTerminalGroupID)
    await store.suspendNextSave()
    let saveStarted = Task { await store.waitForSaveStart() }
    session.requestTerminalGroupSaveAs(firstID)
    session.completePendingTerminalGroupSave()
    await saveStarted.value
    session.teardownTerminalGroups()
    session.newTerminalGroup()
    let newerID = try #require(session.selectedTerminalGroupID)
    session.requestTerminalGroupSaveAs(newerID)
    await store.releaseSave()
    await staleCompletion.wait()
    #expect(session.pendingTerminalGroupSaveRequest?.id == newerID)
    #expect(!session.isPendingTerminalGroupSaveSubmission)
    #expect(session.terminalGroupStoreError == nil)
}

@MainActor
@Test("Save sheet cancellation cannot dismiss a suspended submission")
func terminalGroupSaveSheetCancellationDuringSubmissionWaitsForSuccess() async throws {
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
    session.requestTerminalGroupSaveAs(groupID)
    session.completePendingTerminalGroupSave()
    await saveStarted.value
    session.cancelPendingTerminalGroupSave()
    #expect(session.pendingTerminalGroupSaveRequest?.id == groupID)
    #expect(session.isPendingTerminalGroupSaveSubmission)
    await store.releaseSave()
    await session.waitForTerminalGroupStoreOperationForTesting()
    #expect(session.pendingTerminalGroupSaveRequest == nil)
    #expect(!session.isPendingTerminalGroupSaveSubmission)
}

@Test("Save sheet source keeps invalid drafts and in-flight sheets disabled")
func terminalGroupSaveSheetDisableAndDismissAudit() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: root.appending(path: "Sources/RafuApp/Views/TerminalGroupSaveSheet.swift"),
        encoding: .utf8)
    #expect(
        source.contains(".disabled(session.isPendingTerminalGroupSaveSubmission || !isNameValid)"))
    #expect(
        source.contains(".interactiveDismissDisabled(session.isPendingTerminalGroupSaveSubmission)")
    )
    #expect(source.contains("TerminalGroupSheetPresentation.validatedName(name)"))
}

@MainActor
@Test("Terminal Group presentation requests reset during teardown")
func terminalGroupPresentationRequestsResetDuringTeardown() throws {
    let session = WorkspaceSession()
    session.newTerminalGroup()
    let groupID = try #require(session.selectedTerminalGroupID)
    session.requestTerminalGroupRename(groupID)
    session.teardownTerminalGroups()
    #expect(session.pendingTerminalGroupRenameRequest == nil)
    #expect(session.pendingTerminalPaneStartingFolderRequest == nil)
}
