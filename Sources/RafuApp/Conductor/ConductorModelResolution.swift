import Foundation

/// Which model a provider will actually use, and where that answer came from.
///
/// Rafu shows the model in four places — the coordinator card, each allowed
/// CLI, the graph and Runs panel, and the launched ensemble's header — and all
/// four must agree. They did not before: the creation canvas said "Provider
/// default", run detail said "Adapter default", and neither named a model. One
/// resolver keeps them consistent and, more importantly, keeps them *honest*.
///
/// ## The honest floor
///
/// There is a real limit here, and it is the whole reason this type carries a
/// `source` rather than just a string. An adapter exposes `curatedModels()` and
/// `discoverModels()`, but **no designated built-in default**. When no model is
/// chosen, the adapter passes no `--model` flag at all and the CLI picks for
/// itself, using whatever its own config says. Rafu genuinely does not know
/// that value.
///
/// So `.cliDecides` is not a placeholder to be filled in later — it is the
/// truthful answer, and it must never be replaced by guessing `curatedModels()
/// .first`. That guess would look like knowledge and be wrong whenever a user's
/// CLI config differs from Rafu's shipped list, which is exactly the case where
/// a wrong model quietly spends the user's tokens.
nonisolated struct ConductorModelResolution: Equatable, Sendable {
    /// The exact string that will be handed to the CLI as `--model <id>`, or
    /// `nil` when no flag will be passed at all.
    let modelID: String?
    let source: Source
    /// What the display name resolves to — a catalog entry's `displayName`
    /// when the id is one Rafu knows, the raw id when it is not, and a stated
    /// fallback when there is no id.
    let displayName: String

    nonisolated enum Source: Equatable, Sendable {
        /// Chosen for this specific role or step.
        case explicit
        /// Chosen for this ensemble, applying to every role bound to the
        /// provider that has no explicit model of its own.
        case ensembleDefault
        /// The user's per-CLI default from Settings → Agents.
        case settingsDefault
        /// Nothing is set anywhere. No `--model` flag is passed and the CLI
        /// applies its own configured default, which Rafu cannot read.
        case cliDecides
    }

    /// Short, human-facing label for a chip or a caption.
    var label: String { displayName }

    /// Longer form for tooltips and accessibility, naming the *source* so a
    /// user can tell "I picked this" from "your Settings picked this" from
    /// "nobody picked, the CLI will".
    var detailedLabel: String {
        switch source {
        case .explicit: displayName
        case .ensembleDefault: "\(displayName) — this Ensemble's default"
        case .settingsDefault: "\(displayName) — your default for this CLI"
        case .cliDecides: displayName
        }
    }

    /// `true` when Rafu is naming a specific model rather than deferring.
    var namesAModel: Bool { modelID != nil }

    /// Resolves in precedence order: the explicit choice, then this
    /// ensemble's per-provider default, then the Settings default, then
    /// nothing.
    ///
    /// Every string input is trimmed and empty-checked, because "" is the
    /// established "not set" value throughout the Conductor stores
    /// (`ConductorDefaultModelStore.defaultModel(for:)` documents it), and an
    /// untrimmed whitespace string would otherwise resolve as a model named
    /// " " and be passed to the CLI as one.
    ///
    /// - Parameter catalog: models the adapter offers, used only to turn an id
    ///   into a friendlier display name. An id absent from the catalog is
    ///   still resolved — the user may legitimately run a model Rafu has never
    ///   heard of — it simply displays as itself.
    static func resolve(
        explicit: String?,
        ensembleDefault: String?,
        settingsDefault: String?,
        catalog: [ConductorModelChoice] = [],
        unsetLabel: String = "CLI default"
    ) -> ConductorModelResolution {
        let candidates: [(String?, Source)] = [
            (explicit, .explicit),
            (ensembleDefault, .ensembleDefault),
            (settingsDefault, .settingsDefault),
        ]
        for (value, source) in candidates {
            guard let trimmed = normalized(value) else { continue }
            return ConductorModelResolution(
                modelID: trimmed,
                source: source,
                displayName: displayName(for: trimmed, in: catalog)
            )
        }
        return ConductorModelResolution(
            modelID: nil, source: .cliDecides, displayName: unsetLabel)
    }

    /// `nil` for nil, empty, or whitespace-only input; the trimmed value
    /// otherwise.
    static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func displayName(for id: String, in catalog: [ConductorModelChoice]) -> String {
        catalog.first { $0.id == id }?.displayName ?? id
    }
}
