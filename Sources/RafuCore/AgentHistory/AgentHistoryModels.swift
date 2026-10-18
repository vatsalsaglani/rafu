import Foundation

// Read-only Agent History (round-2 X12). These value types describe the chat
// transcripts that Claude Code and Codex already keep on this Mac. Rafu only
// reads those files; it never writes, moves, uploads, or logs them.

/// The agent CLIs whose local transcripts Rafu can read.
public enum AgentHistoryProvider: String, CaseIterable, Codable, Hashable, Sendable {
    case claudeCode
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// One session's identity: the provider plus the provider's own session id.
public struct AgentHistorySessionKey: Hashable, Codable, Sendable {
    public let provider: AgentHistoryProvider
    public let sessionID: String

    public init(provider: AgentHistoryProvider, sessionID: String) {
        self.provider = provider
        self.sessionID = sessionID
    }
}

/// The cheap per-file summary built from the head and tail of a transcript.
/// It never holds message bodies beyond the bounded, single-line title.
public struct AgentHistorySessionSummary: Identifiable, Equatable, Sendable {
    public let key: AgentHistorySessionKey
    /// A single-line label: the provider's own title when it has one, else
    /// the first real user prompt, else "Untitled Session".
    public let title: String
    /// The working directory the session ran in (`cwd`). `nil` when the
    /// sampled part of the file did not record one.
    public let projectPath: String?
    /// A lossy label for a Claude Code project folder, used only when no
    /// `cwd` was found. Never used as a path.
    public let fallbackProjectLabel: String?
    public let startedAt: Date?
    public let updatedAt: Date?
    public let gitBranch: String?
    /// Exact for small files; an extrapolation for large ones (see
    /// `isMessageCountEstimated`).
    public let messageCount: Int
    public let isMessageCountEstimated: Bool
    public let fileURL: URL
    public let fileSize: Int64
    public let modificationDate: Date
    public let cliVersion: String?

    public var id: AgentHistorySessionKey { key }
    public var provider: AgentHistoryProvider { key.provider }
    /// The date lists sort and display by.
    public var activityDate: Date { updatedAt ?? modificationDate }

    public init(
        key: AgentHistorySessionKey,
        title: String,
        projectPath: String?,
        fallbackProjectLabel: String? = nil,
        startedAt: Date?,
        updatedAt: Date?,
        gitBranch: String?,
        messageCount: Int,
        isMessageCountEstimated: Bool,
        fileURL: URL,
        fileSize: Int64,
        modificationDate: Date,
        cliVersion: String? = nil
    ) {
        self.key = key
        self.title = title
        self.projectPath = projectPath
        self.fallbackProjectLabel = fallbackProjectLabel
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.gitBranch = gitBranch
        self.messageCount = messageCount
        self.isMessageCountEstimated = isMessageCountEstimated
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.modificationDate = modificationDate
        self.cliVersion = cliVersion
    }

    /// The same summary with a different title (Codex thread names arrive
    /// from a separate index file).
    public func withTitle(_ newTitle: String) -> AgentHistorySessionSummary {
        AgentHistorySessionSummary(
            key: key, title: newTitle, projectPath: projectPath,
            fallbackProjectLabel: fallbackProjectLabel, startedAt: startedAt,
            updatedAt: updatedAt, gitBranch: gitBranch, messageCount: messageCount,
            isMessageCountEstimated: isMessageCountEstimated, fileURL: fileURL,
            fileSize: fileSize, modificationDate: modificationDate, cliVersion: cliVersion)
    }
}

/// Sessions that ran in one folder.
public struct AgentHistoryProject: Identifiable, Equatable, Sendable {
    /// The normalized path, or a synthetic id when the path is unknown.
    public let id: String
    /// The real folder path, or `nil` when no session recorded one.
    public let path: String?
    public let displayName: String
    /// Newest first.
    public let sessions: [AgentHistorySessionSummary]

    public var latestActivity: Date? { sessions.first?.activityDate }

    public init(
        id: String, path: String?, displayName: String, sessions: [AgentHistorySessionSummary]
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.sessions = sessions
    }
}

public enum AgentHistoryProviderFilter: String, CaseIterable, Hashable, Sendable {
    case all
    case claudeCode
    case codex

    public var title: String {
        switch self {
        case .all: "All"
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    public func includes(_ provider: AgentHistoryProvider) -> Bool {
        switch self {
        case .all: true
        case .claudeCode: provider == .claudeCode
        case .codex: provider == .codex
        }
    }
}

/// All known sessions, grouped by project. Pure and cheap to rebuild.
public struct AgentHistoryIndex: Equatable, Sendable {
    /// Newest first.
    public let sessions: [AgentHistorySessionSummary]
    /// Newest activity first.
    public let projects: [AgentHistoryProject]

    public static let empty = AgentHistoryIndex(sessions: [])

    public init(sessions: [AgentHistorySessionSummary]) {
        let sorted = sessions.sorted(by: Self.newestFirst)
        self.sessions = sorted
        var order: [String] = []
        var grouped: [String: [AgentHistorySessionSummary]] = [:]
        var paths: [String: String] = [:]
        var labels: [String: String] = [:]
        for session in sorted {
            let id: String
            if let path = session.projectPath.map(AgentHistoryPath.normalized), !path.isEmpty {
                id = path
                paths[id] = path
                labels[id] = AgentHistoryPath.displayName(of: path)
            } else if let label = session.fallbackProjectLabel, !label.isEmpty {
                id = "label:" + label
                labels[id] = label
            } else {
                id = "unknown"
                labels[id] = "Unknown Folder"
            }
            if grouped[id] == nil { order.append(id) }
            grouped[id, default: []].append(session)
        }
        self.projects = order.map { id in
            AgentHistoryProject(
                id: id, path: paths[id], displayName: labels[id] ?? id,
                sessions: grouped[id] ?? [])
        }
    }

    public func session(for key: AgentHistorySessionKey) -> AgentHistorySessionSummary? {
        sessions.first { $0.key == key }
    }

    /// Keeps sessions of the chosen provider whose title, folder, or branch
    /// contains `query` (case- and diacritic-insensitive), plus every session
    /// in `messageMatches` (the result of an explicit message-text search).
    public func filtered(
        provider: AgentHistoryProviderFilter,
        query: String,
        messageMatches: Set<AgentHistorySessionKey> = []
    ) -> AgentHistoryIndex {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let kept = sessions.filter { session in
            guard provider.includes(session.provider) else { return false }
            if needle.isEmpty || messageMatches.contains(session.key) { return true }
            return Self.matches(session, needle: needle)
        }
        return AgentHistoryIndex(sessions: kept)
    }

    /// Splits projects into those inside one of `workspaceRoots` and the rest.
    /// Both keep newest-first order.
    public func partition(workspaceRoots: [String]) -> (
        workspace: [AgentHistoryProject], others: [AgentHistoryProject]
    ) {
        let roots = workspaceRoots.map(AgentHistoryPath.normalized).filter { !$0.isEmpty }
        var workspace: [AgentHistoryProject] = []
        var others: [AgentHistoryProject] = []
        for project in projects {
            if let path = project.path,
                roots.contains(where: { AgentHistoryPath.isPath(path, inside: $0) })
            {
                workspace.append(project)
            } else {
                others.append(project)
            }
        }
        return (workspace, others)
    }

    private static func matches(_ session: AgentHistorySessionSummary, needle: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if session.title.range(of: needle, options: options) != nil { return true }
        if let path = session.projectPath, path.range(of: needle, options: options) != nil {
            return true
        }
        if let branch = session.gitBranch, branch.range(of: needle, options: options) != nil {
            return true
        }
        return session.key.sessionID.range(of: needle, options: options) != nil
    }

    private static func newestFirst(
        _ lhs: AgentHistorySessionSummary, _ rhs: AgentHistorySessionSummary
    ) -> Bool {
        if lhs.activityDate != rhs.activityDate { return lhs.activityDate > rhs.activityDate }
        return lhs.fileURL.path < rhs.fileURL.path
    }
}

/// Path helpers that work on plain strings, so a remote-looking or missing
/// folder is never resolved against the local disk by accident.
public enum AgentHistoryPath {
    /// Removes trailing slashes (except for "/") and `.`/`..` segments.
    public static func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return trimmed }
        var parts: [Substring] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    public static func isPath(_ path: String, inside root: String) -> Bool {
        let path = normalized(path)
        let root = normalized(root)
        guard !root.isEmpty, !path.isEmpty else { return false }
        if path == root || root == "/" { return true }
        return path.hasPrefix(root + "/")
    }

    public static func displayName(of path: String) -> String {
        let normalized = normalized(path)
        let last = normalized.split(separator: "/").last.map(String.init) ?? normalized
        return last.isEmpty ? normalized : last
    }

    /// `~/x` for paths under `home`, else the path itself.
    public static func abbreviated(_ path: String, home: String) -> String {
        let home = normalized(home)
        let path = normalized(path)
        guard home.count > 1 else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
