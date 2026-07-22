import Foundation

/// The full 19-provider roster (agent-usage-providers.md, "Provider
/// roster"), in the SAME order as `UsageProviderID`'s case list — Claude
/// and Codex first for detection-order parity with the shipped companion
/// strip. `UsageSettingsSection` and `UsageRegistryReader` both default to
/// iterating `all` in this order.
nonisolated enum UsageProviderRegistry {
    static let all: [UsageProviderDescriptor] = [
        ClaudeProvider.descriptor,
        CodexProvider.descriptor,
        ClineProvider.descriptor,
        OpenCodeProvider.descriptor,
        OpenCodeGoProvider.descriptor,
        CursorProvider.descriptor,
        AntigravityProvider.descriptor,
        GrokBuildProvider.descriptor,
        GeminiCLIProvider.descriptor,
        KiloCodeProvider.descriptor,
        CopilotProvider.descriptor,
        WindsurfProvider.descriptor,
        AmpProvider.descriptor,
        FactoryDroidProvider.descriptor,
        OpenRouterProvider.descriptor,
        KimiProvider.descriptor,
        WarpProvider.descriptor,
        QwenProvider.descriptor,
        QoderProvider.descriptor,
    ]

    static func descriptor(for id: UsageProviderID) -> UsageProviderDescriptor? {
        all.first { $0.id == id }
    }
}
