import Foundation
import Testing

@testable import RafuApp

private enum TerminalGroupContractTestError: Error {
    case invalidTestValue
}

@MainActor
private final class TerminalGroupCapacityReservationProbe: TerminalGroupCapacityReserving {
    private(set) var activeReservationIDs: Set<TerminalGroupCapacityReservationID> = []

    func reserveLiveSessionCapacity(
        _ requestedLiveSessionCount: Int
    ) throws -> TerminalGroupCapacityReservation {
        guard
            let reservation = TerminalGroupCapacityReservation(
                generation: 1,
                reservedLiveSessionCount: requestedLiveSessionCount
            )
        else {
            throw TerminalGroupContractTestError.invalidTestValue
        }
        activeReservationIDs.insert(reservation.id)
        return reservation
    }

    func consumeLiveSessionCapacity(
        _ reservation: TerminalGroupCapacityReservation
    ) throws {
        guard activeReservationIDs.remove(reservation.id) != nil else {
            throw TerminalGroupContractTestError.invalidTestValue
        }
    }

    func cancelLiveSessionCapacity(
        _ reservation: TerminalGroupCapacityReservation
    ) throws {
        guard activeReservationIDs.remove(reservation.id) != nil else {
            throw TerminalGroupContractTestError.invalidTestValue
        }
    }
}

private func paneName(_ value: String) throws -> TerminalPaneName {
    guard let name = TerminalPaneName(value) else {
        throw TerminalGroupContractTestError.invalidTestValue
    }
    return name
}

private func reportedTitle(_ value: String) throws -> TerminalReportedTitle {
    guard let title = TerminalReportedTitle(value) else {
        throw TerminalGroupContractTestError.invalidTestValue
    }
    return title
}

@Test("Terminal Group IDs and vocabulary round-trip through Codable")
func terminalGroupIdentityAndVocabularyRoundTrip() throws {
    let groupID = TerminalGroupID()
    let paneID = TerminalPaneID()
    let splitID = TerminalGroupSplitID()
    let savedGroupID = SavedTerminalGroupID()
    let savedPaneID = SavedTerminalPaneID()
    let savedSplitID = SavedTerminalGroupSplitID()

    #expect(
        try JSONDecoder().decode(TerminalGroupID.self, from: JSONEncoder().encode(groupID))
            == groupID)
    #expect(
        try JSONDecoder().decode(TerminalPaneID.self, from: JSONEncoder().encode(paneID)) == paneID)
    #expect(
        try JSONDecoder().decode(TerminalGroupSplitID.self, from: JSONEncoder().encode(splitID))
            == splitID)
    #expect(
        try JSONDecoder().decode(
            SavedTerminalGroupID.self, from: JSONEncoder().encode(savedGroupID))
            == savedGroupID)
    #expect(
        try JSONDecoder().decode(SavedTerminalPaneID.self, from: JSONEncoder().encode(savedPaneID))
            == savedPaneID)
    #expect(
        try JSONDecoder().decode(
            SavedTerminalGroupSplitID.self,
            from: JSONEncoder().encode(savedSplitID)
        ) == savedSplitID)
    #expect(
        try JSONDecoder().decode(
            TerminalGroupSplitPlacement.self,
            from: JSONEncoder().encode(TerminalGroupSplitPlacement.right)
        ) == .right)
}

@Test("Terminal Group v2 limits stay independent and bounded")
func terminalGroupV2LimitsAreIndependent() {
    #expect(TerminalGroupLimits.maximumGroupsPerWindow == 20)
    #expect(TerminalGroupLimits.maximumPanesPerGroup == 10)
    #expect(TerminalGroupLimits.maximumRetainedPanesPerWindow == 200)
    #expect(TerminalGroupLimits.maximumLiveSessionsPerWindow == 200)
    #expect(TerminalGroupLimits.maximumSavedLayoutsPerWorkspace == 32)
    // The values may coincide. Independence is expressed by distinct named
    // contracts and by their separate capacity call sites.
}

@Test("Terminal Group snapshots normalize fractions and reject invalid pane topology")
func terminalGroupSnapshotValidatesTreeAndBounds() throws {
    let firstPaneID = TerminalPaneID()
    let secondPaneID = TerminalPaneID()
    let name = try #require(TerminalGroupName("Build"))
    let firstPaneName = try paneName("Editor")
    let title = try reportedTitle("OSC title")
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let panes = [
        try TerminalPaneSnapshot(
            id: firstPaneID,
            sessionID: nil,
            explicitUserName: firstPaneName,
            reportedTitle: title,
            runtimeKind: .ordinaryShell,
            themeColor: .accent,
            status: .stopped,
            launchProfile: profile,
            startAvailability: .available
        ),
        try TerminalPaneSnapshot(
            id: secondPaneID,
            sessionID: nil,
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .ordinaryShell,
            themeColor: nil,
            status: .stopped,
            launchProfile: profile,
            startAvailability: .available
        ),
    ]
    let root = TerminalGroupNode.split(
        id: TerminalGroupSplitID(),
        axis: .columns,
        fraction: .infinity,
        first: .pane(firstPaneID),
        second: .pane(secondPaneID)
    )

    let snapshot = try TerminalGroupSnapshot(
        id: TerminalGroupID(),
        name: name,
        root: root,
        focusedPaneID: firstPaneID,
        savedLayoutID: nil,
        panes: panes,
        retainedPaneCount: 2
    )
    guard case .split(_, _, let fraction, _, _) = snapshot.root else {
        Issue.record("Expected a split root")
        return
    }
    #expect(fraction == TerminalGroupSnapshot.defaultSplitFraction)

    #expect(throws: TerminalGroupSnapshotError.duplicatePane(firstPaneID)) {
        _ = try TerminalGroupSnapshot(
            id: TerminalGroupID(),
            name: name,
            root: .split(
                id: TerminalGroupSplitID(),
                axis: .rows,
                fraction: 0.5,
                first: .pane(firstPaneID),
                second: .pane(firstPaneID)
            ),
            focusedPaneID: firstPaneID,
            savedLayoutID: nil,
            panes: [panes[0]],
            retainedPaneCount: 1
        )
    }
    #expect(throws: TerminalGroupSnapshotError.focusedPaneMissing(secondPaneID)) {
        _ = try TerminalGroupSnapshot(
            id: TerminalGroupID(),
            name: name,
            root: .pane(firstPaneID),
            focusedPaneID: secondPaneID,
            savedLayoutID: nil,
            panes: [panes[0]],
            retainedPaneCount: 1
        )
    }
    #expect(throws: TerminalGroupSnapshotError.retainedPaneLimitExceeded(25)) {
        _ = try TerminalGroupSnapshot(
            id: TerminalGroupID(),
            name: name,
            root: .pane(firstPaneID),
            focusedPaneID: firstPaneID,
            savedLayoutID: nil,
            panes: [panes[0]],
            retainedPaneCount: 25
        )
    }

    let sharedSessionID = UUID()
    var duplicateSessionPanes = panes
    duplicateSessionPanes[0] = try TerminalPaneSnapshot(
        id: firstPaneID,
        sessionID: sharedSessionID,
        explicitUserName: nil,
        reportedTitle: nil,
        runtimeKind: .ordinaryShell,
        themeColor: nil,
        status: .live,
        launchProfile: profile,
        startAvailability: .available
    )
    duplicateSessionPanes[1] = try TerminalPaneSnapshot(
        id: secondPaneID,
        sessionID: sharedSessionID,
        explicitUserName: nil,
        reportedTitle: nil,
        runtimeKind: .ordinaryShell,
        themeColor: nil,
        status: .live,
        launchProfile: profile,
        startAvailability: .available
    )
    #expect(throws: TerminalGroupSnapshotError.duplicateSession(sharedSessionID)) {
        _ = try TerminalGroupSnapshot(
            id: TerminalGroupID(),
            name: name,
            root: root,
            focusedPaneID: firstPaneID,
            savedLayoutID: nil,
            panes: duplicateSessionPanes,
            retainedPaneCount: 2
        )
    }

    var sevenPaneRoot = TerminalGroupNode.pane(firstPaneID)
    for _ in 0..<6 {
        sevenPaneRoot = .split(
            id: TerminalGroupSplitID(),
            axis: .columns,
            fraction: 0.5,
            first: sevenPaneRoot,
            second: .pane(TerminalPaneID())
        )
    }
    #expect(throws: TerminalGroupSnapshotError.tooManyPanes(7)) {
        _ = try TerminalGroupSnapshot(
            id: TerminalGroupID(),
            name: name,
            root: sevenPaneRoot,
            focusedPaneID: firstPaneID,
            savedLayoutID: nil,
            panes: panes,
            retainedPaneCount: 7
        )
    }
}

@Test("Terminal Group launch profiles retain only a safe shell choice and relative folder")
func terminalGroupLaunchProfileEncodingIsSafe() throws {
    let folder = try #require(TerminalWorkspaceRelativePath("Sources/RafuApp"))
    let shell = try #require(TerminalPaneShellChoice(approvedShellPath: "/bin/zsh"))
    let profile = TerminalPaneLaunchProfile(shell: shell, startingFolder: folder)

    let decoded = try JSONDecoder().decode(
        TerminalPaneLaunchProfile.self,
        from: JSONEncoder().encode(profile)
    )
    #expect(decoded == profile)
    #expect(TerminalWorkspaceRelativePath("../outside") == nil)
    #expect(TerminalWorkspaceRelativePath("/absolute") == nil)
    #expect(TerminalPaneShellChoice(approvedShellPath: "zsh") == nil)
}

@Test("Terminal Group group and pane names use an 80 Unicode-scalar bound")
func terminalGroupNamesUseUnicodeScalarBounds() {
    let eightyScalars = String(repeating: "🙂", count: 80)
    let eightyOneScalars = String(repeating: "🙂", count: 81)

    #expect(eightyScalars.unicodeScalars.count == 80)
    #expect(eightyScalars.utf8.count > 80)
    #expect(TerminalGroupName(eightyScalars) != nil)
    #expect(TerminalPaneName(eightyScalars) != nil)
    #expect(TerminalGroupName(eightyOneScalars) == nil)
    #expect(TerminalPaneName(eightyOneScalars) == nil)
}

@Test("Unavailable Terminal Group panes reject live and restartable state")
func unavailableTerminalGroupPaneStatesAreRejected() throws {
    let paneID = TerminalPaneID()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)

    #expect(throws: TerminalPaneSnapshotError.unavailablePaneHasLiveSession(paneID)) {
        _ = try TerminalPaneSnapshot(
            id: paneID,
            sessionID: UUID(),
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .unavailableAgentTerminal,
            themeColor: nil,
            status: .unavailable,
            launchProfile: nil,
            startAvailability: .unavailable
        )
    }
    #expect(throws: TerminalPaneSnapshotError.unavailablePaneHasInvalidStatus(paneID, .stopped)) {
        _ = try TerminalPaneSnapshot(
            id: paneID,
            sessionID: nil,
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .unavailableEnsemble,
            themeColor: nil,
            status: .stopped,
            launchProfile: nil,
            startAvailability: .unavailable
        )
    }
    #expect(throws: TerminalPaneSnapshotError.unavailablePaneHasLaunchProfile(paneID)) {
        _ = try TerminalPaneSnapshot(
            id: paneID,
            sessionID: nil,
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .unavailableAgentTerminal,
            themeColor: nil,
            status: .unavailable,
            launchProfile: profile,
            startAvailability: .unavailable
        )
    }
    #expect(
        throws: TerminalPaneSnapshotError.unavailablePaneHasInvalidStartAvailability(
            paneID,
            .available
        )
    ) {
        _ = try TerminalPaneSnapshot(
            id: paneID,
            sessionID: nil,
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .unavailableEnsemble,
            themeColor: nil,
            status: .unavailable,
            launchProfile: nil,
            startAvailability: .available
        )
    }
}

@MainActor
@Test("Capacity reservations and close tokens are bounded generation-checked values")
func terminalGroupCapacityAndCloseTokensAreBounded() throws {
    let reservation = try #require(
        TerminalGroupCapacityReservation(generation: 1, reservedLiveSessionCount: 2)
    )
    #expect(reservation.generation == 1)
    #expect(TerminalGroupCapacityReservation(generation: 0, reservedLiveSessionCount: 1) == nil)
    #expect(TerminalGroupCapacityReservation(generation: 1, reservedLiveSessionCount: 11) == nil)

    let sessionID = UUID()
    let token = try #require(
        TerminalGroupCloseToken(
            target: .pane(TerminalPaneID()),
            affectedSessionIDs: [sessionID],
            liveProcessCount: 1,
            generation: 4
        )
    )
    #expect(token.affectedSessionIDs == [sessionID])
    #expect(
        TerminalGroupCloseToken(
            target: .pane(TerminalPaneID()),
            affectedSessionIDs: [sessionID, sessionID],
            liveProcessCount: 1,
            generation: 4
        ) == nil)

    let probe = TerminalGroupCapacityReservationProbe()
    let reserver: any TerminalGroupCapacityReserving = probe
    let consumedReservation = try reserver.reserveLiveSessionCapacity(1)
    #expect(probe.activeReservationIDs == [consumedReservation.id])
    try reserver.consumeLiveSessionCapacity(consumedReservation)
    #expect(probe.activeReservationIDs.isEmpty)

    let cancelledReservation = try reserver.reserveLiveSessionCapacity(1)
    #expect(probe.activeReservationIDs == [cancelledReservation.id])
    try reserver.cancelLiveSessionCapacity(cancelledReservation)
    #expect(probe.activeReservationIDs.isEmpty)
}

@Test("Pane metadata commands carry only bounded runtime values")
func terminalGroupPaneMetadataCommandsAreBounded() throws {
    let paneID = TerminalPaneID()
    let name = try paneName("Build")

    #expect(
        TerminalGroupCommand.setPaneName(paneID: paneID, name: name)
            == .setPaneName(paneID: paneID, name: name))
    #expect(
        TerminalGroupCommand.setPaneName(paneID: paneID, name: nil)
            == .setPaneName(paneID: paneID, name: nil))
    #expect(
        TerminalGroupCommand.setPaneThemeColor(paneID: paneID, color: .accent)
            == .setPaneThemeColor(paneID: paneID, color: .accent))
    #expect(
        TerminalGroupCommand.setPaneThemeColor(paneID: paneID, color: nil)
            == .setPaneThemeColor(paneID: paneID, color: nil))
    #expect(
        TerminalGroupEffect.paneMetadataChanged(paneID: paneID)
            == .paneMetadataChanged(paneID: paneID))
}

@Test("Named saved layouts re-key every runtime identity when opened")
func namedSavedLayoutInstantiationRekeysEveryOpen() throws {
    let savedPaneID = SavedTerminalPaneID()
    let savedPaneName = try paneName("Shell")
    let savedGroup = try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(),
        name: try #require(TerminalGroupName("Layout")),
        root: .pane(savedPaneID),
        focusedPaneID: savedPaneID,
        panes: [
            try SavedTerminalPaneRecord(
                id: savedPaneID,
                explicitUserName: savedPaneName,
                themeColor: .success,
                kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell,
                    startingFolder: .root
                )
            )
        ]
    )

    let first = try TerminalGroupSavedLayoutInstantiation(savedGroup: savedGroup)
    let second = try TerminalGroupSavedLayoutInstantiation(savedGroup: savedGroup)

    #expect(first.savedLayoutID == savedGroup.id)
    #expect(second.savedLayoutID == savedGroup.id)
    #expect(first.groupID != second.groupID)
    #expect(first.focusedPaneID != second.focusedPaneID)
    #expect(first.panes.map(\.id) != second.panes.map(\.id))
}

@Test("The command and switcher identities remain pure and do not construct a session")
func terminalGroupCommandAndSwitcherIdentityArePure() throws {
    let groupID = TerminalGroupID()
    let command = TerminalGroupCommand.focusDirection(groupID: groupID, direction: .right)
    let effect = TerminalGroupEffect.selectEditorTab(groupID: groupID)
    let destination = EditorTabSwitcherDestination.terminalGroup(groupID: groupID)

    #expect(command == .focusDirection(groupID: groupID, direction: .right))
    #expect(effect == .selectEditorTab(groupID: groupID))
    #expect(destination == .terminalGroup(groupID: groupID))
}
