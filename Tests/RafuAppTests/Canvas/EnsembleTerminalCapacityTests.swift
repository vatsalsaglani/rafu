import Foundation
import Testing

@testable import RafuApp

/// Ensemble terminals have no count limit (ADR 0023 amendment, 2026-11-12).
/// The Terminal Group editor tabs keep the window's group, retained-pane and
/// live-session bounds. These tests drive the capacity checks directly; no
/// test here starts a process.
private func ensembleRecord() throws -> SavedTerminalGroupRecord {
    let paneID = SavedTerminalPaneID()
    let pane = try SavedTerminalPaneRecord(
        id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
        launchProfile: TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root))
    return try SavedTerminalGroupRecord(
        id: SavedTerminalGroupID(), name: try #require(TerminalGroupName("Terminal")),
        root: .pane(paneID), focusedPaneID: paneID, panes: [pane])
}

private func openRecord() throws -> TerminalGroupOpenTabRestorationRecord {
    let paneID = TerminalPaneID()
    return try TerminalGroupOpenTabRestorationRecord(
        groupID: TerminalGroupID(), name: try #require(TerminalGroupName("Terminal")),
        root: .pane(paneID), focusedPaneID: paneID, savedLayoutID: nil,
        panes: [
            try TerminalGroupOpenPaneRestorationRecord(
                id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: TerminalPaneLaunchProfile(
                    shell: .preferredShell, startingFolder: .root))
        ])
}

@Test("Ensemble terminal groups pass the window group and retained-pane bounds")
func ensembleGroupsAreExemptFromTheWindowBounds() throws {
    var runtime = TerminalGroupRuntime()
    let count = TerminalGroupLimits.maximumGroupsPerWindow + 5
    for _ in 0..<count {
        _ = try runtime.insertStoppedSavedGroup(try ensembleRecord(), ensemble: true)
    }
    #expect(runtime.snapshots.count == count)
    #expect(runtime.windowGroupCount == 0)
    #expect(runtime.retainedPaneCount == 0)
    // The tab bound is untouched: a full set of tab groups still refuses the next one.
    for _ in 0..<TerminalGroupLimits.maximumGroupsPerWindow {
        _ = try runtime.perform(.createGroup(name: nil))
    }
    #expect(
        throws: TerminalGroupCapacityError.groupLimitExceeded(
            current: TerminalGroupLimits.maximumGroupsPerWindow, requested: 1)
    ) {
        try runtime.perform(.createGroup(name: nil))
    }
    #expect(throws: TerminalGroupCapacityError.self) {
        _ = try runtime.insertStoppedSavedGroup(try ensembleRecord())
    }
}

@MainActor
@Test("Ensemble terminals start past the live-session limit; tab terminals do not")
func ensembleTerminalsStartPastTheLiveSessionLimit() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    manager.terminalGroupControllerFactory = { index, _ in
        WorkspaceTerminalController(index: index, startingDirectory: "/tmp", shell: shell)
    }
    let profile = TerminalPaneLaunchProfile(shell: .preferredShell, startingFolder: .root)
    let instantiation = TerminalGroupControllerInstantiation.ordinaryShell(
        startingDirectory: "/tmp", shell: shell, profile: profile)
    let count = TerminalGroupLimits.maximumLiveSessionsPerWindow + 5
    for _ in 0..<count {
        let group = try manager.insertStoppedSavedGroup(try ensembleRecord(), ensemble: true)
        let paneID = try #require(group.panes.first?.id)
        _ = try manager.startPane(paneID, instantiation: instantiation)
    }
    #expect(manager.sessions.count == count)
    let live = manager.terminalGroups.flatMap(\.panes).filter { $0.status == .live }
    #expect(live.count == count)
    // None of them used the window's live-session capacity: a tab terminal still fits.
    _ = try manager.reserveLiveSessionCapacity(1)
    #expect(manager.retainedTerminalPaneCount == 0)
}

@MainActor
@Test("A tab group moved onto an Ensemble leaves the window bounds")
func markedGroupLeavesTheWindowBounds() throws {
    let manager = WorkspaceTerminalManager()
    let group = try createdGroupID(manager.perform(.createGroup(name: nil)))
    #expect(manager.retainedTerminalPaneCount == 1)
    manager.markEnsembleTerminalGroup(group)
    #expect(manager.isEnsembleTerminalGroup(group))
    #expect(manager.retainedTerminalPaneCount == 0)
}

@Test("An Ensemble restoration payload holds more groups than a window payload")
func ensembleRestorationPayloadHasNoWindowGroupBound() throws {
    let count = TerminalGroupWorkspaceRestoration.maximumOpenGroups + 10
    let records = try (0..<count).map { _ in try openRecord() }
    #expect(throws: TerminalGroupRestorationError.self) {
        _ = try TerminalGroupWorkspaceRestoration(openGroups: records)
    }
    let ensemble = try TerminalGroupWorkspaceRestoration(openGroups: records, ensemble: true)
    let decoded = try JSONDecoder().decode(
        TerminalGroupWorkspaceRestoration.self, from: JSONEncoder().encode(ensemble))
    #expect(decoded.openGroups.count == count)
    #expect(decoded.diagnostics.isEmpty)
}
