import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

/// Regression tests for dragging a tab to a group edge to split it (round 2,
/// X8). The SwiftUI and AppKit drag plumbing needs a window, so these pin the
/// pure rules behind it: which target owns a drag, which edge a point selects,
/// and what a split does to the layout.
@Suite("Editor tab drag to split")
struct EditorSplitDropTests {
    private let tab = EditorDragPayload.tab(id: UUID().uuidString)
    private let file = EditorDragPayload.file(path: "/tmp/a.swift")

    @Test("Without a board the group takes every private drag")
    func groupTakesEverythingWithoutBoard() {
        for payload in [tab, file, nil] as [EditorDragPayload?] {
            #expect(EditorDropRouting.groupAccepts(payload, canvasIsVisible: false))
        }
    }

    @Test("With a board the group takes tab drags and leaves files to the board")
    func groupTakesOnlyTabsOverBoard() {
        #expect(EditorDropRouting.groupAccepts(tab, canvasIsVisible: true))
        #expect(!EditorDropRouting.groupAccepts(file, canvasIsVisible: true))
        #expect(!EditorDropRouting.groupAccepts(nil, canvasIsVisible: true))
    }

    @Test("The board never takes a tab and keeps files and unknown drags")
    func boardDeclinesTabs() {
        #expect(!EditorDropRouting.canvasAccepts(tab))
        #expect(EditorDropRouting.canvasAccepts(file))
        #expect(EditorDropRouting.canvasAccepts(nil))
    }

    @Test("Exactly one target owns each known payload while a board is visible")
    func targetsAreExclusiveForKnownPayloads() {
        for payload in [tab, file] {
            let group = EditorDropRouting.groupAccepts(payload, canvasIsVisible: true)
            let board = EditorDropRouting.canvasAccepts(payload)
            #expect(group != board)
        }
    }

    @Test(
        "Each edge band selects its split edge in a wide group",
        arguments: [
            (CGPoint(x: 10, y: 300), EditorSplitEdge.leading),
            (CGPoint(x: 1_190, y: 300), EditorSplitEdge.trailing),
            (CGPoint(x: 600, y: 10), EditorSplitEdge.top),
            (CGPoint(x: 600, y: 590), EditorSplitEdge.bottom),
        ])
    func edgeBands(point: CGPoint, edge: EditorSplitEdge) {
        let size = CGSize(width: 1_200, height: 600)
        #expect(EditorDropGeometry.target(at: point, in: size) == edge)
    }

    @Test("The edge band is capped at 100 points in a large group")
    func edgeBandIsCapped() {
        let size = CGSize(width: 2_000, height: 1_000)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 99, y: 500), in: size) == .leading)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 101, y: 500), in: size) == nil)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 1_901, y: 500), in: size) == .trailing)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 1_899, y: 500), in: size) == nil)
    }

    @Test("In a narrow group the band shrinks to a quarter so the centre stays reachable")
    func narrowGroupKeepsCentre() {
        let size = CGSize(width: 240, height: 400)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 59, y: 200), in: size) == .leading)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 120, y: 200), in: size) == nil)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 181, y: 200), in: size) == .trailing)
    }

    @Test("A corner picks the nearer edge")
    func cornerPicksNearerEdge() {
        let size = CGSize(width: 800, height: 600)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 4, y: 40), in: size) == .leading)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 40, y: 4), in: size) == .top)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 796, y: 560), in: size) == .trailing)
        #expect(EditorDropGeometry.target(at: CGPoint(x: 760, y: 596), in: size) == .bottom)
    }

    @Test("Dropping a tab on the trailing edge splits and moves the tab")
    func trailingEdgeSplitMovesTab() throws {
        let first = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/one.swift")))
        let second = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/two.swift")))
        let group = EditorGroupState(tabs: [first, second])
        var layout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)

        let splitGroupID = layout.split(group: group.id, at: .trailing, moving: second.id)
        let created = try #require(splitGroupID)

        #expect(layout.groupIDs == [group.id, created])
        #expect(layout.group(id: group.id)?.tabs.map(\.id) == [first.id])
        #expect(layout.group(id: created)?.tabs.map(\.id) == [second.id])
        #expect(layout.focusedGroupID == created)
    }

    @Test("Dropping a tab on the leading edge puts the new group first")
    func leadingEdgeSplitPlacesNewGroupFirst() throws {
        let first = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/one.swift")))
        let second = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/two.swift")))
        let group = EditorGroupState(tabs: [first, second])
        var layout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)

        let splitGroupID = layout.split(group: group.id, at: .leading, moving: first.id)
        let created = try #require(splitGroupID)

        #expect(layout.groupIDs == [created, group.id])
    }

    @Test("Splitting a group by its only tab moves the tab into the new pane")
    func soleTabSelfSplitMovesTab() throws {
        let only = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/only.swift")))
        let group = EditorGroupState(tabs: [only])
        var layout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)

        let created = try #require(layout.split(group: group.id, at: .trailing, moving: only.id))
        #expect(layout.groupIDs == [group.id, created])
        #expect(layout.group(id: created)?.tabs.map(\.id) == [only.id])
        #expect(layout.group(id: group.id)?.tabs.isEmpty == true)
    }

    @Test("A sole tab from another group can still split a different group")
    func soleTabSplitsOtherGroup() throws {
        let moving = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/moving.swift")))
        let resident = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/resident.swift")))
        let sourceGroup = EditorGroupState(tabs: [moving])
        let targetGroup = EditorGroupState(tabs: [resident])
        var layout = EditorLayoutState(
            root: .split(
                id: EditorSplitID(), axis: .horizontal, fraction: 0.5,
                first: .group(sourceGroup), second: .group(targetGroup)))

        let splitGroupID = layout.split(group: targetGroup.id, at: .trailing, moving: moving.id)
        let created = try #require(splitGroupID)

        #expect(layout.group(id: sourceGroup.id) == nil)
        #expect(layout.group(containing: moving.id)?.id == created)
        #expect(layout.groupIDs.count == 2)
    }

    @Test("A tab dropped past the last tab appends to a group's bar")
    func dropPastLastTabAppends() {
        let frames = [
            CGRect(x: 0, y: 0, width: 100, height: 28),
            CGRect(x: 100, y: 0, width: 100, height: 28),
        ]
        #expect(TabStripDrop.insertionIndex(forX: 900, tabFrames: frames) == 2)
        #expect(TabStripDrop.insertionIndex(forX: 900, tabFrames: []) == 0)
    }
}
