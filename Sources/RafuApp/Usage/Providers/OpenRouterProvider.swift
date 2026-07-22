import Foundation

/// Stub — lands in phase W4 (docs/plans/phases/usage-providers/
/// W4-api-key-providers.md). No strategies yet: `makeStrategies` returns
/// `[]`, so the Settings "Usage" tab hides this row until W4 lands. Also
/// the honest coverage for BYO-key Cline/Roo Code setups
/// (agent-usage-providers.md, "Roo Code note").
nonisolated enum OpenRouterProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .openRouter,
        displayName: "OpenRouter",
        authPattern: .apiKey,
        disclosure:
            "Not yet supported. Will send an API key you provide to OpenRouter's credits endpoint.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
