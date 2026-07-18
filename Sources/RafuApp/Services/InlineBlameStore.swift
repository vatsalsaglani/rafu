import Foundation

/// Identifies the exact (file, HEAD, buffer revision) combination a cached
/// `GitBlame` answers for. Any field changing — a new HEAD, a different
/// file, or an edited-then-saved buffer bumping `revision` — invalidates the
/// cached entry via a simple key mismatch.
nonisolated struct InlineBlameCacheKey: Hashable, Sendable {
    let path: String
    let headOID: String?
    let revision: Int
}

/// Single-entry cache for `WorkspaceSession.inlineBlame(for:)`. Inline blame
/// only ever needs the ACTIVE file's data, so this retains exactly one
/// `(key, blame)` pair rather than growing an unbounded per-file cache — a
/// cache miss (a different key) always evicts the previous entry. A pure
/// value type; the `@MainActor` caller owns all mutation and honestly
/// conforms to `Sendable`.
nonisolated struct InlineBlameStore: Sendable {
    private var key: InlineBlameCacheKey?
    private var blame: GitBlame?

    init() {}

    /// Returns the cached blame only when `key` matches the retained entry;
    /// `nil` on any mismatch (including an empty store).
    func blame(for key: InlineBlameCacheKey) -> GitBlame? {
        guard self.key == key else { return nil }
        return blame
    }

    /// Stores `blame` for `key`, evicting whatever entry (if any) was
    /// previously retained.
    mutating func store(_ blame: GitBlame, for key: InlineBlameCacheKey) {
        self.key = key
        self.blame = blame
    }

    /// Explicitly clears the retained entry. Called when inline blame is
    /// toggled off and when the Git workbench state resets (workspace
    /// switch), so a stale answer can never leak into a next session even if
    /// a future key were to coincidentally collide.
    mutating func invalidate() {
        key = nil
        blame = nil
    }
}
