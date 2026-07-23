import Foundation

/// Per-adapter enable state (conductor/C0-shim.md, "Settings surface").
/// Mirrors `UsageEnableStore`'s suite-name idiom exactly: the SUITE NAME is
/// stored, not a `UserDefaults` instance (`UserDefaults` is not `Sendable`
/// on this toolchain), so tests inject an isolated suite instead of
/// polluting the developer's real defaults.
///
/// This store holds preferences only. No credential of any kind is stored
/// for the Conductor anywhere, in `UserDefaults` or Keychain — inference auth
/// is fully delegated to each vendor CLI (ADR 0018).
nonisolated struct ConductorEnableStore: Sendable {
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static func key(for id: ConductorCLIID) -> String {
        "conductorAdapterEnabled.\(id.rawValue)"
    }

    /// `defaultValue` is the adapter's `ConductorCLIAdapter.defaultEnabled` —
    /// callers always pass it explicitly rather than this store hardcoding
    /// one, so the store stays adapter-agnostic.
    func isEnabled(_ id: ConductorCLIID, default defaultValue: Bool) -> Bool {
        let key = Self.key(for: id)
        return defaults.object(forKey: key) == nil ? defaultValue : defaults.bool(forKey: key)
    }

    func setEnabled(_ value: Bool, for id: ConductorCLIID) {
        defaults.set(value, forKey: Self.key(for: id))
    }
}

/// The per-adapter default model a role inherits when its `.rafu/agents/*.md`
/// file names none. Plain preference text — a model identifier, never a
/// credential.
nonisolated struct ConductorDefaultModelStore: Sendable {
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    static func key(for id: ConductorCLIID) -> String {
        "conductorAdapterDefaultModel.\(id.rawValue)"
    }

    /// `""` means "no default chosen"; the adapter decides.
    func defaultModel(for id: ConductorCLIID) -> String {
        defaults.string(forKey: Self.key(for: id)) ?? ""
    }

    func setDefaultModel(_ value: String, for id: ConductorCLIID) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: Self.key(for: id))
        } else {
            defaults.set(trimmed, forKey: Self.key(for: id))
        }
    }
}
