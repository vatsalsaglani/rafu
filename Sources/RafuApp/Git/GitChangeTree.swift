import Foundation

/// A folder's aggregate staging state across every file beneath it, used to
/// drive the tree view's tri-state folder checkbox. A single partially
/// staged file (staged index + unstaged worktree edits) counts as `.some`
/// for every ancestor folder, not `.all`.
nonisolated enum GitChangeStagingState: Equatable, Sendable {
    case all
    case some
    case none
}

/// One folder in the Source Control tree. `id` is the folder's full,
/// uncompacted path (stable identity for expansion state and staging), while
/// `displayName` may show a chain-compacted run of segments (for example
/// "Sources/RafuApp") when every intermediate segment has exactly one child
/// directory and no files of its own.
nonisolated struct GitChangeTreeNode: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let directories: [GitChangeTreeNode]
    let files: [GitChange]
    /// Every file path recursively beneath this folder, in display order.
    /// Passed directly to `WorkspaceSession.setStaged(_:paths:)` for the
    /// folder checkbox's single batch stage/unstage process.
    let descendantPaths: [String]
    let stagingState: GitChangeStagingState

    var fileCount: Int { descendantPaths.count }
}

/// The full grouped view of a changeset: files directly at the repository
/// root (no folder to group under) plus the compacted top-level folders.
nonisolated struct GitChangeTree: Sendable {
    let rootFiles: [GitChange]
    let directories: [GitChangeTreeNode]

    static let empty = GitChangeTree(rootFiles: [], directories: [])
}

/// One flattened, indented row for rendering the tree in a plain `List`.
nonisolated enum GitChangeTreeRow: Identifiable, Sendable {
    case folder(GitChangeTreeNode, depth: Int)
    case file(GitChange, depth: Int)

    /// Folder rows use a `"dir:"`-namespaced id so they can never collide
    /// with a `GitChange.id` (a repo-relative path) if some future consumer
    /// starts reading tree-row ids as selection state.
    var id: String {
        switch self {
        case .folder(let node, _): "dir:" + node.id
        case .file(let change, _): change.id
        }
    }
}

/// Pure, process-free grouping of Git changes into a folder tree. Does not
/// filter conflicts itself — callers pass only the non-conflicted subset,
/// since Conflicts stays a flat section above the tree in the UI.
nonisolated enum GitChangeTreeBuilder {
    static func build(changes: [GitChange]) -> GitChangeTree {
        let root = TrieNode(name: "", path: "")
        for change in changes {
            let components = change.path.split(separator: "/").map(String.init)
            guard !components.isEmpty else { continue }
            let directoryComponents = components.dropLast()
            guard !directoryComponents.isEmpty else {
                root.files.append(change)
                continue
            }
            var current = root
            var pathSoFar = ""
            for segment in directoryComponents {
                pathSoFar = pathSoFar.isEmpty ? segment : "\(pathSoFar)/\(segment)"
                if let existing = current.children[segment] {
                    current = existing
                } else {
                    let child = TrieNode(name: segment, path: pathSoFar)
                    current.children[segment] = child
                    current = child
                }
            }
            current.files.append(change)
        }

        let directories = sortedChildren(of: root).map { convert($0).node }
        let rootFiles = root.files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        return GitChangeTree(rootFiles: rootFiles, directories: directories)
    }

    /// Flattens a tree into ordered, indented rows: directories before files
    /// at every level, expanded unless their id is in `collapsedIDs`.
    static func visibleRows(tree: GitChangeTree, collapsedIDs: Set<String>) -> [GitChangeTreeRow] {
        var rows: [GitChangeTreeRow] = []
        for node in tree.directories {
            appendRows(node: node, depth: 0, collapsedIDs: collapsedIDs, into: &rows)
        }
        for file in tree.rootFiles {
            rows.append(.file(file, depth: 0))
        }
        return rows
    }

    private static func appendRows(
        node: GitChangeTreeNode,
        depth: Int,
        collapsedIDs: Set<String>,
        into rows: inout [GitChangeTreeRow]
    ) {
        rows.append(.folder(node, depth: depth))
        guard !collapsedIDs.contains(node.id) else { return }
        for child in node.directories {
            appendRows(node: child, depth: depth + 1, collapsedIDs: collapsedIDs, into: &rows)
        }
        for file in node.files {
            rows.append(.file(file, depth: depth + 1))
        }
    }

    private struct BuildResult {
        let node: GitChangeTreeNode
        /// Every file recursively beneath `node`, kept only to let the
        /// parent aggregate its own `stagingState`.
        let files: [GitChange]
    }

    /// Converts one trie node into a display node, compacting a chain of
    /// single-child, file-less directories into one segment (for example
    /// "Sources/RafuApp"). Compaction stops as soon as a directory has its
    /// own files or more than one child.
    private static func convert(_ node: TrieNode) -> BuildResult {
        var segments = [node.name]
        var current = node
        while current.files.isEmpty, current.children.count == 1,
            let onlyChild = current.children.values.first
        {
            segments.append(onlyChild.name)
            current = onlyChild
        }

        let displayName = segments.joined(separator: "/")
        let childResults = sortedChildren(of: current).map(convert)
        let ownFiles = current.files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
        let allFiles = childResults.flatMap(\.files) + ownFiles

        let treeNode = GitChangeTreeNode(
            id: current.path,
            displayName: displayName,
            directories: childResults.map(\.node),
            files: ownFiles,
            descendantPaths: allFiles.map(\.path),
            stagingState: stagingState(for: allFiles)
        )
        return BuildResult(node: treeNode, files: allFiles)
    }

    private static func sortedChildren(of node: TrieNode) -> [TrieNode] {
        node.children.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private static func stagingState(for files: [GitChange]) -> GitChangeStagingState {
        guard !files.isEmpty else { return .none }
        if files.allSatisfy({ $0.isStaged && !$0.hasUnstagedChanges }) { return .all }
        if files.allSatisfy({ !$0.isStaged }) { return .none }
        return .some
    }

    private final class TrieNode {
        let name: String
        let path: String
        var children: [String: TrieNode] = [:]
        var files: [GitChange] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }
}
