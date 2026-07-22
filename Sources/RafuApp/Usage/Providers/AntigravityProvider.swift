import Foundation

/// Stub — lands in phase W6 (docs/plans/phases/usage-providers/
/// W6-cookie-providers-1.md). No strategies yet: `makeStrategies` returns
/// `[]`, so the Settings "Usage" tab hides this row until W6 lands.
nonisolated enum AntigravityProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .antigravity,
        displayName: "Antigravity",
        authPattern: .cookieImport,
        disclosure:
            "Not yet supported. Will use a browser cookie you import to fetch your Antigravity usage.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
