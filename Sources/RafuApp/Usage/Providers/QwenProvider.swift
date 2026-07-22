import Foundation

/// Stub — the API-key path lands in phase W4
/// (docs/plans/phases/usage-providers/W4-api-key-providers.md); the
/// intl/`.com.cn` dual-region cookie path lands alongside Qoder in phase
/// W8 (docs/plans/phases/usage-providers/W8-alibaba-providers.md). No
/// strategies yet: `makeStrategies` returns `[]`, so the Settings "Usage"
/// tab hides this row until W4 lands.
nonisolated enum QwenProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .qwen,
        displayName: "Qwen",
        authPattern: .apiKey,
        disclosure:
            "Not yet supported. Will send an API key you provide (or, later, an imported cookie) to Alibaba's Qwen coding-plan quota endpoint.",
        defaultEnabled: false,
        makeStrategies: { _ in [] }
    )
}
