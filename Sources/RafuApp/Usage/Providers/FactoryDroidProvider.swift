import Foundation

/// Stub — lands in phase W7 (docs/plans/phases/usage-providers/
/// W7-cookie-providers-2.md). No strategies yet: `makeStrategies` returns
/// `[]`, so the Settings "Usage" tab hides this row until W7 lands.
nonisolated enum FactoryDroidProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .factoryDroid,
        displayName: "Factory Droid",
        authPattern: .cookieImport,
        disclosure:
            "Not yet supported. Will use a browser cookie you import to fetch Factory Droid usage.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
