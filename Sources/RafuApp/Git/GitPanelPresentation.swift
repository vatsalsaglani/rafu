import Foundation

// Pure presentation helpers for the Source Control panel and the diff header
// (macOS redesign W2, findings G1-G12). Everything here is value-only and
// UI-free so it is unit tested without instantiating SwiftUI.

/// The single status vocabulary shared by the Files sidebar badges
/// (`GitTreeBadge`) and the Source Control rows (G3). One letter per state,
/// one title per state; untracked is `U`, a staged new file is `A`.
nonisolated enum GitStatusPresentation {
    /// Single-character marker. Matches `GitTreeBadge.shortCode`.
    static func letter(for kind: GitChangeKind) -> String {
        switch kind {
        case .added: "A"
        case .copied: "C"
        case .conflicted: "!"
        case .deleted: "D"
        case .modified: "M"
        case .renamed: "R"
        case .typeChanged: "T"
        case .untracked: "U"
        case .unknown: "•"
        }
    }

    /// Tooltip and VoiceOver title for the marker.
    static func title(for kind: GitChangeKind) -> String {
        switch kind {
        case .added: "Added"
        case .copied: "Copied"
        case .conflicted: "Conflict"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .typeChanged: "Type Changed"
        case .untracked: "Untracked"
        case .unknown: "Changed"
        }
    }
}

/// A repository-relative path split for a one-line file row (G2): the file
/// name, and the folder only when the file is not at the repository root.
nonisolated struct GitChangePathParts: Equatable, Sendable {
    let name: String
    let folder: String?

    init(path: String) {
        guard let separator = path.lastIndex(of: "/") else {
            name = path
            folder = nil
            return
        }
        let folderText = String(path[path.startIndex..<separator])
        name = String(path[path.index(after: separator)...])
        folder = folderText.isEmpty ? nil : folderText
    }
}

/// Short relative time for history and stash rows (G6, G10): seconds only in
/// the first minute, then "2 min ago", "3 h ago", "4 d ago", and so on.
nonisolated enum GitRelativeTime {
    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 10 { return "just now" }
        if seconds < 60 { return "\(seconds) sec ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        if days < 7 { return "\(days) d ago" }
        if days < 30 { return "\(days / 7) w ago" }
        if days < 365 { return "\(days / 30) mo ago" }
        return "\(days / 365) y ago"
    }
}

/// The neutral sync control's state and wording (G4, G15).
nonisolated struct GitSyncPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The repository has no remote at all.
        case noRemote
        /// A remote exists but the current branch does not track one.
        case noUpstream
        /// The current branch tracks an upstream.
        case tracking
    }

    static let noRemoteHelp = "This repository has no remote."

    let state: State
    let aheadCount: Int
    let behindCount: Int

    static func resolve(
        hasRemote: Bool, upstream: String?, aheadCount: Int, behindCount: Int
    ) -> GitSyncPresentation {
        if upstream != nil {
            return GitSyncPresentation(
                state: .tracking,
                aheadCount: max(0, aheadCount),
                behindCount: max(0, behindCount)
            )
        }
        return GitSyncPresentation(
            state: hasRemote ? .noUpstream : .noRemote, aheadCount: 0, behindCount: 0)
    }

    /// Text shown in the capsule: "↑2 ↓1", "No upstream", or "No remote".
    var label: String {
        switch state {
        case .noRemote: "No remote"
        case .noUpstream: "No upstream"
        case .tracking: "↑\(aheadCount) ↓\(behindCount)"
        }
    }

    var accessibilityLabel: String {
        switch state {
        case .noRemote: "Sync: no remote"
        case .noUpstream: "Sync: no upstream branch"
        case .tracking:
            "Sync: \(aheadCount) commits ahead, \(behindCount) commits behind"
        }
    }

    /// Fetch, Pull, and Push can only fail without a remote.
    var canSync: Bool { state != .noRemote }
}

/// Section picker layout rule (G1): segments show words, and fall back to
/// icons with tooltips below `iconThreshold` points of available width.
nonisolated enum GitSectionPickerLayout {
    static let iconThreshold: CGFloat = 320

    static func usesIcons(forWidth width: CGFloat) -> Bool {
        width < iconThreshold
    }
}

nonisolated extension GitInspectorSection {
    /// SF Symbol used when the picker is too narrow for words.
    var symbolName: String {
        switch self {
        case .changes: "plusminus"
        case .history: "clock.arrow.circlepath"
        case .worktrees: "point.3.connected.trianglepath.dotted"
        }
    }

    /// Segment text: "Changes (3)", "History", "Worktrees". The count is
    /// omitted when it is zero.
    func segmentLabel(changeCount: Int) -> String {
        guard self == .changes, changeCount > 0 else { return title }
        return "\(title) (\(changeCount))"
    }
}

nonisolated extension GitChangesViewMode {
    /// Menu wording for the "View as" pull-down (G5).
    var title: String {
        switch self {
        case .flat: "List"
        case .tree: "Tree"
        }
    }

    var symbolName: String {
        switch self {
        case .flat: "list.bullet"
        case .tree: "list.bullet.indent"
        }
    }
}

/// Caption under the commit message field (G7).
nonisolated enum GitCommitCaption {
    static func text(stagedCount: Int) -> String {
        switch stagedCount {
        case ..<1: "Nothing staged"
        case 1: "Commits 1 file"
        default: "Commits \(stagedCount) files"
        }
    }
}

/// Turns raw `%D` decorations ("HEAD -> main", "origin/main", "tag: v1") into
/// plain chip labels (G10): no ASCII arrow, tags without the "tag: " prefix,
/// HEAD first, duplicates removed.
nonisolated enum GitRefLabels {
    static func chips(from decorations: [String]) -> [String] {
        var labels: [String] = []
        for decoration in decorations {
            let trimmed = decoration.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "HEAD -> ") {
                labels.append("HEAD")
                labels.append(String(trimmed[range.upperBound...]))
            } else if trimmed.hasPrefix("tag: ") {
                labels.append(String(trimmed.dropFirst("tag: ".count)))
            } else if !trimmed.isEmpty {
                labels.append(trimmed)
            }
        }
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }
}

/// Splits a full object ID into fixed-width lines (G11). Breaking by
/// character count, with no hyphen glyph, keeps a copied or read hash exact.
nonisolated enum GitHashDisplay {
    static func lines(for hash: String, perLine: Int = 20) -> [String] {
        guard perLine > 0, !hash.isEmpty else { return hash.isEmpty ? [] : [hash] }
        var lines: [String] = []
        var index = hash.startIndex
        while index < hash.endIndex {
            let end =
                hash.index(index, offsetBy: perLine, limitedBy: hash.endIndex) ?? hash.endIndex
            lines.append(String(hash[index..<end]))
            index = end
        }
        return lines
    }
}

nonisolated struct GitDiffLineCounts: Equatable, Sendable {
    let added: Int
    let deleted: Int
}

/// Wording for the diff header (G8): the real comparison, a path breadcrumb,
/// and the "+n −n" counts.
nonisolated enum GitDiffHeaderPresentation {
    /// New side first, matching the "Before | After" columns read right to left.
    static func comparisonLabel(for scope: GitDiffScope) -> String {
        switch scope {
        case .workingTree: "Working Tree ↔ Index"
        case .staged: "Index ↔ HEAD"
        case .commit(let revision): "\(shortRevision(revision)) ↔ Parent"
        case .between(let base, let head): "\(shortRevision(head)) ↔ \(shortRevision(base))"
        }
    }

    static func shortRevision(_ revision: String) -> String {
        String(revision.prefix(8))
    }

    /// Path components for a breadcrumb. When there are more than
    /// `maximumComponents`, the leading folders collapse into one "…".
    static func breadcrumb(for path: String, maximumComponents: Int = 4) -> [String] {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        let limit = max(2, maximumComponents)
        guard components.count > limit else { return components }
        return ["…"] + components.suffix(limit - 1)
    }

    static func lineCounts(for diff: GitFileDiff) -> GitDiffLineCounts {
        let rows = diff.rows
        let added = rows.count {
            $0.newLine != nil && ($0.kind == .addition || $0.kind == .modification)
        }
        let deleted = rows.count {
            $0.oldLine != nil && ($0.kind == .deletion || $0.kind == .modification)
        }
        return GitDiffLineCounts(added: added, deleted: deleted)
    }
}
