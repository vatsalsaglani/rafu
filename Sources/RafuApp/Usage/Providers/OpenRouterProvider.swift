import Foundation

/// Adapted from CodexBar's `OpenRouterUsageStats.swift`,
/// `OpenRouterSettingsReader.swift`, and `OpenRouterProviderDescriptor.swift`
/// at commit cc8da27cec92029a6435bfee4a703a719290234e (MIT license).
nonisolated enum OpenRouterProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .openRouter,
        displayName: "OpenRouter",
        authPattern: .apiKey,
        disclosure:
            "Sends only the OpenRouter API key you provide to openrouter.ai to fetch credit usage and an optional key limit. This also represents Roo Code and other BYO-key spend routed through OpenRouter.",
        defaultEnabled: false,
        makeStrategies: { _ in [OpenRouterAPIKeyStrategy()] }
    )
}

nonisolated enum OpenRouterUsageError: Error, Sendable, Equatable {
    case missingCredential
    case unauthorized
    case invalidResponse
}

nonisolated struct OpenRouterAPIKeyStrategy: UsageFetchStrategy {
    let id = "openrouter.api-key"

    private let environmentCredential: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentCredential = Self.cleaned(environment["OPENROUTER_API_KEY"])
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let apiKey = credential(in: context) else {
            throw OpenRouterUsageError.missingCredential
        }

        let credits = try await fetchCredits(apiKey: apiKey, context: context)
        let keyQuota = try await fetchOptionalKeyQuota(apiKey: apiKey, context: context)
        let balance = max(0, credits.totalCredits - credits.totalUsage)
        let costLine = String(
            format: "$%.2f used · $%.2f left",
            locale: Locale(identifier: "en_US_POSIX"),
            credits.totalUsage,
            balance)

        let windows: [UsageWindow]
        if let limit = keyQuota?.limit, limit > 0,
            let usage = keyQuota?.usage, usage >= 0
        {
            windows = [
                UsageWindow(
                    label: "limit",
                    percent: min(100, max(0, usage / limit * 100)),
                    tokens: nil,
                    resetsAt: nil)
            ]
        } else {
            windows = []
        }

        return UsageSnapshot(
            providerID: .openRouter,
            windows: windows,
            costLine: costLine,
            identity: nil)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    private func fetchCredits(
        apiKey: String,
        context: UsageFetchContext
    ) async throws -> OpenRouterCreditsData {
        let data = try await send(path: "credits", apiKey: apiKey, context: context)
        guard let response = try? JSONDecoder().decode(OpenRouterCreditsResponse.self, from: data),
            response.data.totalCredits >= 0,
            response.data.totalUsage >= 0
        else {
            throw OpenRouterUsageError.invalidResponse
        }
        return response.data
    }

    private func fetchOptionalKeyQuota(
        apiKey: String,
        context: UsageFetchContext
    ) async throws -> OpenRouterKeyData? {
        do {
            let data = try await send(path: "key", apiKey: apiKey, context: context)
            return try? JSONDecoder().decode(OpenRouterKeyResponse.self, from: data).data
        } catch OpenRouterUsageError.unauthorized {
            throw OpenRouterUsageError.unauthorized
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // `/key` is enrichment only. `UsageHTTPClient` has already
            // recorded a 429 gate before this degrades to credits-only.
            return nil
        }
    }

    private func send(
        path: String,
        apiKey: String,
        context: UsageFetchContext
    ) async throws -> Data {
        let url = URL(string: "https://openrouter.ai/api/v1/\(path)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Rafu", forHTTPHeaderField: "X-Title")

        do {
            let (data, _) = try await context.http.send(request, provider: .openRouter)
            return data
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw OpenRouterUsageError.unauthorized
        }
    }

    private func credential(in context: UsageFetchContext) -> String? {
        Self.cleaned(context.credential(.openRouter))
            ?? environmentCredential
    }

    private static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? nil : value
    }
}

private nonisolated struct OpenRouterCreditsResponse: Decodable, Sendable {
    let data: OpenRouterCreditsData
}

private nonisolated struct OpenRouterCreditsData: Decodable, Sendable {
    let totalCredits: Double
    let totalUsage: Double

    private enum CodingKeys: String, CodingKey {
        case totalCredits = "total_credits"
        case totalUsage = "total_usage"
    }
}

private nonisolated struct OpenRouterKeyResponse: Decodable, Sendable {
    let data: OpenRouterKeyData
}

private nonisolated struct OpenRouterKeyData: Decodable, Sendable {
    let limit: Double?
    let usage: Double?
}
