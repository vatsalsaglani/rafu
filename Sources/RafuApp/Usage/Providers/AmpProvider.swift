import Foundation

/// Stub — lands in phase W7 (docs/plans/phases/usage-providers/
/// W7-cookie-providers-2.md). No strategies yet: `makeStrategies` returns
/// `[]`, so the Settings "Usage" tab hides this row until W7 lands.
nonisolated enum AmpProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .amp,
        displayName: "Amp",
        authPattern: .cookieImport,
        disclosure:
            "Not yet supported. Will use a browser cookie you import to fetch Sourcegraph Amp usage.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
