import Foundation
import Testing

@testable import RafuApp

@Test("Twenty-first Terminal Group is rejected without mutation")
func terminalGroupCountBoundaryIsAtomic() throws {
    var runtime = TerminalGroupRuntime()
    for _ in 0..<TerminalGroupLimits.maximumGroupsPerWindow {
        _ = try runtime.perform(.createGroup(name: nil))
    }
    let before = runtime.snapshots
    #expect(
        throws: TerminalGroupCapacityError.groupLimitExceeded(
            current: TerminalGroupLimits.maximumGroupsPerWindow, requested: 1)
    ) {
        try runtime.perform(.createGroup(name: nil))
    }
    #expect(runtime.snapshots == before)
}

@Test("The tenth pane succeeds and the eleventh pane rejects without mutation")
func terminalGroupTenPaneBoundaryIsAtomic() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    for _ in 0..<(TerminalGroupLimits.maximumPanesPerGroup - 1) {
        _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    }
    let before = try #require(runtime.snapshot(groupID: groupID))
    #expect(before.panes.count == TerminalGroupLimits.maximumPanesPerGroup)
    #expect(
        throws: TerminalGroupCapacityError.groupPaneLimitExceeded(
            current: TerminalGroupLimits.maximumPanesPerGroup, requested: 1)
    ) {
        try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    }
    #expect(runtime.snapshot(groupID: groupID) == before)
}

@Test("Two hundred retained panes are bounded by the twenty-group and ten-pane limits")
func terminalGroupRetainedCapacityHasNoPartialMutation() throws {
    var runtime = TerminalGroupRuntime()
    for _ in 0..<20 {
        let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
        for _ in 0..<9 {
            _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
        }
    }
    #expect(runtime.retainedPaneCount == 200)
    let before = runtime.snapshots
    #expect(throws: TerminalGroupCapacityError.groupLimitExceeded(current: 20, requested: 1)) {
        try runtime.perform(.createGroup(name: nil))
    }
    #expect(runtime.snapshots == before)
}

@Test("Retained-pane limit rejects Split and saved insertion without changing tree or focus")
func terminalGroupRetainedCapacityRejectsSplitAndSavedInsertion() throws {
    var runtime = TerminalGroupRuntime()
    let first = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    for _ in 0..<9 {
        _ = try runtime.perform(.splitFocusedPane(groupID: first, placement: .right))
    }
    for _ in 0..<19 {
        let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
        for _ in 0..<9 {
            _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
        }
    }
    let before = runtime.snapshots
    #expect(throws: TerminalGroupCapacityError.groupPaneLimitExceeded(current: 10, requested: 1)) {
        try runtime.perform(.splitFocusedPane(groupID: first, placement: .down))
    }
    #expect(runtime.snapshots == before)

    let savedPaneID = SavedTerminalPaneID()
    let record = try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("One pane")),
        root: .pane(savedPaneID), focusedPaneID: savedPaneID,
        panes: [
            try SavedTerminalPaneRecord(
                id: savedPaneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell, startingFolder: .root))
        ])
    #expect(throws: TerminalGroupCapacityError.groupLimitExceeded(current: 20, requested: 1)) {
        try runtime.insertStoppedSavedGroup(record)
    }
    #expect(runtime.snapshots == before)
}

@MainActor
@Test("Start All succeeds below the independent live-session limit")
func terminalGroupStartAllCapacityHasNoPartialMutation() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    for _ in 0..<6 {
        _ = try manager.createLiveGroup(instantiation: instantiation)
    }

    let stoppedGroupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
    _ = try manager.perform(.splitFocusedPane(groupID: stoppedGroupID, placement: .right))
    let before = try #require(manager.terminalGroup(stoppedGroupID))
    let starts = Dictionary(uniqueKeysWithValues: before.panes.map { ($0.id, instantiation) })
    _ = try manager.startAllRestartablePanes(in: stoppedGroupID, instantiations: starts)
    #expect(manager.terminalGroup(stoppedGroupID)?.panes.allSatisfy { $0.status == .live } == true)
}

@MainActor
@Test("Capacity reservations are single-use and workspace shutdown releases them")
func terminalGroupReservationsAreBoundedAndReleased() throws {
    let manager = WorkspaceTerminalManager()
    let reservation = try manager.reserveLiveSessionCapacity(6)
    let secondReservation = try manager.reserveLiveSessionCapacity(1)
    try manager.cancelLiveSessionCapacity(secondReservation)
    #expect(throws: TerminalGroupCapacityError.staleReservation(reservation.id)) {
        try manager.consumeLiveSessionCapacity(reservation)
    }
    try manager.cancelLiveSessionCapacity(reservation)
    let second = try manager.reserveLiveSessionCapacity(1)
    manager.shutdownAll()
    #expect(throws: TerminalGroupCapacityError.staleReservation(second.id)) {
        try manager.cancelLiveSessionCapacity(second)
    }
}

@MainActor
@Test("Live pane metadata mirrors from pane identity without changing the snapshot")
func livePaneMetadataMirrorsByPaneID() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let groupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
    let paneID = try #require(manager.terminalGroup(groupID)?.focusedPaneID)
    manager.terminalGroupControllerFactory = { index, _ in
        WorkspaceTerminalController(index: index, startingDirectory: "/tmp", shell: shell)
    }
    _ = try manager.startPane(paneID, instantiation: instantiation)
    let name = try #require(TerminalPaneName("Live pane"))
    _ = try manager.perform(.setPaneName(paneID: paneID, name: name))
    _ = try manager.perform(.setPaneThemeColor(paneID: paneID, color: .success))
    #expect(manager.terminalGroup(groupID)?.panes.first?.explicitUserName == name)
    #expect(manager.terminalGroup(groupID)?.panes.first?.themeColor == .success)
    #expect(manager.terminalController(for: paneID)?.userName == "Live pane")
    #expect(manager.terminalController(for: paneID)?.terminalPaneThemeColor == .success)
}

@MainActor
@Test("The two-hundredth live legacy session is allowed and the next is rejected")
func liveSessionBoundaryUsesTheIndependentWindowLimit() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    for _ in 0..<TerminalGroupLimits.maximumLiveSessionsPerWindow {
        _ = manager.newSession(startingDirectory: "/tmp", shell: shell)
    }
    let before = manager.sessions.count
    #expect(before == 200)
    #expect(
        throws: TerminalGroupCapacityError.liveSessionLimitExceeded(
            current: 200, requested: 1)
    ) {
        try manager.reserveLiveSessionCapacity(1)
    }
    #expect(manager.sessions.count == before)
}

@MainActor
@Test("A classified insertion commits a reservation for one successful consume")
func terminalGroupCommittedReservationConsumesExactlyOnce() throws {
    let manager = WorkspaceTerminalManager()
    let beforeInsertion = try manager.reserveLiveSessionCapacity(1)
    #expect(throws: TerminalGroupCapacityError.staleReservation(beforeInsertion.id)) {
        try manager.consumeLiveSessionCapacity(beforeInsertion)
    }
    try manager.cancelLiveSessionCapacity(beforeInsertion)

    let reservation = try manager.reserveLiveSessionCapacity(1)
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
        currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Agent")
    let group = try manager.createLiveGroup(
        instantiation: .process(spec: spec, kind: .directAgentTerminal(provider: .codex)),
        reservation: reservation)
    #expect(group.panes.first?.sessionID != nil)
    #expect(manager.sessions.count == 1)
    try manager.consumeLiveSessionCapacity(reservation)
    #expect(throws: TerminalGroupCapacityError.staleReservation(reservation.id)) {
        try manager.consumeLiveSessionCapacity(reservation)
    }
    #expect(throws: TerminalGroupCapacityError.staleReservation(reservation.id)) {
        try manager.cancelLiveSessionCapacity(reservation)
    }
}

@MainActor
@Test("Foreign, double-cancel, and post-shutdown reservation operations reject")
func terminalGroupReservationLifecycleRejectsForeignAndStaleOperations() throws {
    let first = WorkspaceTerminalManager()
    let second = WorkspaceTerminalManager()
    let foreign = try first.reserveLiveSessionCapacity(1)
    #expect(throws: TerminalGroupCapacityError.staleReservation(foreign.id)) {
        try second.cancelLiveSessionCapacity(foreign)
    }
    try first.cancelLiveSessionCapacity(foreign)
    #expect(throws: TerminalGroupCapacityError.staleReservation(foreign.id)) {
        try first.cancelLiveSessionCapacity(foreign)
    }

    let committed = try first.reserveLiveSessionCapacity(1)
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
        currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Agent")
    _ = try first.createLiveGroup(
        instantiation: .process(spec: spec, kind: .directAgentTerminal(provider: .codex)),
        reservation: committed)
    first.shutdownAll()
    #expect(throws: TerminalGroupCapacityError.staleReservation(committed.id)) {
        try first.consumeLiveSessionCapacity(committed)
    }
}

@MainActor
@Test("Natural exit releases a slot and restart checks a reused reservation")
func terminalGroupNaturalExitReleasesCapacityAndRestartPreflightsAgain() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    var groups: [TerminalGroupSnapshot] = []
    for _ in 0..<6 {
        groups.append(try manager.createLiveGroup(instantiation: instantiation))
    }
    let exitingPane = try #require(groups.first?.panes.first)
    let exitingController = try #require(manager.terminalController(for: exitingPane.id))
    exitingController.processDidTerminate(exitCode: 0)
    let reusedSlot = try manager.reserveLiveSessionCapacity(1)
    try manager.cancelLiveSessionCapacity(reusedSlot)
    try manager.restartExitedPane(exitingPane.id)
    #expect(manager.terminalController(for: exitingPane.id) === exitingController)
}

@MainActor
@Test("Construction failure restores runtime, counter, and reserved capacity")
func terminalGroupConstructionFailureHasNoPartialAggregateState() throws {
    enum ConstructionFailure: Error { case injected }

    let manager = WorkspaceTerminalManager()
    let reservation = try manager.reserveLiveSessionCapacity(1)
    manager.terminalGroupControllerFactory = { _, _ in throw ConstructionFailure.injected }
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
        currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Agent")

    #expect(throws: ConstructionFailure.self) {
        try manager.createLiveGroup(
            instantiation: .process(spec: spec, kind: .directAgentTerminal(provider: .codex)),
            reservation: reservation)
    }
    #expect(manager.sessions.isEmpty)
    #expect(manager.terminalGroups.isEmpty)
    #expect(throws: TerminalGroupCapacityError.staleReservation(reservation.id)) {
        try manager.cancelLiveSessionCapacity(reservation)
    }
    let reusable = try manager.reserveLiveSessionCapacity(6)
    #expect(reusable.reservedLiveSessionCount == 6)
    try manager.cancelLiveSessionCapacity(reusable)
}

@MainActor
@Test("A classified validation failure releases its owned reservation")
func terminalGroupClassifiedValidationFailureReleasesReservation() throws {
    let manager = WorkspaceTerminalManager()
    let reservation = try manager.reserveLiveSessionCapacity(1)
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
        currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Agent")

    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.createLiveGroup(
            instantiation: .process(spec: spec, kind: .ordinaryShell), reservation: reservation)
    }
    #expect(manager.sessions.isEmpty)
    #expect(manager.terminalGroups.isEmpty)
    #expect(throws: TerminalGroupCapacityError.staleReservation(reservation.id)) {
        try manager.cancelLiveSessionCapacity(reservation)
    }
    let reusable = try manager.reserveLiveSessionCapacity(6)
    try manager.cancelLiveSessionCapacity(reusable)
}

@MainActor
@Test("A value failure after construction closes the candidate and releases capacity")
func terminalGroupPostConstructionValueFailureClosesCandidate() throws {
    let manager = WorkspaceTerminalManager()
    for _ in 0..<20 {
        let groupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
        for _ in 0..<9 {
            _ = try manager.perform(.splitFocusedPane(groupID: groupID, placement: .right))
        }
    }
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let candidate = WorkspaceTerminalController(index: 1, startingDirectory: "/tmp", shell: shell)
    manager.terminalGroupControllerFactory = { _, _ in candidate }
    let reservation = try manager.reserveLiveSessionCapacity(1)
    let spec = TerminalProcessSpec(
        executableURL: URL(fileURLWithPath: "/usr/bin/false"), arguments: [],
        currentDirectoryPath: "/tmp", environment: [:], roleBadge: "Agent")

    #expect(throws: TerminalGroupCapacityError.groupLimitExceeded(current: 20, requested: 1)) {
        try manager.createLiveGroup(
            instantiation: .process(spec: spec, kind: .directAgentTerminal(provider: .codex)),
            reservation: reservation)
    }
    #expect(candidate.status == .exited(code: nil))
    #expect(manager.sessions.isEmpty)
    #expect(manager.retainedTerminalPaneCount == 200)
    #expect(throws: TerminalGroupCapacityError.staleReservation(reservation.id)) {
        try manager.cancelLiveSessionCapacity(reservation)
    }
    let reusable = try manager.reserveLiveSessionCapacity(6)
    try manager.cancelLiveSessionCapacity(reusable)
}

@MainActor
@Test("Start All construction failure leaves every stopped pane and controller unchanged")
func terminalGroupStartAllConstructionFailureRollsBackEverything() throws {
    enum ConstructionFailure: Error { case injected }
    final class Attempts { var count = 0 }

    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let groupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
    _ = try manager.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let before = try #require(manager.terminalGroup(groupID))
    let attempts = Attempts()
    manager.terminalGroupControllerFactory = { index, _ in
        attempts.count += 1
        guard attempts.count != 2 else { throw ConstructionFailure.injected }
        return WorkspaceTerminalController(index: index, startingDirectory: "/tmp", shell: shell)
    }

    let starts = Dictionary(uniqueKeysWithValues: before.panes.map { ($0.id, instantiation) })
    #expect(throws: ConstructionFailure.self) {
        try manager.startAllRestartablePanes(in: groupID, instantiations: starts)
    }
    #expect(manager.terminalGroup(groupID) == before)
    #expect(manager.sessions.isEmpty)
    #expect(manager.selectedID == nil)
    let reusable = try manager.reserveLiveSessionCapacity(6)
    try manager.cancelLiveSessionCapacity(reusable)

    manager.terminalGroupControllerFactory = nil
    let first = try manager.startPane(before.focusedPaneID, instantiation: instantiation)
    #expect(first.index == 1)
}

@MainActor
@Test("A factory cannot bind an existing legacy controller into a group pane")
func terminalGroupRejectsFactoryControllerAlreadyOwnedByLegacySession() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let legacy = manager.newSession(startingDirectory: "/tmp", shell: shell)
    var legacyExitCallbacks = 0
    legacy.onExit = { _, _ in legacyExitCallbacks += 1 }
    let groupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
    let paneID = try #require(manager.terminalGroup(groupID)?.focusedPaneID)
    manager.terminalGroupControllerFactory = { _, _ in legacy }

    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.startPane(
            paneID,
            instantiation: .ordinaryShell(
                startingDirectory: "/tmp", shell: shell, profile: profile))
    }
    #expect(manager.sessions.count == 1)
    #expect(manager.sessions.first === legacy)
    #expect(manager.terminalGroup(groupID)?.panes.first?.sessionID == nil)
    #expect(legacy.status == .idle)
    legacy.processDidTerminate(exitCode: 0)
    #expect(legacyExitCallbacks == 1)
}

@MainActor
@Test("Start All rejects a duplicate candidate before callback or shutdown mutation")
func terminalGroupStartAllRejectsDuplicateFactoryCandidateAtomically() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let groupID = try createdGroupID(manager.perform(.createGroup(name: nil)))
    _ = try manager.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    let before = try #require(manager.terminalGroup(groupID))
    let sharedCandidate = WorkspaceTerminalController(
        index: 99, startingDirectory: "/tmp", shell: shell)
    var candidateExitCallbacks = 0
    sharedCandidate.onExit = { _, _ in candidateExitCallbacks += 1 }
    manager.terminalGroupControllerFactory = { _, _ in sharedCandidate }
    let starts = Dictionary(uniqueKeysWithValues: before.panes.map { ($0.id, instantiation) })

    #expect(throws: TerminalGroupValidationError.unsupportedPaneStart) {
        try manager.startAllRestartablePanes(in: groupID, instantiations: starts)
    }
    #expect(manager.terminalGroup(groupID) == before)
    #expect(manager.sessions.isEmpty)
    #expect(manager.selectedID == nil)
    #expect(sharedCandidate.status == .exited(code: nil))
    sharedCandidate.processDidTerminate(exitCode: 0)
    #expect(candidateExitCallbacks == 1)

    manager.terminalGroupControllerFactory = nil
    let controller = try manager.startPane(before.focusedPaneID, instantiation: instantiation)
    #expect(controller.index == 1)
}

@MainActor
@Test("Six grouped sessions count once, and legacy sessions share the same window cap")
func terminalGroupAndLegacyCapacityCountsEachControllerOnce() throws {
    let manager = WorkspaceTerminalManager()
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    for _ in 0..<6 {
        _ = try manager.createLiveGroup(instantiation: instantiation)
    }
    let reservation = try manager.reserveLiveSessionCapacity(1)
    try manager.cancelLiveSessionCapacity(reservation)

    let mixed = WorkspaceTerminalManager()
    for _ in 0..<5 {
        _ = try mixed.createLiveGroup(instantiation: instantiation)
    }
    _ = mixed.newSession(startingDirectory: "/tmp", shell: shell)
    let mixedReservation = try mixed.reserveLiveSessionCapacity(1)
    try mixed.cancelLiveSessionCapacity(mixedReservation)
}
