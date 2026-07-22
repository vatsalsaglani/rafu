import Foundation

/// Stub — lands in phase W5 (docs/plans/phases/usage-providers/
/// W5-local-token-providers.md). No strategies yet: `makeStrategies`
/// returns `[]`, so the Settings "Usage" tab hides this row until W5 lands.
nonisolated enum GeminiCLIProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .geminiCLI,
        displayName: "Gemini CLI",
        authPattern: .localZeroConfig,
        disclosure: "Not yet supported. Will read Gemini CLI's local usage/token files.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
