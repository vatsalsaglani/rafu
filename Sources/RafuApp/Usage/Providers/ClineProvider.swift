import Foundation

/// Stub — lands in phase W4 (docs/plans/phases/usage-providers/
/// W4-api-key-providers.md). No strategies yet: `makeStrategies` returns
/// `[]`, so the Settings "Usage" tab hides this row until W4 lands.
nonisolated enum ClineProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .cline,
        displayName: "Cline",
        authPattern: .apiKey,
        disclosure:
            "Not yet supported. Will send an API key you provide to api.cline.bot to fetch five-hour/weekly/monthly usage limits.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
