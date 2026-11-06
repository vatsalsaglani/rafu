import AppKit
import Foundation

/// How a click on a Files row changes the selection. Control is not a
/// selection modifier: Control-click is the macOS secondary click, which
/// opens the row's context menu.
nonisolated enum FileTreeClickModifier: Equatable, Sendable {
    /// Plain click: select only this row (a file row also opens).
    case none
    /// Command-click: add or remove this row; never opens.
    case toggle
    /// Shift-click: select the visible range from the anchor; never opens.
    case extend

    /// Reads the click's modifiers. Returns nil for a Control-click, which
    /// belongs to the context menu and must not change the selection.
    init?(flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection([.command, .shift, .control, .option])
        if flags.contains(.control) { return nil }
        if flags.contains(.command) {
            self = .toggle
        } else if flags.contains(.shift) {
            self = .extend
        } else {
            self = .none
        }
    }
}

/// The Files tree selection of one window: a set of absolute paths, the
/// anchor a Shift range starts from, and the lead (the moving end of a
/// Shift range). Pure value logic, so it is testable without views.
nonisolated struct FileTreeSelection: Equatable, Sendable {
    private(set) var paths: Set<String> = []
    private(set) var anchor: String?
    private(set) var lead: String?

    /// The one path that stands for the selection: the anchor while it is
    /// selected, otherwise the first selected path in sorted order.
    var primaryPath: String? {
        if let anchor, paths.contains(anchor) { return anchor }
        return paths.min()
    }

    /// Replaces the selection with `path` (or clears it). Every
    /// programmatic writer (editor tab sync, reveal) goes through this, so
    /// those paths always collapse a multi-selection to one row.
    mutating func select(_ path: String?) {
        paths = path.map { [$0] } ?? []
        anchor = path
        lead = path
    }

    /// Applies one row click. `visibleOrder` is the tree's visible rows,
    /// top to bottom (`FileTreeVisibleOrder`).
    mutating func click(
        _ path: String, modifier: FileTreeClickModifier, visibleOrder: [String]
    ) {
        switch modifier {
        case .none:
            select(path)
        case .toggle:
            if paths.contains(path) {
                paths.remove(path)
            } else {
                paths.insert(path)
            }
            anchor = path
            lead = path
        case .extend:
            guard let anchor, let range = Self.range(from: anchor, to: path, in: visibleOrder)
            else {
                select(path)
                return
            }
            paths = Set(range)
            lead = path
        }
    }

    /// Shift-Up (`offset` -1) or Shift-Down (+1): moves the lead one visible
    /// row and selects the range from the anchor to it. Returns false when
    /// nothing changed (no anchor on screen, or already at an end).
    @discardableResult
    mutating func extend(by offset: Int, visibleOrder: [String]) -> Bool {
        guard let anchor, let anchorIndex = visibleOrder.firstIndex(of: anchor) else {
            return false
        }
        let leadIndex = lead.flatMap { visibleOrder.firstIndex(of: $0) } ?? anchorIndex
        let next = leadIndex + offset
        guard visibleOrder.indices.contains(next) else { return false }
        let target = visibleOrder[next]
        guard let range = Self.range(from: anchor, to: target, in: visibleOrder) else {
            return false
        }
        paths = Set(range)
        lead = target
        return true
    }

    /// Removes every selected path equal to or under one of `removed`
    /// (items moved to the Trash).
    mutating func remove(itemsAt removed: [String]) {
        func isRemoved(_ path: String) -> Bool {
            removed.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
        paths = paths.filter { !isRemoved($0) }
        if let anchor, isRemoved(anchor) { self.anchor = primaryPath }
        if let lead, isRemoved(lead) { self.lead = anchor }
    }

    private static func range(from start: String, to end: String, in order: [String])
        -> ArraySlice<String>?
    {
        guard let first = order.firstIndex(of: start), let last = order.firstIndex(of: end)
        else { return nil }
        return order[min(first, last)...max(first, last)]
    }
}

/// The Files rows the user can see, top to bottom, as absolute paths. It
/// walks the loaded listings through expanded folders only, so a row under
/// a collapsed folder or a collapsed root is never part of a Shift range.
nonisolated enum FileTreeVisibleOrder {
    struct Tree: Sendable {
        var loadedChildren: [String: [WorkspaceFileNode]]
        var expandedDirectories: Set<String>
        /// A collapsed root section (multi-folder workspaces) shows no rows.
        var isCollapsed = false
    }

    static func paths(in trees: [Tree]) -> [String] {
        var result: [String] = []
        for tree in trees where !tree.isCollapsed {
            append(children: tree.loadedChildren[""] ?? [], of: tree, to: &result)
        }
        return result
    }

    private static func append(
        children: [WorkspaceFileNode], of tree: Tree, to result: inout [String]
    ) {
        for node in children {
            result.append(node.url.path)
            guard node.isDirectory, tree.expandedDirectories.contains(node.relativePath),
                let grandchildren = tree.loadedChildren[node.relativePath]
            else { continue }
            append(children: grandchildren, of: tree, to: &result)
        }
    }
}
