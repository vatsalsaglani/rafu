import Foundation

/// A single rung on the `NavigationLadder`: one source of "go to
/// definition"/"find references"/etc. answers. Rungs are ordered from most
/// to least precise (an LSP tier above a syntactic-index tier above the
/// text-search fallback).
///
/// `answer(_:)` returning `nil` means "decline this request, fall through to
/// the next tier" — distinct from a non-`nil` answer with empty
/// `candidates`, which means "this tier is authoritative for this request
/// and found nothing." Implementations must be safe to call from any task
/// and must check `Task.checkCancellation()` (or otherwise honor
/// cancellation) before doing meaningful work, since a superseded request
/// (the caret moved again) cancels the enclosing task.
nonisolated protocol NavigationTierProvider: Sendable {
    /// This provider's identity on the ladder, surfaced to the UI via
    /// `NavigationTier.label`.
    var tier: NavigationTier { get }

    /// Answers `request`, or returns `nil` to decline and let the ladder try
    /// the next provider.
    func answer(_ request: NavigationRequest) async throws -> NavigationAnswer?
}
