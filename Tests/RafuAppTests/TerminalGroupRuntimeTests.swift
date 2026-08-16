import Foundation
import Testing

@testable import RafuApp

@Test("Directional target query reports outer edges without mutating focus")
func directionalTargetQueryReportsOuterEdges() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = TerminalGroupID()
    let left = TerminalPaneID()
    let right = TerminalPaneID()
    let shell = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let leftPane = try TerminalPaneSnapshot(
        id: left, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped, launchProfile: shell,
        startAvailability: .available)
    let rightPane = try TerminalPaneSnapshot(
        id: right, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped, launchProfile: shell,
        startAvailability: .available)
    let snapshot = try TerminalGroupSnapshot(
        id: groupID, name: try #require(TerminalGroupName("Edges")),
        root: .split(
            id: TerminalGroupSplitID(), axis: .columns, fraction: 0.5, first: .pane(left),
            second: .pane(right)), focusedPaneID: left, savedLayoutID: nil,
        panes: [leftPane, rightPane], retainedPaneCount: 2)
    _ = try runtime.insertInertSnapshot(snapshot)
    #expect(runtime.directionalPaneTarget(in: groupID, direction: .left) == nil)
    #expect(runtime.directionalPaneTarget(in: groupID, direction: .right) == right)
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == left)
}

func createdGroupID(_ effect: TerminalGroupEffect) throws -> TerminalGroupID {
    guard case .insertEditorTab(let groupID) = effect else {
        throw TerminalGroupValidationError.invalidName
    }
    return groupID
}

@Test("Terminal Group splits insert after focus and keep a bounded pure tree")
func terminalGroupSplitsBuildExpectedTree() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let first = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)

    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let second = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .down))
    let third = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    let group = try #require(runtime.snapshot(groupID: groupID))

    #expect(group.root.paneIDs == [first, second, third])
    #expect(group.panes.allSatisfy { $0.status == .stopped })
    #expect(group.panes.allSatisfy { $0.sessionID == nil })
}

@Test("Right and down splits retain their exact nested tree shape")
func terminalGroupNestedSplitTreeShapeIsStable() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let first = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let second = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: first))
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .down))
    let third = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    let root = try #require(runtime.snapshot(groupID: groupID)?.root)

    guard case .split(_, .columns, _, let left, let right) = root,
        case .split(_, .rows, _, .pane(first), .pane(third)) = left,
        case .pane(second) = right
    else {
        Issue.record("Expected columns(rows(first, third), second)")
        return
    }
}

@Test("Directional focus uses normalized rectangles and does not wrap")
func terminalGroupDirectionalFocusUsesGeometry() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let first = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let second = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: first))
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .down))
    let third = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)

    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: first))
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .right))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == second)

    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .left))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == first)
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .up))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == first)

    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .down))
    // The right pane's centre is the nearest candidate in the down
    // half-plane; the lower nested leaf remains a valid but farther target.
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == second)
    #expect(third != second)
}

@Test("Directional focus covers every direction, tie-breaks by tree order, and never wraps")
func terminalGroupDirectionalFocusHasStableTieBreaks() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let first = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let second = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: first))
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .down))
    let third = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)

    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: first))
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .right))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == second)
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .left))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == first)
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .down))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == second)
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .up))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == first)

    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: third))
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .up))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == second)
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .left))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == first)
    _ = try runtime.perform(.focusDirection(groupID: groupID, direction: .up))
    #expect(runtime.snapshot(groupID: groupID)?.focusedPaneID == first)
}

@Test("Recursive close collapses nested splits without changing surviving order")
func terminalGroupRecursiveCloseCollapsesNestedTree() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let first = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let second = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    _ = try runtime.perform(.focusPane(groupID: groupID, paneID: first))
    _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .down))
    let third = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)

    let thirdToken = try runtimeCloseToken(runtime.perform(.prepareClose(.pane(third))))
    _ = try runtime.perform(.finalizeClose(thirdToken))
    #expect(runtime.snapshot(groupID: groupID)?.root.paneIDs == [first, second])
    let firstToken = try runtimeCloseToken(runtime.perform(.prepareClose(.pane(first))))
    _ = try runtime.perform(.finalizeClose(firstToken))
    #expect(runtime.snapshot(groupID: groupID)?.root == .pane(second))
}

@Test("Raw rename trims text and restores the next default name for empty input")
func terminalGroupRenameTrimsAndDefaults() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    try runtime.renameGroup(groupID, rawName: "  Named group  ")
    #expect(runtime.snapshot(groupID: groupID)?.name.rawValue == "Named group")
    try runtime.renameGroup(groupID, rawName: " \n ")
    #expect(runtime.snapshot(groupID: groupID)?.name.rawValue == "Terminal Group 2")
    let next = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    #expect(runtime.snapshot(groupID: next)?.name.rawValue == "Terminal Group 3")
}

@Test("Runtime rejects duplicate pane and session membership without mutation")
func terminalGroupRuntimeRejectsDuplicateMembership() throws {
    var runtime = TerminalGroupRuntime()
    let sessionID = UUID()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let firstPane = try TerminalPaneSnapshot(
        id: TerminalPaneID(), sessionID: sessionID, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .live, launchProfile: profile,
        startAvailability: .available)
    _ = try runtime.createLiveGroup(name: nil, sessionID: sessionID, pane: firstPane)
    let secondPane = try TerminalPaneSnapshot(
        id: TerminalPaneID(), sessionID: sessionID, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .live, launchProfile: profile,
        startAvailability: .available)

    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.createLiveGroup(name: nil, sessionID: sessionID, pane: secondPane)
    }
    let duplicateSessionID = UUID()
    let duplicatePane = try TerminalPaneSnapshot(
        id: firstPane.id, sessionID: duplicateSessionID, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .live, launchProfile: profile,
        startAvailability: .available)
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.createLiveGroup(name: nil, sessionID: duplicateSessionID, pane: duplicatePane)
    }
    #expect(runtime.retainedPaneCount == 1)
}

@MainActor
@Test("Decoded inert snapshots preserve named runtime IDs and start availability")
func terminalGroupInertSnapshotPreservesNamedDecodedIdentity() throws {
    let manager = WorkspaceTerminalManager()
    let firstPaneID = TerminalPaneID()
    let secondPaneID = TerminalPaneID()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let snapshot = try TerminalGroupSnapshot(
        id: TerminalGroupID(), name: try #require(TerminalGroupName("Decoded named")),
        root: .split(
            id: TerminalGroupSplitID(), axis: .columns, fraction: 0.3,
            first: .pane(firstPaneID), second: .pane(secondPaneID)),
        focusedPaneID: secondPaneID, savedLayoutID: SavedTerminalGroupID(),
        panes: [
            try TerminalPaneSnapshot(
                id: firstPaneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                launchProfile: profile, startAvailability: .unavailable),
            try TerminalPaneSnapshot(
                id: secondPaneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .unavailableAgentTerminal, themeColor: nil, status: .unavailable,
                launchProfile: nil, startAvailability: .unavailable),
        ], retainedPaneCount: 2)

    let inserted = try manager.insertInertSnapshot(snapshot)
    #expect(inserted == snapshot)
    #expect(manager.terminalGroup(snapshot.id) == snapshot)
    #expect(manager.sessions.isEmpty)
}

@MainActor
@Test("Decoded open-instance snapshots retain their one runtime identity")
func terminalGroupInertSnapshotPreservesOpenInstanceIdentity() throws {
    let manager = WorkspaceTerminalManager()
    let groupID = TerminalGroupID()
    let paneID = TerminalPaneID()
    let snapshot = try inertSnapshot(groupID: groupID, paneID: paneID)

    _ = try manager.insertInertSnapshot(snapshot)
    #expect(manager.terminalGroup(groupID)?.id == groupID)
    #expect(manager.terminalGroup(groupID)?.focusedPaneID == paneID)
    #expect(manager.terminalGroup(groupID)?.panes.first?.id == paneID)
}

@Test("Inert snapshot insertion rejects duplicate group or pane identity without mutation")
func terminalGroupInertSnapshotRejectsDuplicateMembership() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = TerminalGroupID()
    let paneID = TerminalPaneID()
    let first = try inertSnapshot(groupID: groupID, paneID: paneID)
    _ = try runtime.insertInertSnapshot(first)
    let before = runtime.snapshots
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(first)
    }
    let duplicatePane = try inertSnapshot(groupID: TerminalGroupID(), paneID: paneID)
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(duplicatePane)
    }
    #expect(runtime.snapshots == before)
}

@Test("Inert snapshot insertion rejects live-session state without mutation")
func terminalGroupInertSnapshotRejectsNonInertPaneState() throws {
    var runtime = TerminalGroupRuntime()
    let paneID = TerminalPaneID()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let live = try TerminalGroupSnapshot(
        id: TerminalGroupID(), name: try #require(TerminalGroupName("Live")), root: .pane(paneID),
        focusedPaneID: paneID, savedLayoutID: nil,
        panes: [
            try TerminalPaneSnapshot(
                id: paneID, sessionID: UUID(), explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .ordinaryShell, themeColor: nil, status: .live, launchProfile: profile,
                startAvailability: .available)
        ], retainedPaneCount: 1)
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(live)
    }
    #expect(runtime.snapshots.isEmpty)
}

@Test("Inert snapshot insertion rejects the retained-pane boundary without mutation")
func terminalGroupInertSnapshotRespectsRetainedCapacity() throws {
    var runtime = TerminalGroupRuntime()
    for _ in 0..<24 {
        _ = try runtime.perform(.createGroup(name: nil))
    }
    let before = runtime.snapshots
    let snapshot = try inertSnapshot(groupID: TerminalGroupID(), paneID: TerminalPaneID())
    #expect(throws: TerminalGroupCapacityError.retainedPaneLimitExceeded(current: 24, requested: 1))
    {
        try runtime.insertInertSnapshot(snapshot)
    }
    #expect(runtime.snapshots == before)
}

@Test("Inert snapshot insertion rejects a split identity used by another group")
func terminalGroupInertSnapshotRejectsDuplicateSplitIdentity() throws {
    var runtime = TerminalGroupRuntime()
    let existing = try inertSplitSnapshot(
        groupID: TerminalGroupID(), firstPaneID: TerminalPaneID(), secondPaneID: TerminalPaneID(),
        splitID: TerminalGroupSplitID())
    _ = try runtime.insertInertSnapshot(existing)
    let before = runtime.snapshots
    let duplicate = try inertSplitSnapshot(
        groupID: TerminalGroupID(), firstPaneID: TerminalPaneID(), secondPaneID: TerminalPaneID(),
        splitID: try #require(existing.root.splitIDs.first))
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(duplicate)
    }
    #expect(runtime.snapshots == before)
}

@Test("Inert snapshot insertion rejects non-TG-22 pane kinds and live metadata")
func terminalGroupInertSnapshotRejectsNonTG22PaneDomain() throws {
    var runtime = TerminalGroupRuntime()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)

    let directPaneID = TerminalPaneID()
    let direct = try TerminalGroupSnapshot(
        id: TerminalGroupID(), name: try #require(TerminalGroupName("Direct")),
        root: .pane(directPaneID), focusedPaneID: directPaneID, savedLayoutID: nil,
        panes: [
            try TerminalPaneSnapshot(
                id: directPaneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .directAgentTerminal(provider: .codex), themeColor: nil,
                status: .stopped, launchProfile: profile, startAvailability: .available)
        ], retainedPaneCount: 1)
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(direct)
    }

    let missingProfilePaneID = TerminalPaneID()
    let missingProfile = try TerminalGroupSnapshot(
        id: TerminalGroupID(), name: try #require(TerminalGroupName("No profile")),
        root: .pane(missingProfilePaneID), focusedPaneID: missingProfilePaneID, savedLayoutID: nil,
        panes: [
            try TerminalPaneSnapshot(
                id: missingProfilePaneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
                runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                launchProfile: nil, startAvailability: .available)
        ], retainedPaneCount: 1)
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(missingProfile)
    }

    let titledPaneID = TerminalPaneID()
    let titled = try TerminalGroupSnapshot(
        id: TerminalGroupID(), name: try #require(TerminalGroupName("Titled")),
        root: .pane(titledPaneID), focusedPaneID: titledPaneID, savedLayoutID: nil,
        panes: [
            try TerminalPaneSnapshot(
                id: titledPaneID, sessionID: nil, explicitUserName: nil,
                reportedTitle: TerminalReportedTitle("OSC")!,
                runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
                launchProfile: profile, startAvailability: .available)
        ], retainedPaneCount: 1)
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.insertInertSnapshot(titled)
    }
    #expect(runtime.snapshots.isEmpty)
}

@Test("Duplicate group names have deterministic runtime UUID ordering")
func terminalGroupSnapshotOrderingBreaksEqualNamesByRuntimeID() throws {
    var runtime = TerminalGroupRuntime()
    let firstID = TerminalGroupID(
        rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
    let secondID = TerminalGroupID(
        rawValue: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
    let second = try inertSnapshot(groupID: secondID, paneID: TerminalPaneID())
    let first = try inertSnapshot(groupID: firstID, paneID: TerminalPaneID())
    _ = try runtime.insertInertSnapshot(second)
    _ = try runtime.insertInertSnapshot(first)
    #expect(runtime.snapshots.map(\.id) == [firstID, secondID])
}

@Test("Divider fractions normalize and saved layout deletion detaches every open group")
func terminalGroupNormalizesFractionsAndDetachesLayouts() throws {
    var runtime = TerminalGroupRuntime()
    let firstID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let secondID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    _ = try runtime.perform(.splitFocusedPane(groupID: firstID, placement: .right))
    let splitID = try #require(runtime.snapshot(groupID: firstID)?.root.splitIDs.first)
    _ = try runtime.perform(.setDividerFraction(splitID: splitID, fraction: 99))
    #expect(
        runtime.snapshot(groupID: firstID)?.root.normalizedFractions()
            == runtime.snapshot(groupID: firstID)?.root)

    let savedID = SavedTerminalGroupID()
    let savedName = try #require(TerminalGroupName("Saved terminal group"))
    _ = try runtime.perform(
        .commitSavedLayout(groupID: firstID, savedLayoutID: savedID, name: savedName))
    _ = try runtime.perform(
        .commitSavedLayout(groupID: secondID, savedLayoutID: savedID, name: savedName))
    #expect(runtime.snapshot(groupID: firstID)?.savedLayoutID == savedID)
    #expect(runtime.snapshot(groupID: firstID)?.name == savedName)
    #expect(runtime.snapshot(groupID: secondID)?.savedLayoutID == savedID)
    #expect(runtime.snapshot(groupID: secondID)?.name == savedName)
    _ = try runtime.perform(.detachDeletedSavedLayout(savedID))
    #expect(runtime.snapshot(groupID: firstID)?.savedLayoutID == nil)
    #expect(runtime.snapshot(groupID: secondID)?.savedLayoutID == nil)
    #expect(runtime.snapshot(groupID: firstID)?.name == savedName)
    #expect(runtime.snapshot(groupID: secondID)?.name == savedName)
}

@Test("Pure start commands cannot create a live pane without a controller binding")
func terminalGroupPureStartHasNoProcessOrMembershipSideEffect() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    let paneID = try #require(runtime.snapshot(groupID: groupID)?.focusedPaneID)
    let before = try #require(runtime.snapshot(groupID: groupID))
    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try runtime.perform(.startPane(paneID))
    }
    #expect(runtime.snapshot(groupID: groupID) == before)
}

private func runtimeCloseToken(_ effect: TerminalGroupEffect) throws -> TerminalGroupCloseToken {
    guard case .requestCloseConfirmation(let token) = effect else {
        throw TerminalGroupValidationError.staleCloseToken
    }
    return token
}

private func inertSnapshot(groupID: TerminalGroupID, paneID: TerminalPaneID) throws
    -> TerminalGroupSnapshot
{
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let pane = try TerminalPaneSnapshot(
        id: paneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
        runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped, launchProfile: profile,
        startAvailability: .available)
    return try TerminalGroupSnapshot(
        id: groupID, name: try #require(TerminalGroupName("Inert")), root: .pane(paneID),
        focusedPaneID: paneID, savedLayoutID: nil, panes: [pane], retainedPaneCount: 1)
}

private func inertSplitSnapshot(
    groupID: TerminalGroupID,
    firstPaneID: TerminalPaneID,
    secondPaneID: TerminalPaneID,
    splitID: TerminalGroupSplitID
) throws -> TerminalGroupSnapshot {
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let panes = try [firstPaneID, secondPaneID].map { paneID in
        try TerminalPaneSnapshot(
            id: paneID, sessionID: nil, explicitUserName: nil, reportedTitle: nil,
            runtimeKind: .ordinaryShell, themeColor: nil, status: .stopped,
            launchProfile: profile, startAvailability: .available)
    }
    return try TerminalGroupSnapshot(
        id: groupID, name: try #require(TerminalGroupName("Split inert")),
        root: .split(
            id: splitID, axis: .columns, fraction: 0.5,
            first: .pane(firstPaneID), second: .pane(secondPaneID)),
        focusedPaneID: firstPaneID, savedLayoutID: nil, panes: panes, retainedPaneCount: 2)
}

@MainActor
@Test("Live split binds one lazy controller and advances the tracked group revision")
func terminalGroupLiveSplitIsAtomicAndObservable() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let group = try manager.createLiveGroup(instantiation: instantiation)
    let revision = manager.terminalGroupRevision
    let controller = try manager.splitFocusedPane(
        in: group.id, placement: .right, instantiation: instantiation)
    let updated = try #require(manager.terminalGroup(group.id))
    let focused = try #require(updated.panes.first { $0.id == updated.focusedPaneID })
    #expect(focused.sessionID == controller.id)
    #expect(manager.terminalController(for: focused.id) === controller)
    #expect(manager.terminalGroupRevision > revision)
}
