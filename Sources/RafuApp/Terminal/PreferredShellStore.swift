import Foundation

/// Persists the user's most recently used terminal shell across sessions
/// (terminal-manager.md T-C, "recently selected or opened" — global, not
/// per-workspace). The model layer reads `UserDefaults` directly because
/// `@AppStorage` is a SwiftUI View-only property wrapper; `defaultsKey`
/// matches the key a future Settings row could bind via
/// `@AppStorage("preferredShellPath")` with no migration needed.
///
/// Stores the `UserDefaults` *suite name* rather than a `UserDefaults`
/// instance directly — `UserDefaults` is not `Sendable` on this toolchain,
/// so a stored instance would break this struct's honest `Sendable`
/// conformance. This mirrors `WorkspaceSearchHistoryStore`'s established
/// pattern (a deviation from the advisor brief's literal
/// `let defaults: UserDefaults` signature, made necessary by the SDK, not a
/// design choice).
nonisolated struct PreferredShellStore: Sendable {
    static let defaultsKey = "preferredShellPath"

    /// `nil` uses the standard defaults; tests inject a suite they clean up.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    /// The stored shell, matched by exact path against the current
    /// `shells` catalog. Returns `nil` (and clears the stored value) when
    /// the path no longer resolves to a known shell — e.g. it was
    /// uninstalled since it was last recorded.
    func resolved(in shells: [TerminalShell]) -> TerminalShell? {
        guard let path = defaults.string(forKey: Self.defaultsKey) else { return nil }
        if let match = shells.first(where: { $0.path == path }) {
            return match
        }
        clear()
        return nil
    }

    func record(_ shell: TerminalShell) {
        defaults.set(shell.path, forKey: Self.defaultsKey)
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
