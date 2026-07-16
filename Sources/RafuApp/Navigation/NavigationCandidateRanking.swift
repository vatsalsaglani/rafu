import Foundation

/// Pure ranking rules shared by every navigation tier provider that can
/// return more than one candidate for a symbol name: the request's own file
/// first, then files in the same directory (proximity), then lexicographic
/// by path and byte offset. Extracted from `SyntacticNavigationProvider.rank`
/// so `TextSearchNavigationProvider`'s raw, unranked search-order candidates
/// can be ordered identically without duplicating the tie-break logic.
nonisolated enum NavigationCandidateRanking {
    /// Whether `lhs` should sort before `rhs`: same-file first, then
    /// same-directory, then relative path, then offset.
    /// `requestRelativePath` is the requesting document's own
    /// workspace-relative path.
    static func isOrderedBefore(
        lhsRelativePath: String,
        lhsOffset: Int,
        rhsRelativePath: String,
        rhsOffset: Int,
        requestRelativePath: String
    ) -> Bool {
        let requestDirectory = (requestRelativePath as NSString).deletingLastPathComponent

        let lhsSameFile = lhsRelativePath == requestRelativePath
        let rhsSameFile = rhsRelativePath == requestRelativePath
        if lhsSameFile != rhsSameFile { return lhsSameFile }

        let lhsSameDirectory =
            (lhsRelativePath as NSString).deletingLastPathComponent == requestDirectory
        let rhsSameDirectory =
            (rhsRelativePath as NSString).deletingLastPathComponent == requestDirectory
        if lhsSameDirectory != rhsSameDirectory { return lhsSameDirectory }

        if lhsRelativePath != rhsRelativePath { return lhsRelativePath < rhsRelativePath }
        return lhsOffset < rhsOffset
    }

    /// The workspace-relative path of `url` under `rootURL`, or `url`'s last
    /// path component when `url` isn't inside `rootURL` at all. Shared by
    /// every navigation provider that needs to key ranking off the
    /// request's own document location.
    static func relativePath(for url: URL, rootURL: URL) -> String {
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
    }
}
