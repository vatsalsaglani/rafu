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
