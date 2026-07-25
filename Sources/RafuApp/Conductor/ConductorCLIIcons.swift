import Foundation

/// The static, seven-provider icon catalog shared by every agent-aware
/// surface. Vendor SVGs are template-tinted and always retain a system-symbol
/// fallback so a missing asset degrades without hiding the provider's name.
nonisolated enum ConductorCLIIcons {
    static func icon(for id: ConductorCLIID) -> FileIconProvider.Icon {
        switch id {
        case .claudeCode:
            agentIcon(assetName: "agent-claude-code")
        case .codex:
            agentIcon(assetName: "agent-codex")
        case .openCode:
            agentIcon(assetName: "agent-opencode")
        case .cline:
            agentIcon(assetName: "agent-cline")
        case .kimi:
            agentIcon(assetName: "agent-kimi")
        case .geminiCLI:
            agentIcon(assetName: "agent-gemini")
        case .cursor:
            agentIcon(assetName: "agent-cursor")
        }
    }

    private static func agentIcon(assetName: String) -> FileIconProvider.Icon {
        FileIconProvider.Icon(
            symbol: "terminal",
            tint: .secondary,
            assetName: assetName,
            assetIsTemplate: true)
    }
}
