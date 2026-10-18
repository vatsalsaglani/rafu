import Foundation

/// Where a link clicked in a rendered note goes (review 7.8, "Links"). Workspace
/// paths open in Rafu, web and mail links open in the system handler, and
/// everything else is ignored: no `javascript:`, no files outside the workspace.
nonisolated enum CanvasNoteLink: Equatable, Sendable {
    case workspaceFile(String)
    case external(URL)
    case ignored

    static func classify(_ url: URL, root: URL?) -> CanvasNoteLink {
        switch url.scheme?.lowercased() {
        case "http", "https", "mailto":
            return .external(url)
        case "file":
            guard let root else { return .ignored }
            let path = url.standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard path.hasPrefix(prefix), path.count > prefix.count else { return .ignored }
            return .workspaceFile(String(path.dropFirst(prefix.count)))
        default:
            return .ignored
        }
    }

    /// A directory URL with a trailing slash, so relative references resolve
    /// inside it instead of replacing its last component.
    static func baseURL(for root: URL?) -> URL? {
        root.map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }
}
