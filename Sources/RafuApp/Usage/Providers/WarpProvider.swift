// Adapted from CodexBar's WarpUsageFetcher.swift and
// WarpProviderDescriptor.swift at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum WarpUsageError: Error, Sendable, Equatable {
    case missingCredential
    case unauthorized
    case invalidResponse
}

nonisolated struct WarpAPIKeyStrategy: UsageFetchStrategy {
    let id = "warp.api-key"

    private static let endpoint = URL(
        string: "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo")!
    private static let maximumCredentialBytes = 16 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024
    private static let graphQLQuery = """
        query GetRequestLimitInfo($requestContext: RequestContext!) {
          user(requestContext: $requestContext) {
            __typename
            ... on UserOutput {
              user {
                requestLimitInfo {
                  isUnlimited
                  nextRefreshTime
                  requestLimit
                  requestsUsedSinceLastRefresh
                }
                bonusGrants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
                workspaces {
                  bonusGrantsInfo {
                    grants {
                      requestCreditsGranted
                      requestCreditsRemaining
                      expiration
                    }
                  }
                }
              }
            }
          }
        }
        """

    private let environmentCredential: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentCredential =
            Self.cleanedCredential(environment["WARP_API_KEY"])
            ?? Self.cleanedCredential(environment["WARP_TOKEN"])
    }

    @concurrent
    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    @concurrent
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let credential = credential(in: context) else {
            throw WarpUsageError.missingCredential
        }

        let version = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("warp-app", forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersion, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("Warp/1.0", forHTTPHeaderField: "User-Agent")

        guard
            let body = try? JSONSerialization.data(withJSONObject: [
                "query": Self.graphQLQuery,
                "operationName": "GetRequestLimitInfo",
                "variables": [
                    "requestContext": [
                        "clientContext": [:] as [String: String],
                        "osContext": [
                            "category": "macOS",
                            "name": "macOS",
                            "version": osVersion,
                        ],
                    ]
                ],
            ])
        else { throw WarpUsageError.invalidResponse }
        request.httpBody = body

        let data: Data
        do {
            (data, _) = try await context.http.send(request, provider: .warp)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw WarpUsageError.unauthorized
        }
        try Task.checkCancellation()
        return try Self.parseResponse(data)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    static func parseResponse(_ data: Data) throws -> UsageSnapshot {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw WarpUsageError.invalidResponse }

        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            let unauthorized = errors.contains { value in
                let message: String?
                if let string = value as? String {
                    message = string
                } else {
                    message = (value as? [String: Any])?["message"] as? String
                }
                guard let message else { return false }
                let lowered = message.lowercased()
                return lowered.contains("unauthorized") || lowered.contains("authentication")
            }
            throw unauthorized ? WarpUsageError.unauthorized : WarpUsageError.invalidResponse
        }

        guard let dataObject = root["data"] as? [String: Any],
            let userOutput = dataObject["user"] as? [String: Any]
        else { throw WarpUsageError.invalidResponse }
        if let typeName = userOutput["__typename"] as? String, typeName != "UserOutput" {
            throw WarpUsageError.invalidResponse
        }
        guard let user = userOutput["user"] as? [String: Any],
            let limitInfo = user["requestLimitInfo"] as? [String: Any],
            let isUnlimited = boolValue(limitInfo["isUnlimited"])
        else { throw WarpUsageError.invalidResponse }

        var windows: [UsageWindow] = []
        var costLine: String?
        if isUnlimited {
            costLine = "Unlimited AI requests"
        } else {
            guard let requestLimit = intValue(limitInfo["requestLimit"]), requestLimit > 0,
                let requestsUsed = intValue(limitInfo["requestsUsedSinceLastRefresh"]),
                requestsUsed >= 0
            else { throw WarpUsageError.invalidResponse }
            windows.append(
                UsageWindow(
                    label: "requests",
                    percent: min(100, Double(requestsUsed) / Double(requestLimit) * 100),
                    tokens: nil,
                    resetsAt: (limitInfo["nextRefreshTime"] as? String)
                        .flatMap(UsageDateParsing.parseISO8601Fractional)))
        }

        let bonus = bonusTotals(user: user)
        if bonus.total > 0 {
            windows.append(
                UsageWindow(
                    label: "add-on credits",
                    percent: Double(bonus.total - bonus.remaining) / Double(bonus.total) * 100,
                    tokens: nil,
                    resetsAt: nil))
        }

        let snapshot = UsageSnapshot(
            providerID: .warp,
            windows: windows,
            costLine: costLine,
            identity: nil)
        guard snapshot.renderable else { throw WarpUsageError.invalidResponse }
        return snapshot
    }

    private func credential(in context: UsageFetchContext) -> String? {
        Self.cleanedCredential(context.credential(.warp)) ?? environmentCredential
    }

    private static func cleanedCredential(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= maximumCredentialBytes
        else { return nil }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'"))
        {
            value = String(value.dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, !value.contains("\r"), !value.contains("\n") else { return nil }
        return value
    }

    private static func bonusTotals(user: [String: Any]) -> (total: Int, remaining: Int) {
        var grants = (user["bonusGrants"] as? [[String: Any]]) ?? []
        for workspace in (user["workspaces"] as? [[String: Any]]) ?? [] {
            guard let info = workspace["bonusGrantsInfo"] as? [String: Any],
                let workspaceGrants = info["grants"] as? [[String: Any]]
            else { continue }
            grants.append(contentsOf: workspaceGrants)
        }

        var total = 0
        var remaining = 0
        for grant in grants {
            guard let granted = intValue(grant["requestCreditsGranted"]), granted >= 0,
                let grantRemaining = intValue(grant["requestCreditsRemaining"]),
                (0...granted).contains(grantRemaining)
            else { continue }
            let (nextTotal, totalOverflow) = total.addingReportingOverflow(granted)
            let (nextRemaining, remainingOverflow) = remaining.addingReportingOverflow(
                grantRemaining)
            guard !totalOverflow, !remainingOverflow else { continue }
            total = nextTotal
            remaining = nextRemaining
        }
        return (total, remaining)
    }

    private static func intValue(_ value: Any?) -> Int? {
        if value is Bool { return nil }
        if let value = value as? Int { return value }
        if let value = value as? NSNumber {
            let double = value.doubleValue
            guard double.isFinite, double.rounded() == double,
                double >= Double(Int.min), double <= Double(Int.max)
            else { return nil }
            return Int(double)
        }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? String {
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

nonisolated enum WarpProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .warp,
        displayName: "Warp",
        authPattern: .apiKey,
        disclosure:
            "Sends only the Warp API key you provide (or WARP_API_KEY/WARP_TOKEN) to app.warp.dev/graphql/v2 to fetch AI request and add-on credit counts. Warp exposes no cookie usage path.",
        defaultEnabled: false,
        makeStrategies: { _ in [WarpAPIKeyStrategy()] }
    )
}
