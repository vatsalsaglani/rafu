import Foundation

nonisolated struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var iconName: String { FileTypePresentation.symbol(for: url, isDirectory: isDirectory) }
}

/// Chooses the already materialized directory levels that one FSEvents batch
/// must re-list. An event may name a directory whose own child list changed;
/// the classifier records that directory's parent. In that case, include the
/// materialized direct child too. Paths not materialized by an earlier sidebar
/// expansion never enter this scope, preserving lazy tree loading.
nonisolated enum WorkspaceFileTreeRefreshScope {
    static func materializedDirectories(
        affectedBy changedDirectoryRelativePaths: Set<String>,
        among materializedDirectoryPaths: Set<String>
    ) -> Set<String> {
        let changedMaterializedDirectories = changedDirectoryRelativePaths.intersection(
            materializedDirectoryPaths)
        let materializedDirectChildren = materializedDirectoryPaths.filter { path in
            guard !path.isEmpty else { return false }
            return changedDirectoryRelativePaths.contains(parentDirectoryPath(of: path))
        }
        return changedMaterializedDirectories.union(materializedDirectChildren)
    }

    private static func parentDirectoryPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

nonisolated enum FileTypePresentation {
    static func symbol(for url: URL, isDirectory: Bool) -> String {
        FileIconProvider.icon(for: url, isDirectory: isDirectory).symbol
    }
}
