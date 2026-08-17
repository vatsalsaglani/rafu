import Foundation

/// Stores the user's explicit choice to stop warning before a running pane
/// closes. This preference applies only to one pane. It never suppresses the
/// confirmation that closes a complete Terminal Group.
nonisolated struct TerminalPaneClosePreferenceStore: Sendable {
    static let defaultsKey = "skipRunningTerminalPaneCloseConfirmation"

    /// `nil` uses the app defaults. Tests use an isolated suite.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    var skipsRunningPaneConfirmation: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    func suppressFutureConfirmations() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}
