// Adapted from CodexBar (https://github.com/steipete/CodexBar), MIT
// License. W3 intentionally stops at CodexBar's local OpenCode Go SQLite
// strategy; Zen balance and web enrichment remain Wave B work.

import Foundation

nonisolated enum OpenCodeGoProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .openCodeGo,
        displayName: "OpenCode Go",
        authPattern: .localZeroConfig,
        disclosure:
            "Reads OpenCode Go cost and timestamp metric fields from ~/.local/share/opencode/opencode.db after detecting its auth.json key. Local only — Zen/web enrichment is not used.",
        defaultEnabled: true,
        makeStrategies: { _ in
            [
                OpenCodeLocalUsageStrategy(
                    providerID: .openCodeGo,
                    scope: .openCodeGo)
            ]
        }
    )
}
