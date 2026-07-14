import Foundation

/// Orders a fixed set of `NavigationTierProvider`s from most to least
/// precise and resolves a `NavigationRequest` against them in order, taking
/// the first non-`nil` answer.
nonisolated struct NavigationLadder: Sendable {
    let providers: [any NavigationTierProvider]

    /// Resolves `request` against `providers` in order. Checks cancellation
    /// before invoking each provider so a superseded request never pays for
    /// a slow lower-priority lookup (or, symmetrically, a request that a
    /// fast tier already answered never blocks on a slow one). Returns `nil`
    /// only when every provider declines.
    func resolve(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        for provider in providers {
            try Task.checkCancellation()
            if let answer = try await provider.answer(request) {
                return answer
            }
        }
        return nil
    }
}

/// Default lowest tier of the ladder: wraps the existing bounded workspace
/// text search so "go to definition" and friends always have some answer,
/// even for a language with neither an LSP nor a syntactic index yet.
/// Deliberately bounded far tighter than the user-facing Search surface —
/// this tier exists to keep navigation usable, not to replace search.
nonisolated struct TextSearchNavigationProvider: NavigationTierProvider {
    let tier: NavigationTier = .text

    private let rootURL: URL
    private let searchService: WorkspaceSearchService

    init(rootURL: URL, searchService: WorkspaceSearchService = WorkspaceSearchService()) {
        self.rootURL = rootURL
        self.searchService = searchService
    }

    private static let limits = WorkspaceSearchLimits(
        maximumFileBytes: 2 * 1_024 * 1_024,
        maximumFiles: 20_000,
        maximumMatchesPerFile: 20,
        maximumTotalMatches: 200,
        maximumPreviewCharacters: 240
    )

    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        guard
            let symbolName = request.symbolName?.trimmingCharacters(in: .whitespacesAndNewlines),
            !symbolName.isEmpty
        else { return nil }

        let searchRequest = WorkspaceSearchRequest(
            rootURL: rootURL,
            query: symbolName,
            options: [.caseSensitive, .wholeWord],
            limits: Self.limits
        )
        let result = try await searchService.search(searchRequest)
        let candidates = result.groups.flatMap { group in
            group.matches.map { match in
                SymbolCandidate(
                    relativePath: group.relativePath,
                    range: match.range,
                    name: symbolName,
                    kindLabel: "text",
                    previewLine: match.preview
                )
            }
        }
        return NavigationAnswer(tier: .text, candidates: candidates, state: .ready)
    }
}
