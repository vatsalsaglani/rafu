import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Files tree selection model")
struct FileTreeSelectionModelTests {
    private let order = ["/w/a", "/w/b", "/w/c", "/w/d", "/w/e"]

    @Test("A plain click selects one row and sets the anchor")
    func plainClick() {
        var selection = FileTreeSelection()
        selection.click("/w/b", modifier: .none, visibleOrder: order)
        #expect(selection.paths == ["/w/b"])
        #expect(selection.anchor == "/w/b")
        #expect(selection.primaryPath == "/w/b")
    }

    @Test("Command-click toggles a row and moves the anchor")
    func toggle() {
        var selection = FileTreeSelection()
        selection.click("/w/a", modifier: .none, visibleOrder: order)
        selection.click("/w/c", modifier: .toggle, visibleOrder: order)
        #expect(selection.paths == ["/w/a", "/w/c"])
        #expect(selection.anchor == "/w/c")
        selection.click("/w/a", modifier: .toggle, visibleOrder: order)
        #expect(selection.paths == ["/w/c"])
        // The anchor is the toggled-off row; the primary path stays selected.
        #expect(selection.anchor == "/w/a")
        #expect(selection.primaryPath == "/w/c")
    }

    @Test("Shift-click selects the visible range forward and backward")
    func range() {
        var selection = FileTreeSelection()
        selection.click("/w/b", modifier: .none, visibleOrder: order)
        selection.click("/w/d", modifier: .extend, visibleOrder: order)
        #expect(selection.paths == ["/w/b", "/w/c", "/w/d"])
        #expect(selection.anchor == "/w/b")
        selection.click("/w/a", modifier: .extend, visibleOrder: order)
        #expect(selection.paths == ["/w/a", "/w/b"])
        #expect(selection.anchor == "/w/b")
    }

    @Test("Shift-click with no visible anchor selects only the row")
    func rangeWithoutAnchor() {
        var selection = FileTreeSelection()
        selection.click("/w/c", modifier: .extend, visibleOrder: order)
        #expect(selection.paths == ["/w/c"])
        #expect(selection.anchor == "/w/c")
        selection.select("/hidden/x")
        selection.click("/w/e", modifier: .extend, visibleOrder: order)
        #expect(selection.paths == ["/w/e"])
    }

    @Test("Shift-arrows move the lead and stop at the ends")
    func extendWithArrows() {
        var selection = FileTreeSelection()
        selection.click("/w/c", modifier: .none, visibleOrder: order)
        var moved = selection.extend(by: 1, visibleOrder: order)
        #expect(moved)
        moved = selection.extend(by: 1, visibleOrder: order)
        #expect(moved)
        #expect(selection.paths == ["/w/c", "/w/d", "/w/e"])
        moved = selection.extend(by: 1, visibleOrder: order)
        #expect(!moved)
        moved = selection.extend(by: -1, visibleOrder: order)
        #expect(moved)
        moved = selection.extend(by: -1, visibleOrder: order)
        #expect(moved)
        moved = selection.extend(by: -1, visibleOrder: order)
        #expect(moved)
        #expect(selection.paths == ["/w/b", "/w/c"])
    }

    @Test("Setting one path collapses a multi-selection")
    func compatibilityCollapse() {
        var selection = FileTreeSelection()
        selection.click("/w/a", modifier: .none, visibleOrder: order)
        selection.click("/w/e", modifier: .extend, visibleOrder: order)
        #expect(selection.paths.count == 5)
        selection.select("/w/d")
        #expect(selection.paths == ["/w/d"])
        selection.select(nil)
        #expect(selection.paths.isEmpty)
        #expect(selection.primaryPath == nil)
    }

    @Test("Removing trashed items drops them and their descendants")
    func removeTrashed() {
        var selection = FileTreeSelection()
        selection.click("/w/a", modifier: .none, visibleOrder: order)
        selection.click("/w/b", modifier: .toggle, visibleOrder: order)
        selection.click("/w/a/x", modifier: .toggle, visibleOrder: order)
        selection.remove(itemsAt: ["/w/a"])
        #expect(selection.paths == ["/w/b"])
        #expect(selection.primaryPath == "/w/b")
    }

    @Test("Click modifiers: Command toggles, Shift extends, Control is ignored")
    func modifierFlags() {
        #expect(FileTreeClickModifier(flags: []) == FileTreeClickModifier.none)
        #expect(FileTreeClickModifier(flags: .command) == .toggle)
        #expect(FileTreeClickModifier(flags: [.command, .shift]) == .toggle)
        #expect(FileTreeClickModifier(flags: .shift) == .extend)
        #expect(FileTreeClickModifier(flags: .control) == nil)
        #expect(FileTreeClickModifier(flags: [.control, .command]) == nil)
    }
}

@Suite("Files tree visible order")
struct FileTreeVisibleOrderTests {
    private func node(_ root: String, _ relative: String, directory: Bool = false)
        -> WorkspaceFileNode
    {
        WorkspaceFileNode(
            url: URL(filePath: root + "/" + relative), relativePath: relative,
            isDirectory: directory)
    }

    @Test("Expanded folders show their children; collapsed folders do not")
    func primaryTree() {
        let tree = FileTreeVisibleOrder.Tree(
            loadedChildren: [
                "": [node("/w", "src", directory: true), node("/w", "README.md")],
                "src": [node("/w", "src/a.swift"), node("/w", "src/lib", directory: true)],
                "src/lib": [node("/w", "src/lib/b.swift")],
            ],
            expandedDirectories: ["src"])
        #expect(
            FileTreeVisibleOrder.paths(in: [tree]) == [
                "/w/src", "/w/src/a.swift", "/w/src/lib", "/w/README.md",
            ])
    }

    @Test("Additional roots follow in order and a collapsed root is skipped")
    func additionalRoots() {
        let primary = FileTreeVisibleOrder.Tree(
            loadedChildren: ["": [node("/app", "main.swift")]], expandedDirectories: [])
        let collapsed = FileTreeVisibleOrder.Tree(
            loadedChildren: ["": [node("/lib", "lib.swift")]], expandedDirectories: [""],
            isCollapsed: true)
        let docs = FileTreeVisibleOrder.Tree(
            loadedChildren: ["": [node("/docs", "guide.md")]], expandedDirectories: [""])
        #expect(
            FileTreeVisibleOrder.paths(in: [primary, collapsed, docs]) == [
                "/app/main.swift", "/docs/guide.md",
            ])
    }
}
