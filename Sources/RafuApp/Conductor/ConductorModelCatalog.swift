import Foundation

/// What a model picker may offer, and what a stored string actually is.
///
/// `ConductorModelResolution` answers "which model will run"; this answers the
/// two questions that come *before* it — which choices to list, and whether a
/// given id is one Rafu knows. Settings → Agents had both rules inline; the
/// New Ensemble canvas needs the identical pair for the coordinator and for
/// each allowed CLI, so they live here once rather than being copied into a
/// second picker that could drift.
///
/// Both operations are pure. Neither probes, spawns, or reads defaults —
/// discovery is an explicit user action owned by whoever holds the adapter.
nonisolated enum ConductorModelCatalog {
    /// Curated first, then anything a discovery pass added, deduplicated by
    /// id. Order is deliberate: the shipped list is the stable, readable set,
    /// and discovery appends rather than reshuffles it.
    static func merge(
        curated: [ConductorModelChoice],
        discovered: [ConductorModelChoice]
    ) -> [ConductorModelChoice] {
        var seen = Set(curated.map(\.id))
        var result = curated
        for choice in discovered where seen.insert(choice.id).inserted {
            result.append(choice)
        }
        return result
    }

    /// Classifies `value` against `available`.
    ///
    /// A value the catalog never listed comes back as `.custom` rather than
    /// `nil`: the user may legitimately run a model Rafu has never heard of,
    /// so a hand-typed id must survive round-tripping through a picker. Rafu
    /// simply makes no claim that it exists — that is what `.custom` says.
    /// An empty or whitespace-only value is "not set" (the established
    /// `ConductorDefaultModelStore` convention) and resolves to `nil`.
    static func choice(
        for value: String?,
        in available: [ConductorModelChoice]
    ) -> ConductorModelChoice? {
        guard let trimmed = ConductorModelResolution.normalized(value) else { return nil }
        if let known = available.first(where: { $0.id == trimmed }) { return known }
        return ConductorModelChoice(id: trimmed, displayName: trimmed, source: .custom)
    }
}
