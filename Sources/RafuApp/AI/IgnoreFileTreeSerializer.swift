import Foundation

/// Deterministic, bounded text rendering of a workspace's relative file
/// paths — the only workspace content the ignore-suggestion prompt sends
/// (see `IgnoreSuggestionPromptBuilder`). Paths only, never file contents.
/// Sorted so identical inputs always serialize identically; directory
/// children beyond `maxChildrenPerDirectory` collapse into one "… and K
/// more" line; total output stops at `maxLines` so an enormous monorepo
/// can never blow the AI request's byte budget.
nonisolated enum IgnoreFileTreeSerializer {
    private final class Node {
        var children: [String: Node] = [:]
        var isFile = false
    }

    static func serialize(
        paths: [String],
        maxLines: Int = 400,
        maxChildrenPerDirectory: Int = 20
    ) -> String {
        let root = Node()
        for path in paths {
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
            guard !components.isEmpty else { continue }
            var current = root
            for (index, component) in components.enumerated() {
                let child = current.children[component] ?? Node()
                if index == components.count - 1 { child.isFile = true }
                current.children[component] = child
                current = child
            }
        }

        var lines: [String] = []
        var isTruncated = false
        render(
            node: root, depth: 0, maxChildrenPerDirectory: maxChildrenPerDirectory,
            lines: &lines, maxLines: maxLines, isTruncated: &isTruncated
        )
        if isTruncated {
            lines.append("… output truncated")
        }
        return lines.joined(separator: "\n")
    }

    private static func render(
        node: Node,
        depth: Int,
        maxChildrenPerDirectory: Int,
        lines: inout [String],
        maxLines: Int,
        isTruncated: inout Bool
    ) {
        guard !isTruncated else { return }
        let sortedKeys = node.children.keys.sorted()
        let indentation = String(repeating: "  ", count: depth)
        for (index, key) in sortedKeys.enumerated() {
            guard lines.count < maxLines else {
                isTruncated = true
                return
            }
            guard index < maxChildrenPerDirectory else {
                lines.append("\(indentation)… and \(sortedKeys.count - index) more")
                return
            }
            guard let child = node.children[key] else { continue }
            let hasChildren = !child.children.isEmpty
            lines.append(indentation + key + (hasChildren ? "/" : ""))
            if hasChildren {
                render(
                    node: child, depth: depth + 1,
                    maxChildrenPerDirectory: maxChildrenPerDirectory,
                    lines: &lines, maxLines: maxLines, isTruncated: &isTruncated
                )
            }
        }
    }
}
