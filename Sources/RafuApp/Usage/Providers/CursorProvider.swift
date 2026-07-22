import Foundation

/// Stub — lands in phase W3 (docs/plans/phases/usage-providers/
/// W3-local-sqlite-providers.md). No strategies yet: `makeStrategies`
/// returns `[]`, so the Settings "Usage" tab hides this row until W3 lands.
nonisolated enum CursorProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .cursor,
        displayName: "Cursor",
        authPattern: .localZeroConfig,
        disclosure:
            "Not yet supported. Will read Cursor's own token from its local SQLite database (state.vscdb) to fetch your plan usage from cursor.com.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
