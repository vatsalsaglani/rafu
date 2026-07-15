import Foundation

/// Syntactic rung of the `NavigationLadder`, above the text-search fallback:
/// answers "go to definition"/"go to declaration" from the
/// `WorkspaceSymbolIndex`'s tree-sitter-extracted declarations.
///
/// It deliberately DECLINES (`nil`) for `.references` and `.hover`: the index
/// stores declarations, not `@reference.*` occurrences, so find-references
/// falls through to the bounded text tier rather than returning a partial
/// answer the UI would mislabel as authoritative. It also declines when no
/// `symbolName` is supplied, so the text tier (which resolves the identifier
/// from the caret itself) can still try.
nonisolated struct SyntacticNavigationProvider: NavigationTierProvider {
    let tier: NavigationTier = .syntactic

    private let index: WorkspaceSymbolIndex
    private let rootURL: URL

    init(index: WorkspaceSymbolIndex, rootURL: URL) {
        self.index = index
        self.rootURL = rootURL
    }

    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        switch request.kind {
        case .references, .hover:
            return nil
        case .definition, .declaration:
            break
        }
        guard
            let symbolName = request.symbolName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !symbolName.isEmpty
        else { return nil }

        try Task.checkCancellation()

        if await index.currentState == .building {
            return NavigationAnswer(tier: .syntactic, candidates: [], state: .indexing)
        }

        let requestRelativePath = Self.relativePath(for: request.documentURL, rootURL: rootURL)
        let matches = try await index.lookup(name: symbolName)
        let ranked = Self.rank(matches, requestRelativePath: requestRelativePath)
        let candidates = ranked.map { match in
            SymbolCandidate(
                relativePath: match.relativePath,
                range: match.range,
                name: match.name,
                kindLabel: match.kind,
                previewLine: Self.previewLine(rootURL: rootURL, match: match)
            )
        }
        // A non-`nil` answer with empty candidates is authoritative: the index
        // is ready and simply has no declaration by that name.
        return NavigationAnswer(tier: .syntactic, candidates: candidates, state: .ready)
    }

    /// Ranks exact-name matches: the request's own file first, then files in
    /// the same directory (proximity), then lexicographic by path and offset.
    static func rank(
        _ matches: [WorkspaceSymbolMatch],
        requestRelativePath: String
    ) -> [WorkspaceSymbolMatch] {
        let requestDirectory = (requestRelativePath as NSString).deletingLastPathComponent
        return matches.sorted { lhs, rhs in
            let lhsSameFile = lhs.relativePath == requestRelativePath
            let rhsSameFile = rhs.relativePath == requestRelativePath
            if lhsSameFile != rhsSameFile { return lhsSameFile }

            let lhsSameDirectory =
                (lhs.relativePath as NSString).deletingLastPathComponent == requestDirectory
            let rhsSameDirectory =
                (rhs.relativePath as NSString).deletingLastPathComponent == requestDirectory
            if lhsSameDirectory != rhsSameDirectory { return lhsSameDirectory }

            if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
            return lhs.range.location < rhs.range.location
        }
    }

    /// The trimmed source line containing `match`, read lazily so the index
    /// never stores 500k preview lines. Falls back to the symbol name if the
    /// file cannot be read or the range no longer fits.
    private static func previewLine(rootURL: URL, match: WorkspaceSymbolMatch) -> String {
        let fileURL = rootURL.appending(path: match.relativePath)
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]),
            let text = String(data: data, encoding: .utf8)
        else { return match.name }
        let nsText = text as NSString
        guard match.range.location != NSNotFound, NSMaxRange(match.range) <= nsText.length else {
            return match.name
        }
        let lineRange = nsText.lineRange(
            for: NSRange(location: match.range.location, length: 0))
        return nsText.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func relativePath(for url: URL, rootURL: URL) -> String {
        let filePath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        guard filePath == rootPath || filePath.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(filePath.dropFirst(rootPath.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
    }
}
