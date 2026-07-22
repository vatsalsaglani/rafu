import Foundation

// Provider mechanism reviewed against CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

/// CodexBar's current Copilot implementation accepts a token from its own
/// settings/environment or starts an interactive device flow. Neither is a
/// discoverable, reusable local CLI credential that Rafu can safely
/// piggyback on, so W5 deliberately exposes one stable unavailable
/// strategy. Copilot's optional budget enrichment is cookie-only and is
/// outside this phase.
nonisolated struct CopilotUnavailableLocalTokenStrategy: UsageFetchStrategy {
    let id = "copilot.local-token-unavailable"

    func isAvailable(_ context: UsageFetchContext) async -> Bool { false }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        throw UsageLocalDataError.noData
    }

    func shouldFallback(on error: Error) -> Bool { false }
}

nonisolated enum CopilotProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .copilot,
        displayName: "GitHub Copilot",
        authPattern: .piggybackNetwork,
        disclosure:
            "Unavailable: current CodexBar source exposes no discoverable local Copilot CLI or gh token; core usage requires a manually or device-flow supplied token.",
        defaultEnabled: false,
        makeStrategies: { _ in [CopilotUnavailableLocalTokenStrategy()] }
    )
}
