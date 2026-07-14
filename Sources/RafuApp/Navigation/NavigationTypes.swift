import Foundation

/// The category of navigation a `NavigationRequest` is asking for.
nonisolated enum NavigationTargetKind: Sendable, Equatable, Hashable {
    case definition
    case declaration
    case references
    case hover
}

/// A caret-driven navigation request. `position` is a UTF-16 offset from the
/// start of the document, matching `NSRange`/`NSTextStorage` addressing
/// throughout the editor — never a line/column pair.
nonisolated struct NavigationRequest: Sendable, Equatable {
    let documentURL: URL
    /// UTF-16 offset from the start of the document.
    let position: Int
    let languageID: String
    let kind: NavigationTargetKind
    /// The identifier text under/near the caret, when known. Text-tier
    /// fallback (`TextSearchNavigationProvider`) requires this; LSP and
    /// syntactic tiers may resolve it themselves from `position`.
    let symbolName: String?

    init(
        documentURL: URL,
        position: Int,
        languageID: String,
        kind: NavigationTargetKind,
        symbolName: String? = nil
    ) {
        self.documentURL = documentURL
        self.position = position
        self.languageID = languageID
        self.kind = kind
        self.symbolName = symbolName
    }
}

/// One navigation result: a location a candidate list (`NavigationPeekView`,
/// increment 10) can jump to.
nonisolated struct SymbolCandidate: Sendable, Equatable, Identifiable {
    let id: UUID
    let relativePath: String
    let range: NSRange
    let name: String
    let kindLabel: String
    let previewLine: String

    init(
        id: UUID = UUID(),
        relativePath: String,
        range: NSRange,
        name: String,
        kindLabel: String,
        previewLine: String
    ) {
        self.id = id
        self.relativePath = relativePath
        self.range = range
        self.name = name
        self.kindLabel = kindLabel
        self.previewLine = previewLine
    }
}

/// Identifies which rung of the `NavigationLadder` produced an answer, most
/// to least precise.
nonisolated enum NavigationTier: Sendable, Equatable {
    case lsp(serverName: String)
    case syntactic
    case text

    /// UI-facing provenance label shown beside navigation results.
    var label: String {
        switch self {
        case .lsp(let serverName): "via \(serverName)"
        case .syntactic: "syntactic match"
        case .text: "text match"
        }
    }
}

/// A resolved (or in-progress) answer from one tier of the navigation
/// ladder.
nonisolated struct NavigationAnswer: Sendable, Equatable {
    /// Whether the answering tier is ready, still building its index, or
    /// unable to answer at all (distinct from `NavigationLadder.resolve`
    /// returning `nil`, which means every tier declined).
    nonisolated enum State: Sendable, Equatable {
        case ready
        case indexing
        case unavailable
    }

    let tier: NavigationTier
    let candidates: [SymbolCandidate]
    let state: State
}
