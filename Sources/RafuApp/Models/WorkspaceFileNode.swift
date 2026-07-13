import Foundation

nonisolated struct WorkspaceFileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    let isDirectory: Bool
    let children: [WorkspaceFileNode]?

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var iconName: String { FileTypePresentation.symbol(for: url, isDirectory: isDirectory) }
}

nonisolated enum FileTypePresentation {
    static func symbol(for url: URL, isDirectory: Bool) -> String {
        FileIconProvider.icon(for: url, isDirectory: isDirectory).symbol
    }
}
