import Foundation

/// Finds transcript files and keeps their summaries in memory, keyed by path
/// and validated by (modification date, size). A rescan re-reads only new or
/// changed files. All work runs on this actor, never on the main actor, and
/// stops at the caller's cancellation.
public actor AgentHistoryScanner {
    public struct Options: Equatable, Sendable {
        public var locations: AgentHistoryLocations
        public var includesClaudeCode: Bool
        public var includesCodex: Bool
        /// The newest files kept per provider.
        public var maximumFilesPerProvider: Int

        public init(
            locations: AgentHistoryLocations, includesClaudeCode: Bool = true,
            includesCodex: Bool = true, maximumFilesPerProvider: Int = 5_000
        ) {
            self.locations = locations
            self.includesClaudeCode = includesClaudeCode
            self.includesCodex = includesCodex
            self.maximumFilesPerProvider = maximumFilesPerProvider
        }
    }

    public struct ScanResult: Equatable, Sendable {
        public let index: AgentHistoryIndex
        /// Files whose cached summary was reused.
        public let reusedFileCount: Int
        /// Files read in this scan.
        public let parsedFileCount: Int
    }

    struct FileStamp: Equatable, Sendable {
        let modificationDate: Date
        let size: Int64
    }

    private struct CacheEntry {
        let stamp: FileStamp
        let summary: AgentHistorySessionSummary?
    }

    private struct DiscoveredFile {
        let url: URL
        let stamp: FileStamp
    }

    private var cache: [String: CacheEntry] = [:]
    private var codexTitles: (stamp: FileStamp, titles: [String: String])?

    public init() {}

    public func scan(_ options: Options) throws -> ScanResult {
        var summaries: [AgentHistorySessionSummary] = []
        var seen: Set<String> = []
        var reused = 0
        var parsed = 0
        let providers: [(AgentHistoryProvider, Bool)] = [
            (.claudeCode, options.includesClaudeCode), (.codex, options.includesCodex),
        ]
        for (provider, isIncluded) in providers where isIncluded {
            let files = try discover(provider, options: options)
            for file in files {
                try Task.checkCancellation()
                seen.insert(file.url.path)
                let summary: AgentHistorySessionSummary?
                if let cached = cache[file.url.path], cached.stamp == file.stamp {
                    summary = cached.summary
                    reused += 1
                } else {
                    summary = Self.summarize(file, provider: provider)
                    cache[file.url.path] = CacheEntry(stamp: file.stamp, summary: summary)
                    parsed += 1
                }
                if let summary { summaries.append(summary) }
            }
        }
        cache = cache.filter { seen.contains($0.key) }
        if options.includesCodex {
            let titles = try loadCodexTitles(options.locations.codexSessionIndexFile)
            if !titles.isEmpty {
                summaries = summaries.map { summary in
                    guard summary.provider == .codex,
                        let title = titles[summary.key.sessionID]
                    else { return summary }
                    return summary.withTitle(title)
                }
            }
        }
        return ScanResult(
            index: AgentHistoryIndex(sessions: Self.uniqued(summaries)),
            reusedFileCount: reused, parsedFileCount: parsed)
    }

    /// Drops every cached summary (for example when a folder setting changes).
    public func reset() {
        cache = [:]
        codexTitles = nil
    }

    // MARK: Discovery

    private func discover(_ provider: AgentHistoryProvider, options: Options) throws
        -> [DiscoveredFile]
    {
        let files: [DiscoveredFile]
        switch provider {
        case .claudeCode:
            files = try Self.claudeFiles(in: options.locations.claudeProjectsDirectory)
        case .codex:
            files = try Self.codexFiles(in: options.locations.codexSessionsDirectory)
        }
        guard files.count > options.maximumFilesPerProvider else { return files }
        return Array(
            files.sorted { $0.stamp.modificationDate > $1.stamp.modificationDate }
                .prefix(options.maximumFilesPerProvider))
    }

    private static let fileKeys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey,
        .contentModificationDateKey,
    ]

    /// `projects/<folder>/<id>.jsonl`, one level deep. Subagent transcripts
    /// in deeper folders belong to their parent session and are skipped.
    private static func claudeFiles(in projects: URL) throws -> [DiscoveredFile] {
        let manager = FileManager.default
        guard
            let folders = try? manager.contentsOfDirectory(
                at: projects, includingPropertiesForKeys: fileKeys, options: [.skipsHiddenFiles])
        else { return [] }
        var result: [DiscoveredFile] = []
        for folder in folders {
            try Task.checkCancellation()
            guard let values = try? folder.resourceValues(forKeys: Set(fileKeys)),
                values.isDirectory == true, values.isSymbolicLink != true,
                let entries = try? manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: fileKeys,
                    options: [.skipsHiddenFiles])
            else { continue }
            for entry in entries where entry.pathExtension == "jsonl" {
                if let file = discovered(entry) { result.append(file) }
            }
        }
        return result
    }

    /// `sessions/YYYY/MM/DD/rollout-*.jsonl`.
    private static func codexFiles(in sessions: URL) throws -> [DiscoveredFile] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: sessions, includingPropertiesForKeys: fileKeys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var result: [DiscoveredFile] = []
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            let name = url.lastPathComponent
            guard name.hasPrefix("rollout-"), url.pathExtension == "jsonl" else { continue }
            if let file = discovered(url) { result.append(file) }
        }
        return result
    }

    private static func discovered(_ url: URL) -> DiscoveredFile? {
        guard let values = try? url.resourceValues(forKeys: Set(fileKeys)),
            values.isRegularFile == true, values.isSymbolicLink != true
        else { return nil }
        let stamp = FileStamp(
            modificationDate: values.contentModificationDate ?? .distantPast,
            size: Int64(values.fileSize ?? 0))
        return DiscoveredFile(url: url.standardizedFileURL, stamp: stamp)
    }

    // MARK: Parsing

    private static func summarize(_ file: DiscoveredFile, provider: AgentHistoryProvider)
        -> AgentHistorySessionSummary?
    {
        guard file.stamp.size > 0 else { return nil }
        switch provider {
        case .claudeCode:
            return try? ClaudeCodeHistoryParser.summary(
                fileURL: file.url, size: file.stamp.size,
                modificationDate: file.stamp.modificationDate)
        case .codex:
            return try? CodexHistoryParser.summary(
                fileURL: file.url, size: file.stamp.size,
                modificationDate: file.stamp.modificationDate)
        }
    }

    private func loadCodexTitles(_ index: URL) throws -> [String: String] {
        guard let file = Self.discovered(index) else {
            codexTitles = nil
            return [:]
        }
        if let codexTitles, codexTitles.stamp == file.stamp { return codexTitles.titles }
        try Task.checkCancellation()
        let titles = (try? CodexSessionIndex.load(index: index)) ?? [:]
        codexTitles = (file.stamp, titles)
        return titles
    }

    /// One row per session key. A resumed Codex thread can write a second
    /// rollout with the same id; the newest file wins.
    private static func uniqued(_ summaries: [AgentHistorySessionSummary])
        -> [AgentHistorySessionSummary]
    {
        var newest: [AgentHistorySessionKey: AgentHistorySessionSummary] = [:]
        for summary in summaries {
            if let existing = newest[summary.key],
                existing.modificationDate >= summary.modificationDate
            {
                continue
            }
            newest[summary.key] = summary
        }
        return Array(newest.values)
    }
}

/// The on-demand message-text search. It opens each transcript with the
/// smaller `AgentTranscriptLimits.search` bounds and checks prompts and
/// replies only (not tool output or reasoning).
public enum AgentHistoryMessageSearch {
    @concurrent
    public static func sessions(
        matching query: String, in sessions: [AgentHistorySessionSummary],
        limits: AgentTranscriptLimits = .search
    ) async throws -> Set<AgentHistorySessionKey> {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        var matches: Set<AgentHistorySessionKey> = []
        for session in sessions {
            try Task.checkCancellation()
            guard
                let transcript = try? AgentTranscriptLoader.load(
                    fileURL: session.fileURL, key: session.key, limits: limits)
            else { continue }
            if transcript.conversationContains(needle) { matches.insert(session.key) }
        }
        return matches
    }
}
