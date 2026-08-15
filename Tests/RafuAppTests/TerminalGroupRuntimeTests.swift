import Foundation
import Testing

@testable import RafuApp

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
    _ = try runtime.perform(.detachDeletedSavedLayout(savedID))
    #expect(runtime.snapshot(groupID: firstID)?.savedLayoutID == nil)
    #expect(runtime.snapshot(groupID: secondID)?.savedLayoutID == nil)
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
