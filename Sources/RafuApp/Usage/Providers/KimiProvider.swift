import Foundation

/// Stub — lands in phase W5 (docs/plans/phases/usage-providers/
/// W5-local-token-providers.md). No strategies yet: `makeStrategies`
/// returns `[]`, so the Settings "Usage" tab hides this row until W5 lands.
nonisolated enum KimiProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .kimi,
        displayName: "Kimi",
        authPattern: .localZeroConfig,
        disclosure: "Not yet supported. Will read Kimi/Moonshot CLI's local usage/token files.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
