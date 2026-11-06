import Foundation
import RafuCore

/// Formats file paths for Copy Relative Path (⇧⌘C) and Copy Absolute Path
/// (⌥⌘C). Shared by the Files context menu, the File menu commands, and the
/// tests. Pure, so it is safe off the main actor.
nonisolated enum PathCopier {
    enum Style: Sendable {
        case relative
        case absolute
    }

    /// One path. Relative is relative to the root that holds `url`; the root
    /// label is added in front only when the workspace has more than one
    /// root. A path outside every root falls back to the absolute path.
    static func path(for url: URL, style: Style, roots: [WorkspaceRoot]) -> String {
        let absolute = url.standardizedFileURL.path
        guard style == .relative,
            let found = WorkspaceRootList.locate(absolutePath: absolute, in: roots)
        else { return absolute }
        let display = WorkspaceRootList.displayPath(
            relativePath: found.relativePath, rootID: found.root.id, roots: roots)
        return display.isEmpty ? "." : display
    }

    /// Several paths, one per line, in the order given.
    static func paths(for urls: [URL], style: Style, roots: [WorkspaceRoot]) -> String {
        urls.map { path(for: $0, style: style, roots: roots) }.joined(separator: "\n")
    }

    /// What the copy commands act on: the selected file-backed document,
    /// else the Files selection, else nothing. While the Files tree has
    /// keyboard focus, its selection comes first.
    static func target(
        documentURL: URL?, documentIsUntitled: Bool, treePath: String?, treeHasFocus: Bool
    ) -> URL? {
        let tree = treePath.map { URL(filePath: $0) }
        let document = documentIsUntitled ? nil : documentURL
        if treeHasFocus, let tree { return tree }
        return document ?? tree
    }
}
