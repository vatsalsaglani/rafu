import Foundation

/// Adapted from CodexBar's `ClinePassUsageFetcher.swift` and
/// `ClinePassSettingsReader.swift` at commit
/// cc8da27cec92029a6435bfee4a703a719290234e (MIT license).
///
/// That source exposes only five-hour, weekly, and monthly limits. Its
/// snapshot explicitly has no credits/PAYG model, so Rafu does not invent a
/// `costLine` for this endpoint.
nonisolated enum ClineProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .cline,
        displayName: "Cline / ClinePass",
        authPattern: .apiKey,
        disclosure:
            "Sends only the Cline/ClinePass API key you provide to api.cline.bot to fetch five-hour, weekly, and monthly usage limits; never prompts or messages.",
        defaultEnabled: false,
        makeStrategies: { _ in [ClineAPIKeyStrategy()] }
    )
}

nonisolated enum ClineUsageError: Error, Sendable, Equatable {
    case missingCredential
    case unauthorized
    case invalidResponse
}

nonisolated struct ClineAPIKeyStrategy: UsageFetchStrategy {
    let id = "cline.api-key"

    private let environmentCredential: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentCredential =
            ["CLINE_API_KEY", "CLINEPASS_API_KEY"]
            .lazy.compactMap { Self.cleaned(environment[$0]) }.first
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let apiKey = credential(in: context) else {
            throw ClineUsageError.missingCredential
        }

        var request = URLRequest(
            url: URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        do {
            (data, _) = try await context.http.send(request, provider: .cline)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw ClineUsageError.unauthorized
        }
        return try Self.parse(data)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let response = try? JSONDecoder().decode(ClineLimitsResponse.self, from: data),
            response.success
        else {
            throw ClineUsageError.invalidResponse
        }

        var windowsByType: [ClineLimitType: UsageWindow] = [:]
        for limit in response.data.limits {
            guard let label = limit.type.label else { continue }
            let reset: Date?
            if let resetsAt = limit.resetsAt {
                guard let parsed = UsageDateParsing.parseISO8601Fractional(resetsAt) else {
                    throw ClineUsageError.invalidResponse
                }
                reset = parsed
            } else {
                reset = nil
            }
            windowsByType[limit.type] = UsageWindow(
                label: label,
                percent: min(100, max(0, limit.percentUsed)),
                tokens: nil,
                resetsAt: reset)
        }

        let windows = ClineLimitType.displayOrder.compactMap { windowsByType[$0] }
        guard !windows.isEmpty else { throw ClineUsageError.invalidResponse }
        return UsageSnapshot(
            providerID: .cline,
            windows: windows,
            costLine: nil,
            identity: nil)
    }

    private func credential(in context: UsageFetchContext) -> String? {
        if let stored = Self.cleaned(context.credential(.cline)) {
            return stored
        }
        return environmentCredential
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

private nonisolated enum ClineLimitType: Decodable, Hashable, Sendable {
    case fiveHour
    case weekly
    case monthly
    case unknown

    static let displayOrder: [Self] = [.fiveHour, .weekly, .monthly]

    var label: String? {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "7d"
        case .monthly: "monthly"
        case .unknown: nil
        }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self =
            switch raw {
            case "five_hour": .fiveHour
            case "weekly": .weekly
            case "monthly": .monthly
            default: .unknown
            }
    }
}

private nonisolated struct ClineLimit: Decodable, Sendable {
    let type: ClineLimitType
    let percentUsed: Double
    let resetsAt: String?
}

private nonisolated struct ClineLimitsData: Decodable, Sendable {
    let limits: [ClineLimit]
}

private nonisolated struct ClineLimitsResponse: Decodable, Sendable {
    let data: ClineLimitsData
    let success: Bool
}
