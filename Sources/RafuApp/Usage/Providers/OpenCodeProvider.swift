import Foundation

/// Stub — lands in phase W3 (docs/plans/phases/usage-providers/
/// W3-local-sqlite-providers.md). No strategies yet: `makeStrategies`
/// returns `[]`, so the Settings "Usage" tab hides this row until W3 lands.
nonisolated enum OpenCodeProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .openCode,
        displayName: "OpenCode",
        authPattern: .localZeroConfig,
        disclosure:
            "Not yet supported. Will read the local OpenCode SQLite database (no network) to compute spend against your configured caps.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
