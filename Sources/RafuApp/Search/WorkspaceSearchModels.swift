import Foundation

nonisolated struct WorkspaceSearchLimits: Codable, Equatable, Sendable {
    var maximumFileBytes: Int
    var maximumFiles: Int
    var maximumMatchesPerFile: Int
    var maximumTotalMatches: Int
    var maximumPreviewCharacters: Int

    static let standard = Self(
        maximumFileBytes: 2 * 1_024 * 1_024,
        maximumFiles: 20_000,
        maximumMatchesPerFile: 500,
        maximumTotalMatches: 5_000,
        maximumPreviewCharacters: 240
    )
}

nonisolated struct WorkspaceSearchRequest: Equatable, Sendable {
    var rootURL: URL
    var query: String
    var options: TextSearchOptions
    var limits: WorkspaceSearchLimits
    var ignoredPathComponents: Set<String>
    var ignoredRelativePathPrefixes: Set<String>
    /// Raw glob patterns; compiled once per scan. Includes apply only to
    /// regular files, excludes apply to files and whole directories.
    var includeGlobs: [String]
    var excludeGlobs: [String]

    init(
        rootURL: URL,
        query: String,
        options: TextSearchOptions = [],
        limits: WorkspaceSearchLimits = .standard,
        ignoredPathComponents: Set<String> = WorkspaceSearchRequest.defaultIgnoredComponents,
        ignoredRelativePathPrefixes: Set<String> = [],
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.rootURL = rootURL
        self.query = query
        self.options = options
        self.limits = limits
        self.ignoredPathComponents = ignoredPathComponents
        self.ignoredRelativePathPrefixes = ignoredRelativePathPrefixes
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }

    static let defaultIgnoredComponents: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "Pods", "dist", "node_modules",
    ]
}

nonisolated struct WorkspaceFileVersion: Codable, Equatable, Sendable {
    let byteCount: Int
    let modificationDate: Date?
    let contentFingerprint: UInt64
}

nonisolated struct WorkspaceSearchMatch: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let range: NSRange
    let line: Int
    let column: Int
    let preview: String

    init(
        id: UUID = UUID(),
        range: NSRange,
        line: Int,
        column: Int,
        preview: String
    ) {
        self.id = id
        self.range = range
        self.line = line
        self.column = column
        self.preview = preview
    }
}

nonisolated struct WorkspaceSearchFileGroup: Codable, Equatable, Identifiable, Sendable {
    var id: URL { fileURL }

    let fileURL: URL
    let relativePath: String
    let version: WorkspaceFileVersion
    let matches: [WorkspaceSearchMatch]
    let isTruncated: Bool
}

nonisolated struct WorkspaceSearchStatistics: Codable, Equatable, Sendable {
    var visitedFiles = 0
    var searchedFiles = 0
    var skippedBinaryFiles = 0
    var skippedLargeFiles = 0
    var skippedUnreadableFiles = 0
    var skippedSymlinks = 0
    var skippedIgnoredItems = 0
}

nonisolated struct WorkspaceSearchResult: Codable, Equatable, Sendable {
    let groups: [WorkspaceSearchFileGroup]
    let totalMatchCount: Int
    let isTruncated: Bool
    let statistics: WorkspaceSearchStatistics
}

nonisolated struct WorkspaceReplacementEdit: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let range: NSRange
    let original: String
    let replacement: String
    let line: Int
    let originalPreview: String
    let replacementPreview: String

    init(
        id: UUID = UUID(),
        range: NSRange,
        original: String,
        replacement: String,
        line: Int,
        originalPreview: String,
        replacementPreview: String
    ) {
        self.id = id
        self.range = range
        self.original = original
        self.replacement = replacement
        self.line = line
        self.originalPreview = originalPreview
        self.replacementPreview = replacementPreview
    }
}

nonisolated struct WorkspaceReplacementFilePreview: Codable, Equatable, Identifiable, Sendable {
    var id: URL { fileURL }

    let fileURL: URL
    let relativePath: String
    let expectedVersion: WorkspaceFileVersion
    let edits: [WorkspaceReplacementEdit]
}

nonisolated struct WorkspaceReplacementPreview: Codable, Equatable, Sendable {
    let files: [WorkspaceReplacementFilePreview]
    let replacementCount: Int
    let isTruncated: Bool
}

nonisolated struct WorkspaceReplacementReport: Codable, Equatable, Sendable {
    let changedFiles: [URL]
    let replacementCount: Int
}

nonisolated enum WorkspaceSearchError: LocalizedError, Equatable {
    case invalidRoot
    case replacementConflict(relativePath: String)
    case unreadableText(relativePath: String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot: "Choose a readable workspace directory before searching."
        case .replacementConflict(let relativePath):
            "\(relativePath) changed after the replacement preview. Review the search again."
        case .unreadableText(let relativePath):
            "\(relativePath) is no longer readable UTF-8 text."
        }
    }
}
