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

/// One typed ref on a commit, for the History graph's pills.
nonisolated struct GitRefLabel: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The checked-out branch ("HEAD -> refs/heads/main" names "main"),
        /// or a detached "HEAD".
        case head
        case local
        case remote
        case tag
    }

    let kind: Kind
    let name: String
}

/// Turns raw `%D` decorations into labels. History reads them with
/// `--decorate=full` ("HEAD -> refs/heads/main", "refs/remotes/origin/main",
/// "tag: refs/tags/v1"); the short form ("HEAD -> main", "origin/main",
/// "tag: v1") is still accepted.
nonisolated enum GitRefLabels {
    private static let localPrefix = "refs/heads/"
    private static let remotePrefix = "refs/remotes/"
    private static let tagPrefix = "refs/tags/"

    /// Plain chip labels (G10): no ASCII arrow, no "tag: " or "refs/..."
    /// prefix, HEAD first, duplicates removed. Full and short decorations
    /// give the same output.
    static func chips(from decorations: [String]) -> [String] {
        var labels: [String] = []
        for decoration in decorations {
            let trimmed = decoration.trimmingCharacters(in: .whitespaces)
            if let range = trimmed.range(of: "HEAD -> ") {
                labels.append("HEAD")
                labels.append(shortName(String(trimmed[range.upperBound...])))
            } else if trimmed.hasPrefix("tag: ") {
                labels.append(shortName(String(trimmed.dropFirst("tag: ".count))))
            } else if !trimmed.isEmpty {
                labels.append(shortName(trimmed))
            }
        }
        var seen = Set<String>()
        return labels.filter { seen.insert($0).inserted }
    }

    /// Typed labels for the graph pills, in display order: HEAD first, then
    /// local branches, remote branches, and tags, each in Git's order.
    /// "HEAD -> x" becomes one `.head` label named "x". A remote's symbolic
    /// HEAD ("origin/HEAD") is dropped: it only repeats the remote default
    /// branch. Duplicates are removed.
    static func labels(from decorations: [String]) -> [GitRefLabel] {
        var labels: [GitRefLabel] = []
        for decoration in decorations {
            let trimmed = decoration.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let range = trimmed.range(of: "HEAD -> ") {
                labels.append(
                    GitRefLabel(kind: .head, name: shortName(String(trimmed[range.upperBound...]))))
            } else if trimmed == "HEAD" {
                labels.append(GitRefLabel(kind: .head, name: "HEAD"))
            } else if trimmed.hasPrefix("tag: ") {
                labels.append(
                    GitRefLabel(
                        kind: .tag, name: shortName(String(trimmed.dropFirst("tag: ".count)))))
            } else if trimmed.hasPrefix(remotePrefix) {
                let name = String(trimmed.dropFirst(remotePrefix.count))
                guard !name.hasSuffix("/HEAD") else { continue }
                labels.append(GitRefLabel(kind: .remote, name: name))
            } else if trimmed.hasPrefix(tagPrefix) {
                labels.append(
                    GitRefLabel(kind: .tag, name: String(trimmed.dropFirst(tagPrefix.count))))
            } else {
                // `refs/heads/x`, or a short-form name with no prefix.
                labels.append(GitRefLabel(kind: .local, name: shortName(trimmed)))
            }
        }
        var seen = Set<GitRefLabel>()
        let unique = labels.filter { seen.insert($0).inserted }
        func rank(_ kind: GitRefLabel.Kind) -> Int {
            switch kind {
            case .head: 0
            case .local: 1
            case .remote: 2
            case .tag: 3
            }
        }
        // `enumerated` keeps the sort stable inside one kind.
        return unique.enumerated()
            .sorted { (rank($0.element.kind), $0.offset) < (rank($1.element.kind), $1.offset) }
            .map(\.element)
    }

    private static func shortName(_ ref: String) -> String {
        for prefix in [localPrefix, remotePrefix, tagPrefix] where ref.hasPrefix(prefix) {
            return String(ref.dropFirst(prefix.count))
        }
        return ref
    }
}

/// The stats line of the History hover card, phrased like Git's own
/// summary: "2 files changed, 5 insertions(+), 1 deletion(-)".
nonisolated enum GitCommitStatsPresentation {
    static func filesText(_ count: Int) -> String {
        count == 1 ? "1 file changed" : "\(count) files changed"
    }

    static func insertionsText(_ count: Int) -> String {
        count == 1 ? "1 insertion(+)" : "\(count) insertions(+)"
    }

    static func deletionsText(_ count: Int) -> String {
        count == 1 ? "1 deletion(-)" : "\(count) deletions(-)"
    }

    static func summary(for detail: GitCommitDetail) -> String {
        [
            filesText(detail.filesChanged), insertionsText(detail.insertions),
            deletionsText(detail.deletions),
        ].joined(separator: ", ")
    }

    /// The message without its first line (the subject the card already
    /// shows as its title), with surrounding blank lines removed.
    static func bodyWithoutSubject(_ body: String) -> String {
        guard let newline = body.firstIndex(of: "\n") else { return "" }
        return String(body[body.index(after: newline)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Joins the hard line breaks of a commit body so it wraps to the width of
/// the hover card and the expanded row. Commit bodies are usually wrapped at
/// 72 columns; shown in a proportional font at another width, those breaks
/// make every paragraph ragged.
///
/// Rules, in order:
/// - A blank line ends a paragraph. Runs of blank lines become one.
/// - A fenced code block (a line that starts with three backticks or
///   tildes, through the closing fence) is kept line for line.
/// - A line that starts with a list marker ("- ", "* ", "• ", or digits
///   followed by "." or ")" and a space) starts a new line.
/// - An indented line continues the list item above it when it is indented
///   by one to four spaces (a wrapped list item). Any other indented line
///   (indented code, a tab) is kept as it is.
/// - Consecutive lines shaped like Git trailers ("Token: value", such as
///   "Co-Authored-By: …") stay on their own lines.
/// - Any other line joins the line above it with one space.
nonisolated enum GitCommitMessageReflow {
    static func reflow(_ text: String) -> String {
        enum Open {
            /// The last output line cannot take a joined line.
            case none
            case prose
            case listItem
        }

        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var open = Open.none
        var inFence = false
        var previousWasTrailer = false

        func join(_ content: Substring) {
            output[output.count - 1] += " " + content
        }

        for rawLine in lines {
            let line = trimmingTrailingWhitespace(rawLine)
            let content = line.drop(while: { $0 == " " || $0 == "\t" })
            let isTrailer = isTrailerLine(content)
            defer { previousWasTrailer = isTrailer && !inFence }

            if inFence {
                output.append(String(line))
                if isFenceLine(content) { inFence = false }
                continue
            }
            if isFenceLine(content) {
                output.append(String(line))
                inFence = true
                open = .none
                continue
            }
            if content.isEmpty {
                if let last = output.last, !last.isEmpty { output.append("") }
                open = .none
                continue
            }
            if isListMarkerLine(content) {
                output.append(String(line))
                open = .listItem
                continue
            }
            let indent = line.count - content.count
            if indent > 0 {
                let isSpaceIndent = !line.prefix(indent).contains("\t")
                if open == .listItem, isSpaceIndent, indent <= 4 {
                    join(content)
                } else {
                    output.append(String(line))
                    open = .none
                }
                continue
            }
            if open != .none, !(isTrailer && previousWasTrailer) {
                join(content)
            } else {
                output.append(String(line))
                open = .prose
            }
        }
        while output.last?.isEmpty == true { output.removeLast() }
        while output.first?.isEmpty == true { output.removeFirst() }
        return output.joined(separator: "\n")
    }

    private static func trimmingTrailingWhitespace(_ line: Substring) -> Substring {
        var end = line.endIndex
        while end > line.startIndex {
            let previous = line.index(before: end)
            guard line[previous] == " " || line[previous] == "\t" else { break }
            end = previous
        }
        return line[..<end]
    }

    private static func isFenceLine(_ content: Substring) -> Bool {
        content.hasPrefix("```") || content.hasPrefix("~~~")
    }

    private static func isListMarkerLine(_ content: Substring) -> Bool {
        if ["- ", "* ", "• "].contains(where: { content.hasPrefix($0) }) { return true }
        let digits = content.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty else { return false }
        let rest = content.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    /// "Token: value", where the token is a letter followed by letters,
    /// digits, or hyphens (Git's trailer shape).
    private static func isTrailerLine(_ content: Substring) -> Bool {
        guard let colon = content.firstIndex(of: ":"), colon > content.startIndex,
            content[content.index(after: colon)...].hasPrefix(" ")
        else { return false }
        let token = content[..<colon]
        guard let first = token.first, first.isLetter, first.isASCII else { return false }
        return token.allSatisfy { ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "-" }
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
