import Foundation

nonisolated enum GitChangeKind: String, Hashable, Sendable {
    case added
    case copied
    case conflicted
    case deleted
    case modified
    case renamed
    case typeChanged
    case untracked
    case unknown
}

nonisolated struct GitChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let indexStatus: Character
    let worktreeStatus: Character
    let kind: GitChangeKind

    init(
        path: String,
        originalPath: String? = nil,
        indexStatus: Character,
        worktreeStatus: Character,
        kind: GitChangeKind? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.indexStatus = indexStatus
        self.worktreeStatus = worktreeStatus
        self.kind =
            kind
            ?? Self.resolveKind(
                indexStatus: indexStatus,
                worktreeStatus: worktreeStatus,
                hasOriginalPath: originalPath != nil
            )
    }

    var id: String { path }

    var isStaged: Bool {
        !Self.isUnchanged(indexStatus) && indexStatus != "?"
    }

    var hasUnstagedChanges: Bool {
        !Self.isUnchanged(worktreeStatus) || kind == .untracked
    }

    var isConflicted: Bool { kind == .conflicted }

    var statusLabel: String {
        switch kind {
        case .added, .untracked: "Added"
        case .copied: "Copied"
        case .conflicted: "Conflict"
        case .deleted: "Deleted"
        case .modified: "Modified"
        case .renamed: "Renamed"
        case .typeChanged: "Type Changed"
        case .unknown: "Changed"
        }
    }

    private static func isUnchanged(_ status: Character) -> Bool {
        status == "." || status == " "
    }

    private static func resolveKind(
        indexStatus: Character,
        worktreeStatus: Character,
        hasOriginalPath: Bool
    ) -> GitChangeKind {
        let pair = String([indexStatus, worktreeStatus])
        if ["DD", "AU", "UD", "UA", "DU", "AA", "UU"].contains(pair) {
            return .conflicted
        }
        if indexStatus == "?" || worktreeStatus == "?" { return .untracked }
        let statuses = [indexStatus, worktreeStatus]
        if statuses.contains("R") || hasOriginalPath { return .renamed }
        if statuses.contains("C") { return .copied }
        if statuses.contains("A") { return .added }
        if statuses.contains("D") { return .deleted }
        if statuses.contains("T") { return .typeChanged }
        if statuses.contains("M") { return .modified }
        return .unknown
    }
}

/// Added/deleted line counts for one path, merged across the working-tree and
/// staged `git diff --numstat` outputs. `nil` counts mean git reported the
/// path as binary (`-\t-`); `isBinary` distinguishes that from "no data yet".
nonisolated struct GitLineStats: Equatable, Sendable {
    var added: Int?
    var deleted: Int?
    var isBinary: Bool = false

    static func merge(_ lhs: GitLineStats?, _ rhs: GitLineStats) -> GitLineStats {
        guard let lhs else { return rhs }
        if lhs.isBinary || rhs.isBinary { return GitLineStats(isBinary: true) }
        return GitLineStats(
            added: (lhs.added ?? 0) + (rhs.added ?? 0),
            deleted: (lhs.deleted ?? 0) + (rhs.deleted ?? 0)
        )
    }
}

nonisolated struct GitSnapshot: Sendable {
    let repositoryRoot: URL?
    let branch: String
    let headOID: String?
    let upstream: String?
    let aheadCount: Int
    let behindCount: Int
    let isDetached: Bool
    let isUnborn: Bool
    let changes: [GitChange]

    init(
        repositoryRoot: URL? = nil,
        branch: String,
        headOID: String? = nil,
        upstream: String? = nil,
        aheadCount: Int = 0,
        behindCount: Int = 0,
        isDetached: Bool = false,
        isUnborn: Bool = false,
        changes: [GitChange]
    ) {
        self.repositoryRoot = repositoryRoot
        self.branch = branch
        self.headOID = headOID
        self.upstream = upstream
        self.aheadCount = aheadCount
        self.behindCount = behindCount
        self.isDetached = isDetached
        self.isUnborn = isUnborn
        self.changes = changes
    }

    var stagedChanges: [GitChange] {
        changes.filter { $0.isStaged && !$0.isConflicted }
    }

    var unstagedChanges: [GitChange] {
        changes.filter { $0.hasUnstagedChanges && !$0.isConflicted }
    }

    var conflicts: [GitChange] {
        changes.filter(\.isConflicted)
    }
}

nonisolated enum GitDiffScope: Hashable, Sendable {
    case workingTree
    case staged
    case commit(String)
    case between(base: String, head: String)
}

nonisolated struct GitDiffRequest: Hashable, Sendable {
    let path: String
    let scope: GitDiffScope

    init(path: String, scope: GitDiffScope = .workingTree) {
        self.path = path
        self.scope = scope
    }
}

nonisolated enum GitDiffLineKind: String, Hashable, Sendable {
    case context
    case addition
    case deletion
}

nonisolated struct GitDiffLine: Identifiable, Hashable, Sendable {
    let number: Int
    let content: String
    let kind: GitDiffLineKind

    var id: String { "\(kind.rawValue):\(number):\(content)" }
}

nonisolated enum GitDiffRowKind: String, Hashable, Sendable {
    case context
    case addition
    case deletion
    case modification
}

nonisolated struct GitDiffRow: Identifiable, Hashable, Sendable {
    let id: Int
    let oldLine: GitDiffLine?
    let newLine: GitDiffLine?
    let kind: GitDiffRowKind
}

nonisolated struct GitDiffHunk: Identifiable, Hashable, Sendable {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    let rows: [GitDiffRow]
}

nonisolated struct GitFileDiff: Hashable, Sendable {
    let path: String
    let originalPath: String?
    let isBinary: Bool
    let hunks: [GitDiffHunk]
    let rawPatch: String

    var rows: [GitDiffRow] { hunks.flatMap(\.rows) }
    var isEmpty: Bool { !isBinary && hunks.isEmpty }
}

nonisolated struct GitCommitSummary: Identifiable, Hashable, Sendable {
    let id: String
    let parentIDs: [String]
    let authorName: String
    let authorEmail: String
    let authoredAt: Date
    let subject: String
    let decorations: [String]

    var shortID: String { String(id.prefix(8)) }
}

nonisolated struct GitHistoryPage: Hashable, Sendable {
    let commits: [GitCommitSummary]
    let offset: Int
    let requestedCount: Int

    var hasMore: Bool { commits.count == requestedCount }
}

nonisolated struct GitCommitFileChange: Identifiable, Hashable, Sendable {
    let path: String
    let originalPath: String?
    let kind: GitChangeKind

    var id: String { path }
}

nonisolated enum GitBranchKind: String, Hashable, Sendable {
    case local
    case remote
}

nonisolated struct GitBranch: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: GitBranchKind
    let objectID: String
    let upstream: String?
    let aheadCount: Int
    let behindCount: Int
    let isCurrent: Bool
}

nonisolated struct GitBranchSnapshot: Sendable {
    let currentBranch: String?
    let upstream: String?
    let aheadCount: Int
    let behindCount: Int
    let isDetached: Bool
    let isUnborn: Bool
    let branches: [GitBranch]

    var localBranches: [GitBranch] { branches.filter { $0.kind == .local } }
    var remoteBranches: [GitBranch] { branches.filter { $0.kind == .remote } }
}

nonisolated enum GitMergeStrategy: String, Hashable, Sendable {
    case defaultMerge
    case fastForwardOnly
    case noFastForward
}

nonisolated enum GitPullStrategy: String, Hashable, Sendable {
    case merge
    case rebase
    case fastForwardOnly
}

nonisolated struct GitFetchRequest: Hashable, Sendable {
    let remote: String?
    let prune: Bool

    init(remote: String? = nil, prune: Bool = true) {
        self.remote = remote
        self.prune = prune
    }
}

nonisolated struct GitPullRequest: Hashable, Sendable {
    let remote: String?
    let branch: String?
    let strategy: GitPullStrategy

    init(remote: String? = nil, branch: String? = nil, strategy: GitPullStrategy = .merge) {
        self.remote = remote
        self.branch = branch
        self.strategy = strategy
    }
}

nonisolated struct GitPushRequest: Hashable, Sendable {
    let remote: String?
    let branch: String?
    let setUpstream: Bool

    init(remote: String? = nil, branch: String? = nil, setUpstream: Bool = false) {
        self.remote = remote
        self.branch = branch
        self.setUpstream = setUpstream
    }
}

nonisolated struct GitOperationResult: Hashable, Sendable {
    let standardOutput: String
    let standardError: String
}

/// An in-progress merge (MERGE_HEAD exists). `headline` is the first content
/// line of MERGE_MSG ("Merge branch 'x' into y"); `defaultMessage` is the
/// full message with git's '#' comment lines stripped, suitable for
/// prefilling the commit box.
nonisolated struct GitMergeState: Equatable, Sendable {
    let headline: String
    let defaultMessage: String

    /// Strips '#' comment lines and surrounding blank space from a raw
    /// MERGE_MSG. Pure for testability.
    static func cleaned(message: String) -> String {
        message
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init?(rawMergeMessage: String?) {
        let cleaned = Self.cleaned(message: rawMergeMessage ?? "")
        defaultMessage = cleaned.isEmpty ? "Merge" : cleaned
        headline =
            cleaned.split(separator: "\n").first.map(String.init) ?? "Merge in progress"
    }
}
