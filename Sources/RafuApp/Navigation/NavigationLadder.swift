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

    /// The bounded total-match cap this tier's search runs under. Exposed so
    /// `NavigationPeekView` can disclose truncation: a candidate count that
    /// exactly equals this cap means the underlying search may have more
    /// matches than were returned. This is a heuristic, not an exact signal —
    /// `NavigationAnswer` carries no truncation flag, so a genuinely
    /// exactly-200-match symbol also shows the footer, and per-file
    /// truncation below a 200 total isn't disclosed at all.
    static let referencesResultCap = limits.maximumTotalMatches

    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer? {
        // A whole-word text search can locate definitions/declarations/
        // references, but it cannot produce a `.hover` docstring/signature.
        // Hover is deliberately LSP-only: declining here keeps the ladder from
        // surfacing a raw source line as if it were hover documentation, so a
        // language with no live server yields no tooltip at all.
        guard request.kind != .hover else { return nil }
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
        let requestRelativePath = NavigationCandidateRanking.relativePath(
            for: request.documentURL, rootURL: rootURL)
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
        }.sorted { lhs, rhs in
            NavigationCandidateRanking.isOrderedBefore(
                lhsRelativePath: lhs.relativePath,
                lhsOffset: lhs.range.location,
                rhsRelativePath: rhs.relativePath,
                rhsOffset: rhs.range.location,
                requestRelativePath: requestRelativePath
            )
        }
        return NavigationAnswer(tier: .text, candidates: candidates, state: .ready)
    }
}
