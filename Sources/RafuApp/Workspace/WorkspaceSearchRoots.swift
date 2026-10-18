import Foundation

/// One folder that workspace search covers.
nonisolated struct WorkspaceSearchRoot: Equatable, Sendable {
    let url: URL
    /// Prefixed to every result path (`lib/Sources/a.swift`) so results are
    /// labelled by root. `nil` in a one-folder workspace: paths stay as they
    /// were.
    let label: String?
}

/// Combines per-root search results into one result, in root order, so the
/// results list is grouped by root.
nonisolated enum WorkspaceSearchMerge {
    static func labelled(_ path: String, label: String?) -> String {
        guard let label else { return path }
        return label + "/" + path
    }

    static func labelled(_ result: WorkspaceSearchResult, label: String?) -> WorkspaceSearchResult {
        guard label != nil else { return result }
        return WorkspaceSearchResult(
            groups: result.groups.map { group in
                WorkspaceSearchFileGroup(
                    fileURL: group.fileURL,
                    relativePath: labelled(group.relativePath, label: label),
                    version: group.version,
                    matches: group.matches,
                    isTruncated: group.isTruncated)
            },
            totalMatchCount: result.totalMatchCount,
            isTruncated: result.isTruncated,
            statistics: result.statistics)
    }

    /// `isTruncated` is also set when some roots were not searched because
    /// the match limit was already reached.
    static func merge(
        _ results: [WorkspaceSearchResult], skippedRoots: Bool = false
    ) -> WorkspaceSearchResult {
        if results.count == 1, !skippedRoots, let only = results.first { return only }
        var statistics = WorkspaceSearchStatistics()
        for result in results {
            let part = result.statistics
            statistics.visitedFiles += part.visitedFiles
            statistics.searchedFiles += part.searchedFiles
            statistics.skippedBinaryFiles += part.skippedBinaryFiles
            statistics.skippedLargeFiles += part.skippedLargeFiles
            statistics.skippedUnreadableFiles += part.skippedUnreadableFiles
            statistics.skippedSymlinks += part.skippedSymlinks
            statistics.skippedIgnoredItems += part.skippedIgnoredItems
        }
        return WorkspaceSearchResult(
            groups: results.flatMap(\.groups),
            totalMatchCount: results.reduce(0) { $0 + $1.totalMatchCount },
            isTruncated: skippedRoots || results.contains(where: \.isTruncated),
            statistics: statistics)
    }

    static func labelled(
        _ preview: WorkspaceReplacementPreview, label: String?
    ) -> WorkspaceReplacementPreview {
        guard label != nil else { return preview }
        return WorkspaceReplacementPreview(
            files: preview.files.map { file in
                WorkspaceReplacementFilePreview(
                    fileURL: file.fileURL,
                    relativePath: labelled(file.relativePath, label: label),
                    expectedVersion: file.expectedVersion,
                    edits: file.edits)
            },
            replacementCount: preview.replacementCount,
            isTruncated: preview.isTruncated)
    }

    static func merge(
        _ previews: [WorkspaceReplacementPreview], skippedRoots: Bool = false
    ) -> WorkspaceReplacementPreview {
        if previews.count == 1, !skippedRoots, let only = previews.first { return only }
        return WorkspaceReplacementPreview(
            files: previews.flatMap(\.files),
            replacementCount: previews.reduce(0) { $0 + $1.replacementCount },
            isTruncated: skippedRoots || previews.contains(where: \.isTruncated))
    }
}
