import Foundation

/// One open document's inputs to the hibernation decision. A pure value type
/// so `DocumentHibernationPolicy` can be exercised without a live
/// `EditorDocument`, its text storage, or the main actor.
nonisolated struct DocumentHibernationInput: Equatable, Sendable {
    let id: UUID
    let isVisible: Bool
    let isDirty: Bool
    let accessSequence: Int
}

/// Pure, nonisolated policy for Increment 4's bounded editor working set. It
/// decides which open documents keep their editor mounted (so TextKit keeps
/// owning their live text — never cached in the model) and which are released
/// back to a hibernated, reload-from-disk state.
///
/// The data-safety invariant this policy enforces: a dirty document is NEVER
/// hibernated. Its unsaved edits live only in the mounted `NSTextStorage`, so
/// releasing its editor would lose them. Visible documents are likewise never
/// hibernated. Everything else beyond the newest-N by access order (or all of
/// it, under memory pressure) is eligible.
nonisolated enum DocumentHibernationPolicy {
    /// Newest-access documents kept mounted beyond the visible/dirty set, so
    /// recently used tabs remount without a disk read. Bounds the editor
    /// working set independent of how many tabs are open.
    static let keepLoadedLimit = 8

    /// Returns the ids to HIBERNATE. Kept-loaded = visible ∪ dirty ∪ (newest
    /// `keepLoadedLimit` by `accessSequence` across all documents). The
    /// returned set is `allDocuments − keptLoaded`, further intersected with
    /// (non-visible ∩ non-dirty) as a belt-and-braces guard so a visible or
    /// dirty document can never appear in the result. Under memory pressure
    /// the newest-N grace is dropped: every non-visible, non-dirty document
    /// hibernates.
    static func hibernating(
        documents: [DocumentHibernationInput],
        keepLoadedLimit: Int = keepLoadedLimit,
        underMemoryPressure: Bool = false
    ) -> Set<UUID> {
        var keptLoaded = Set<UUID>()
        for document in documents where document.isVisible || document.isDirty {
            keptLoaded.insert(document.id)
        }

        if !underMemoryPressure, keepLoadedLimit > 0 {
            let newest =
                documents
                .sorted { $0.accessSequence > $1.accessSequence }
                .prefix(keepLoadedLimit)
            for document in newest {
                keptLoaded.insert(document.id)
            }
        }

        var hibernating = Set<UUID>()
        for document in documents
        where !document.isVisible
            && !document.isDirty
            && !keptLoaded.contains(document.id)
        {
            hibernating.insert(document.id)
        }
        return hibernating
    }
}
