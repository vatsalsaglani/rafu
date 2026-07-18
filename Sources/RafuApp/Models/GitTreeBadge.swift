import SwiftUI

/// A compact Git-status marker for one file-tree row. Files carry their exact
/// short status code (mirroring `git status --short`, e.g. `M`, `A`, `??`);
/// directories carry the highest-severity status found anywhere beneath them,
/// so a change is visible at every ancestor up to the workspace root without
/// expanding the tree.
nonisolated struct GitTreeBadge: Hashable, Sendable {
    let kind: GitChangeKind
    let isDirectory: Bool

    /// Short code shown at the trailing edge of the row. Directory badges use
    /// a single-character form of the aggregated kind to stay quiet; file
    /// badges match `git status --short` exactly.
    var shortCode: String {
        switch kind {
        case .added: "A"
        case .copied: "C"
        case .conflicted: "U"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .typeChanged: "T"
        case .untracked: isDirectory ? "?" : "??"
        case .unknown: "•"
        }
    }

    /// VoiceOver description; the color-coded letter is never the sole channel.
    var accessibilityLabel: String {
        let scope = isDirectory ? "contains changes" : "status"
        let status: String =
            switch kind {
            case .added: "added"
            case .copied: "copied"
            case .conflicted: "conflicted"
            case .deleted: "deleted"
            case .modified: "modified"
            case .renamed: "renamed"
            case .typeChanged: "type changed"
            case .untracked: "untracked"
            case .unknown: "changed"
            }
        return isDirectory ? "Git: \(scope), \(status)" : "Git \(scope): \(status)"
    }

    func color(in palette: RafuThemePalette) -> Color {
        switch kind {
        case .conflicted: palette.gitConflict
        case .deleted: palette.gitDeleted
        case .added, .copied: palette.gitAdded
        case .untracked: palette.gitUntracked
        case .modified, .renamed, .typeChanged: palette.gitModified
        case .unknown: palette.textMuted
        }
    }

    /// Higher wins when a directory aggregates mixed descendant statuses:
    /// conflicts are most urgent; untracked-only is least. This ordering only
    /// selects which color/letter a folder shows, never whether it shows one.
    static func severity(of kind: GitChangeKind) -> Int {
        switch kind {
        case .conflicted: 7
        case .modified: 6
        case .renamed: 5
        case .typeChanged: 4
        case .added: 3
        case .copied: 3
        case .deleted: 2
        case .untracked: 1
        case .unknown: 0
        }
    }
}

extension GitSnapshot {
    /// Builds the file-tree decoration map keyed by **workspace-relative path**
    /// (the same identity `WorkspaceFileNode.relativePath` uses), so lookups
    /// need no per-row symlink normalization.
    ///
    /// `change.path` is relative to the Git repository root, which may sit at
    /// or above `workspaceRoot`; both are reduced to standardized absolute
    /// paths so the change can be re-expressed relative to the workspace.
    /// Changes outside the open workspace subtree are ignored. Every ancestor
    /// directory of a change (up to, but excluding, the workspace root) is
    /// marked with the most severe status beneath it.
    func treeBadges(workspaceRoot: URL) -> [String: GitTreeBadge] {
        let repositoryRoot = repositoryRoot ?? workspaceRoot
        let rootPath = workspaceRoot.standardizedFileURL.path
        var badges: [String: GitTreeBadge] = [:]

        for change in changes {
            let absolutePath =
                repositoryRoot.appending(path: change.path).standardizedFileURL.path
            guard absolutePath.hasPrefix(rootPath + "/") else { continue }
            let relativePath = String(absolutePath.dropFirst(rootPath.count + 1))
            guard !relativePath.isEmpty else { continue }

            badges[relativePath] = GitTreeBadge(kind: change.kind, isDirectory: false)

            // Roll the status up through every ancestor directory.
            let components = relativePath.split(separator: "/", omittingEmptySubsequences: true)
            guard components.count > 1 else { continue }
            for depth in 1..<components.count {
                let directoryPath = components[0..<depth].joined(separator: "/")
                if let existing = badges[directoryPath],
                    GitTreeBadge.severity(of: existing.kind)
                        >= GitTreeBadge.severity(of: change.kind)
                {
                    continue
                }
                badges[directoryPath] = GitTreeBadge(kind: change.kind, isDirectory: true)
            }
        }
        return badges
    }
}
