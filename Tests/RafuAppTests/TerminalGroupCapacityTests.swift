import Testing

@testable import RafuApp

@Test("The sixth pane succeeds and the seventh pane rejects without mutation")
func terminalGroupPaneCapacityHasNoPartialMutation() throws {
    var runtime = TerminalGroupRuntime()
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))
    for _ in 0..<5 {
        _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    }
    let before = try #require(runtime.snapshot(groupID: groupID))
    #expect(before.panes.count == 6)
    #expect(throws: TerminalGroupCapacityError.groupPaneLimitExceeded(current: 6, requested: 1)) {
        try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    }
    #expect(runtime.snapshot(groupID: groupID) == before)
}

@Test("The twenty-fifth retained pane rejects without changing existing groups")
func terminalGroupRetainedCapacityHasNoPartialMutation() throws {
    var runtime = TerminalGroupRuntime()
    for _ in 0..<24 {
        _ = try runtime.perform(.createGroup(name: nil))
    }
    let before = runtime.snapshots
    #expect(throws: TerminalGroupCapacityError.retainedPaneLimitExceeded(current: 24, requested: 1))
    {
        try runtime.perform(.createGroup(name: nil))
    }
    #expect(runtime.snapshots == before)
}

@MainActor
@Test("Start All checks all requested slots before changing any stopped pane")
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
    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 6, requested: 2)) {
        try manager.startAllRestartablePanes(in: stoppedGroupID, instantiations: starts)
    }
    #expect(manager.terminalGroup(stoppedGroupID) == before)
}

@MainActor
@Test("Capacity reservations are single-use and workspace shutdown releases them")
func terminalGroupReservationsAreBoundedAndReleased() throws {
    let manager = WorkspaceTerminalManager()
    let reservation = try manager.reserveLiveSessionCapacity(6)
    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 6, requested: 1)) {
        try manager.reserveLiveSessionCapacity(1)
    }
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
    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 6, requested: 1)) {
        try manager.reserveLiveSessionCapacity(1)
    }

    let mixed = WorkspaceTerminalManager()
    for _ in 0..<5 {
        _ = try mixed.createLiveGroup(instantiation: instantiation)
    }
    _ = mixed.newSession(startingDirectory: "/tmp", shell: shell)
    #expect(throws: TerminalGroupCapacityError.liveSessionLimitExceeded(current: 6, requested: 1)) {
        try mixed.reserveLiveSessionCapacity(1)
    }
}
