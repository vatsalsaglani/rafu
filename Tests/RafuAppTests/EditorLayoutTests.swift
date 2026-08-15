import Foundation
import Testing

@testable import RafuApp

@Test("Editor layout splits, moves tabs, and round-trips stable identity")
func editorLayoutRestorationRoundTrip() throws {
    let firstTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/first.swift")))
    let secondTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/second.swift")))
    let initialGroup = EditorGroupState(tabs: [firstTab, secondTab], selectedTabID: secondTab.id)
    var layout = EditorLayoutState(root: .group(initialGroup), focusedGroupID: initialGroup.id)

    let splitGroupID = layout.split(
        group: initialGroup.id, at: .trailing, moving: secondTab.id)
    let newGroupID = try #require(splitGroupID)

    #expect(layout.groupIDs == [initialGroup.id, newGroupID])
    #expect(layout.group(id: initialGroup.id)?.tabs.map(\.id) == [firstTab.id])
    #expect(layout.group(id: newGroupID)?.tabs.map(\.id) == [secondTab.id])
    #expect(layout.focusedGroupID == newGroupID)

    let encoded = try JSONEncoder().encode(EditorLayoutRestoration(layout: layout))
    let decoded = try JSONDecoder().decode(EditorLayoutRestoration.self, from: encoded)
    let restored = try decoded.restoredLayout()

    #expect(restored == layout)
    #expect(restored.groupIDs == [initialGroup.id, newGroupID])
}

@Test("EditorGroupState.move reorders forward, backward, clamps out-of-range, and no-ops in place")
func editorGroupStateMoveReordersAndClamps() throws {
    let tabs = (0..<4).map {
        EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/\($0).swift")))
    }
    let ids = tabs.map(\.id)

    // Moving forward (i < j): A (0) to insertion index 2 (between B and C)
    // lands it immediately after B — the central off-by-one case, since
    // removing A first shifts C's original index 2 down to 1.
    var forward = EditorGroupState(tabs: tabs)
    forward.move(ids[0], toInsertionIndex: 2)
    #expect(forward.tabs.map(\.id) == [ids[1], ids[0], ids[2], ids[3]])

    // Moving backward (i > j): D (3) to insertion index 1 (between A and B)
    // lands it immediately after A.
    var backward = EditorGroupState(tabs: tabs)
    backward.move(ids[3], toInsertionIndex: 1)
    #expect(backward.tabs.map(\.id) == [ids[0], ids[3], ids[1], ids[2]])

    // i == j: dropping a tab back onto its own current slot is a no-op.
    var sameIndex = EditorGroupState(tabs: tabs)
    sameIndex.move(ids[1], toInsertionIndex: 1)
    #expect(sameIndex.tabs.map(\.id) == ids)

    // Dropping a tab immediately after itself is ALSO a no-op — the
    // off-by-one correction must treat index == currentIndex + 1 the same
    // as index == currentIndex.
    var justAfterSelf = EditorGroupState(tabs: tabs)
    justAfterSelf.move(ids[1], toInsertionIndex: 2)
    #expect(justAfterSelf.tabs.map(\.id) == ids)

    // Out-of-range requests clamp instead of crashing: a negative request
    // clamps to the front, an overshoot clamps to the end.
    var clampedFront = EditorGroupState(tabs: tabs)
    clampedFront.move(ids[3], toInsertionIndex: -5)
    #expect(clampedFront.tabs.map(\.id) == [ids[3], ids[0], ids[1], ids[2]])

    var clampedEnd = EditorGroupState(tabs: tabs)
    clampedEnd.move(ids[0], toInsertionIndex: 999)
    #expect(clampedEnd.tabs.map(\.id) == [ids[1], ids[2], ids[3], ids[0]])

    // An unknown tab ID is a no-op.
    var unknown = EditorGroupState(tabs: tabs)
    unknown.move(EditorTabID(), toInsertionIndex: 0)
    #expect(unknown.tabs.map(\.id) == ids)
}

@Test("EditorGroupState.move never changes selection, even for the moved tab")
func editorGroupStateMovePreservesSelection() {
    let tabs = (0..<3).map {
        EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/\($0).swift")))
    }
    var group = EditorGroupState(tabs: tabs, selectedTabID: tabs[0].id)
    group.move(tabs[0].id, toInsertionIndex: 2)
    #expect(group.selectedTabID == tabs[0].id)
}

@Test("EditorLayoutState.reorderTab is a no-op for an unknown tab, group, or non-member tab")
func editorLayoutStateReorderTabRejectsInvalidRequests() throws {
    let tabA = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/a.swift")))
    let tabB = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/b.swift")))
    let groupA = EditorGroupState(tabs: [tabA])
    let groupB = EditorGroupState(tabs: [tabB])
    var layout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(), axis: .horizontal, fraction: 0.5,
            first: .group(groupA), second: .group(groupB)),
        focusedGroupID: groupA.id
    )

    // Unknown group.
    let unknownGroupResult = layout.reorderTab(tabA.id, in: EditorGroupID(), toInsertionIndex: 0)
    #expect(!unknownGroupResult)
    // Unknown tab.
    let unknownTabResult = layout.reorderTab(EditorTabID(), in: groupA.id, toInsertionIndex: 0)
    #expect(!unknownTabResult)
    // Tab exists but is not a member of the named group.
    let nonMemberResult = layout.reorderTab(tabB.id, in: groupA.id, toInsertionIndex: 0)
    #expect(!nonMemberResult)
    // A same-slot request resolves to no actual change.
    let sameSlotResult = layout.reorderTab(tabA.id, in: groupA.id, toInsertionIndex: 0)
    #expect(!sameSlotResult)

    #expect(layout.group(id: groupA.id)?.tabs.map(\.id) == [tabA.id])
    #expect(layout.group(id: groupB.id)?.tabs.map(\.id) == [tabB.id])
}

@Test("Moving the last tab out of a group collapses its redundant split")
func movingLastTabCollapsesSourceGroup() throws {
    let firstTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/first.swift")))
    let secondTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/second.swift")))
    let firstGroup = EditorGroupState(tabs: [firstTab])
    let secondGroup = EditorGroupState(tabs: [secondTab])
    var layout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(),
            axis: .horizontal,
            fraction: 0.5,
            first: .group(firstGroup),
            second: .group(secondGroup)
        ),
        focusedGroupID: firstGroup.id
    )

    let didMove = layout.moveTab(firstTab.id, to: secondGroup.id, at: 0)
    #expect(didMove)
    #expect(layout.groupIDs == [secondGroup.id])
    #expect(layout.group(id: secondGroup.id)?.tabs.map(\.id) == [firstTab.id, secondTab.id])
    #expect(layout.focusedGroupID == secondGroup.id)
}

@Test("Closing a selected tab chooses a stable adjacent selection")
func closingSelectedTabChoosesAdjacentTab() throws {
    let tabs = (0..<3).map {
        EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/\($0).swift")))
    }
    let group = EditorGroupState(tabs: tabs, selectedTabID: tabs[1].id)
    var layout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)

    let closedTab = layout.closeTab(tabs[1].id)
    let closed = try #require(closedTab)

    #expect(closed.id == tabs[1].id)
    #expect(layout.group(id: group.id)?.tabs.map(\.id) == [tabs[0].id, tabs[2].id])
    #expect(layout.group(id: group.id)?.selectedTabID == tabs[2].id)
}

@Test("Only a file resource is restorable; a terminal tab is not")
func terminalTabResourceIsNotRestorable() {
    #expect(EditorTabResource.file(URL(fileURLWithPath: "/tmp/a.swift")).isRestorable)
    #expect(!EditorTabResource.terminal(sessionID: UUID()).isRestorable)
    #expect(!EditorTabResource.restorable(kind: "diff", key: "x", title: "x").isRestorable)
}

@Test("A terminal tab resource round-trips through Codable")
func terminalTabResourceCodableRoundTrip() throws {
    let sessionID = UUID()
    let resource = EditorTabResource.terminal(sessionID: sessionID)
    let encoded = try JSONEncoder().encode(resource)
    let decoded = try JSONDecoder().decode(EditorTabResource.self, from: encoded)
    #expect(decoded == resource)
    guard case .terminal(let decodedID) = decoded else {
        Issue.record("Expected a decoded .terminal case")
        return
    }
    #expect(decodedID == sessionID)
}

@Test("A Terminal Group resource round-trips and remains inactive without a matching record")
func terminalGroupResourceCodableRoundTrip() throws {
    let groupID = TerminalGroupID()
    let resource = EditorTabResource.terminalGroup(groupID: groupID)

    let decoded = try JSONDecoder().decode(
        EditorTabResource.self, from: JSONEncoder().encode(resource))

    #expect(decoded == resource)
    #expect(!decoded.isRestorable)
    #expect(
        decoded.restorationClassification(terminalGroups: nil)
            == .missingTerminalGroupRecord(groupID))
}

@Test("Legacy terminal resources remain decodable beside Terminal Group resources")
func legacyTerminalResourceDecodesBesideTerminalGroupResource() throws {
    let legacy = EditorTabResource.terminal(sessionID: UUID())
    let decoded = try JSONDecoder().decode(
        EditorTabResource.self, from: JSONEncoder().encode(legacy))

    #expect(decoded == legacy)
    #expect(decoded.restorationClassification(terminalGroups: nil) == .notRestorable)
}

@Test("Editor layout restoration rejects unknown schema versions")
func editorLayoutRejectsUnknownSchema() {
    let layout = EditorLayoutState()
    let unsupported = EditorLayoutRestoration(schemaVersion: 99, layout: layout)

    #expect(throws: EditorLayoutRestorationError.unsupportedSchema(99)) {
        try unsupported.restoredLayout()
    }
}

@Test("Workspace restoration payload preserves versioned split topology")
func workspaceRestorationPreservesEditorLayout() throws {
    let tab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/README.md")))
    let secondTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/Package.swift")))
    let firstGroup = EditorGroupState(tabs: [tab])
    let secondGroup = EditorGroupState(tabs: [secondTab])
    let layout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(),
            axis: .vertical,
            fraction: 0.4,
            first: .group(firstGroup),
            second: .group(secondGroup)
        ),
        focusedGroupID: firstGroup.id
    )
    let payload = RestorableWorkspace(
        bookmark: Data([1, 2, 3]),
        rootPath: "/tmp",
        openRelativePaths: ["README.md", "Package.swift"],
        selectedRelativePath: "README.md",
        navigatorMode: .files,
        editorLayout: EditorLayoutRestoration(layout: layout)
    )

    let encoded = try JSONEncoder().encode(payload)
    let decoded = try JSONDecoder().decode(RestorableWorkspace.self, from: encoded)

    #expect(try decoded.editorLayout?.restoredLayout() == layout)
}

@MainActor
@Test("visibleDocumentIDs is the selected tab's document in every group")
func visibleDocumentIDsAcrossGroups() {
    let session = WorkspaceSession()
    let urlA = URL(fileURLWithPath: "/tmp/a.swift")
    let urlB = URL(fileURLWithPath: "/tmp/b.swift")
    let docA = EditorDocument(url: urlA)
    let docB = EditorDocument(url: urlB)
    session.openDocuments = [docA, docB]

    let tabA = EditorTabState(resource: .file(urlA))
    let tabB = EditorTabState(resource: .file(urlB))

    // One group holding both tabs with A selected: only A is visible.
    let singleGroup = EditorGroupState(tabs: [tabA, tabB], selectedTabID: tabA.id)
    session.editorLayout = EditorLayoutState(
        root: .group(singleGroup), focusedGroupID: singleGroup.id)
    #expect(session.visibleDocumentIDs == Set([docA.id]))

    // Split into two groups, each showing one tab: both documents visible.
    let groupA = EditorGroupState(tabs: [tabA], selectedTabID: tabA.id)
    let groupB = EditorGroupState(tabs: [tabB], selectedTabID: tabB.id)
    session.editorLayout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(), axis: .horizontal, fraction: 0.5,
            first: .group(groupA), second: .group(groupB)),
        focusedGroupID: groupA.id)
    #expect(session.visibleDocumentIDs == Set([docA.id, docB.id]))
}

@MainActor
@Test(
    "Restored placeholders: only the selected tab of a single group loads; the rest hibernate"
)
func restoredPlaceholdersHibernateNonVisibleTabsInSingleGroup() {
    let session = WorkspaceSession()
    let urlA = URL(fileURLWithPath: "/tmp/a.swift")
    let urlB = URL(fileURLWithPath: "/tmp/b.swift")
    let urlC = URL(fileURLWithPath: "/tmp/c.swift")
    let docA = EditorDocument(url: urlA)
    let docB = EditorDocument(url: urlB)
    let docC = EditorDocument(url: urlC)
    session.openDocuments = [docA, docB, docC]

    let tabA = EditorTabState(resource: .file(urlA))
    let tabB = EditorTabState(resource: .file(urlB))
    let tabC = EditorTabState(resource: .file(urlC))
    // Fewer than DocumentHibernationPolicy.keepLoadedLimit (8) tabs, which
    // is exactly the case where the pre-increment-5 restore left every
    // restored tab loaded via the newest-N grace.
    let group = EditorGroupState(tabs: [tabA, tabB, tabC], selectedTabID: tabB.id)
    session.editorLayout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)

    session.applyRestoredHibernationPlaceholders()

    #expect(docB.loadState == .loaded)
    #expect(docA.loadState == .hibernated)
    #expect(docC.loadState == .hibernated)

    // Selecting a hibernated restored tab re-materializes it via the normal
    // hibernated -> refocus path.
    session.select(docA)
    #expect(docA.loadState == .loaded)
}

@MainActor
@Test("Restored placeholders: each group's selected tab stays loaded across a split layout")
func restoredPlaceholdersKeepEachGroupsSelectedTabLoaded() {
    let session = WorkspaceSession()
    let urlA = URL(fileURLWithPath: "/tmp/a.swift")
    let urlB = URL(fileURLWithPath: "/tmp/b.swift")
    let urlC = URL(fileURLWithPath: "/tmp/c.swift")
    let urlD = URL(fileURLWithPath: "/tmp/d.swift")
    let docA = EditorDocument(url: urlA)
    let docB = EditorDocument(url: urlB)
    let docC = EditorDocument(url: urlC)
    let docD = EditorDocument(url: urlD)
    session.openDocuments = [docA, docB, docC, docD]

    let tabA = EditorTabState(resource: .file(urlA))
    let tabB = EditorTabState(resource: .file(urlB))
    let tabC = EditorTabState(resource: .file(urlC))
    let tabD = EditorTabState(resource: .file(urlD))
    let groupLeft = EditorGroupState(tabs: [tabA, tabB], selectedTabID: tabA.id)
    let groupRight = EditorGroupState(tabs: [tabC, tabD], selectedTabID: tabD.id)
    session.editorLayout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(), axis: .horizontal, fraction: 0.5,
            first: .group(groupLeft), second: .group(groupRight)),
        focusedGroupID: groupLeft.id)

    session.applyRestoredHibernationPlaceholders()

    #expect(docA.loadState == .loaded)
    #expect(docD.loadState == .loaded)
    #expect(docB.loadState == .hibernated)
    #expect(docC.loadState == .hibernated)
}
