import Foundation
import Observation

/// Where a CLI's discovered model list lives between the surface that ran the
/// discovery and every surface that wants to show the result.
///
/// ## Why this exists
///
/// Settings → Agents could run `opencode models` / `cursor-agent models` and
/// show 190 choices while the New Ensemble canvas, for the same CLI, showed
/// the three or four curated ones. Same user, same machine, same minute, two
/// different answers to "which models can I pick?". The canvas was not wrong
/// to refuse to discover — opening a creation canvas must never spawn seven
/// CLI processes behind the user's back — it was wrong to conclude from that
/// that it could not *read* a result someone else had already paid for.
///
/// So discovery stays exactly where it was: an explicit, user-initiated
/// action. This type is only the place its result is kept. Reading it spawns
/// nothing, touches no CLI, and is safe from `init` and from a view body.
///
/// ## Why it persists
///
/// A discovered list is public catalog metadata — model ids and display names,
/// never a credential, never anything account-identifying beyond which models
/// an account was offered. Keeping it in `UserDefaults` alongside the other
/// Conductor preferences means a user refreshes once and both surfaces stay
/// complete across app launches, instead of silently collapsing back to the
/// curated fallback every time Rafu restarts. Staleness is bounded by the same
/// "Refresh models" button that created the entry, and a stale discovered list
/// is strictly better than the stale curated list it replaces.
nonisolated struct ConductorDiscoveredModelStore: Sendable {
    /// Mirrors `ConductorEnableStore`/`ConductorDefaultModelStore`: the SUITE
    /// NAME is stored rather than a `UserDefaults` instance, which is not
    /// `Sendable` on this toolchain, so tests inject an isolated suite instead
    /// of polluting the developer's real defaults.
    private let suiteName: String?

    /// A defensive ceiling on what will be read back out of defaults. Both
    /// adapters that discover already bound their own row counts; this bounds
    /// the *stored* side too, so a hand-edited or corrupted defaults entry
    /// cannot hand a picker an unbounded list.
    static let maximumStoredRows = 2_048

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static func key(for id: ConductorCLIID) -> String {
        "conductorDiscoveredModels.\(id.rawValue)"
    }

    /// `[]` when nothing has been discovered for this CLI, or when the stored
    /// value cannot be decoded — a corrupt entry reads as "no discovery has
    /// happened", which degrades to the curated list rather than to an error.
    func models(for id: ConductorCLIID) -> [ConductorModelChoice] {
        guard let data = defaults.data(forKey: Self.key(for: id)),
            let decoded = try? JSONDecoder().decode([ConductorModelChoice].self, from: data)
        else { return [] }
        return Array(decoded.prefix(Self.maximumStoredRows))
    }

    func setModels(_ models: [ConductorModelChoice], for id: ConductorCLIID) {
        let key = Self.key(for: id)
        let bounded = Array(models.prefix(Self.maximumStoredRows))
        guard !bounded.isEmpty, let data = try? JSONEncoder().encode(bounded) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}

/// The in-memory, observable view of `ConductorDiscoveredModelStore`, shared
/// by every surface in the app.
///
/// It is `@Observable`, so a canvas that is already open updates the moment a
/// refresh elsewhere stores a new list — the Settings window and the Ensemble
/// canvas cannot show different catalogs for the same CLI even transiently.
///
/// `shared` is the app's one instance. Tests (and any future preview) pass
/// their own with an isolated defaults suite; nothing here reaches for
/// `.shared` implicitly except the production default arguments.
@MainActor
@Observable
final class ConductorDiscoveredModelCache {
    static let shared = ConductorDiscoveredModelCache()

    @ObservationIgnored
    private let store: ConductorDiscoveredModelStore
    private var modelsByID: [ConductorCLIID: [ConductorModelChoice]] = [:]

    /// Reads nothing eagerly. The first `models(for:)` for a CLI faults its
    /// entry in from defaults, so constructing this — which happens at app
    /// launch for `shared` — costs one allocation.
    init(store: ConductorDiscoveredModelStore = ConductorDiscoveredModelStore()) {
        self.store = store
    }

    /// This CLI's last discovered list, or `[]` if discovery has never run for
    /// it. Never spawns a process; safe from a view body and from `init`.
    func models(for id: ConductorCLIID) -> [ConductorModelChoice] {
        if let cached = modelsByID[id] { return cached }
        let loaded = store.models(for: id)
        modelsByID[id] = loaded
        return loaded
    }

    /// Records the result of an explicit, user-initiated discovery pass.
    func setModels(_ models: [ConductorModelChoice], for id: ConductorCLIID) {
        modelsByID[id] = models
        store.setModels(models, for: id)
    }
}
