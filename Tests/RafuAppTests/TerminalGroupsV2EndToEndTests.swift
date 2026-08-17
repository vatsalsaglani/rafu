import Testing

@testable import RafuApp

@Test("Terminal Group v2 saves ten named colored panes and rekeys each opened layout")
func terminalGroupsV2EndToEndRoundTripKeepsMetadataAndInertState() throws {
    var runtime = TerminalGroupRuntime()
    let colors: [TerminalPaneThemeColor] = [.accent, .info, .success, .warning, .error, .muted]
    let groupID = try createdGroupID(runtime.perform(.createGroup(name: nil)))

    for _ in 0..<(TerminalGroupLimits.maximumPanesPerGroup - 1) {
        _ = try runtime.perform(.splitFocusedPane(groupID: groupID, placement: .right))
    }

    let original = try #require(runtime.snapshot(groupID: groupID))
    for (index, pane) in original.panes.enumerated() {
        let name = try #require(TerminalPaneName("Pane \(index + 1)"))
        _ = try runtime.perform(.setPaneName(paneID: pane.id, name: name))
        _ = try runtime.perform(
            .setPaneThemeColor(
                paneID: pane.id,
                color: colors[index % colors.count]
            )
        )
    }

    let named = try #require(runtime.snapshot(groupID: groupID))
    let record = try TerminalGroupRestorationCodec().savedRecord(
        from: named, savedLayoutID: SavedTerminalGroupID())
    let first = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot
    let second = try TerminalGroupRestorationCodec().openNamedLayout(record).snapshot

    #expect(first.id != second.id)
    #expect(first.root.paneIDs.allSatisfy { !second.root.paneIDs.contains($0) })
    #expect(first.root.splitIDs.allSatisfy { !second.root.splitIDs.contains($0) })
    #expect(first.panes.map(\.explicitUserName) == named.panes.map(\.explicitUserName))
    #expect(first.panes.map(\.themeColor) == named.panes.map(\.themeColor))
    #expect(first.panes.allSatisfy { $0.sessionID == nil && $0.status == .stopped })
    #expect(first.panes.allSatisfy { $0.reportedTitle == nil })
    #expect(first.panes.allSatisfy { $0.launchProfile != nil })
}
