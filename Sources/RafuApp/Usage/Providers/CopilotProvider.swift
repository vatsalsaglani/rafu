import Foundation

/// Stub — lands in phase W5 (docs/plans/phases/usage-providers/
/// W5-local-token-providers.md). No strategies yet: `makeStrategies`
/// returns `[]`, so the Settings "Usage" tab hides this row until W5 lands.
nonisolated enum CopilotProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .copilot,
        displayName: "GitHub Copilot",
        authPattern: .localZeroConfig,
        disclosure:
            "Not yet supported. Will read GitHub Copilot's local premium-request quota data.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
