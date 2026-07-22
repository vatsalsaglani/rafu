import Foundation

/// Stub — lands in phase W3 (docs/plans/phases/usage-providers/
/// W3-local-sqlite-providers.md). No strategies yet: `makeStrategies`
/// returns `[]`, so the Settings "Usage" tab hides this row until W3 lands.
nonisolated enum OpenCodeGoProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .openCodeGo,
        displayName: "OpenCode Go",
        authPattern: .localZeroConfig,
        disclosure:
            "Not yet supported. Will read the local OpenCode Go/Zen SQLite database, with optional web enrichment.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
