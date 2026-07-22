// Adapted from CodexBar's Qoder provider at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT license).

import Foundation

nonisolated enum QoderProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .qoder,
        displayName: "Qoder",
        authPattern: .cookieImport,
        disclosure:
            "Sends only the Qoder browser cookie you import to qoder.com or qoder.com.cn, according to your region preference, to fetch big-model-credit usage metrics.",
        defaultEnabled: false,
        makeStrategies: { _ in [QoderCookieStrategy()] }
    )
}

nonisolated enum QoderUsageError: Error, Sendable, Equatable {
    case missingCredential
    case invalidCredentials
    case invalidResponse
}

nonisolated enum QoderRegion: String, CaseIterable, Sendable {
    case international = "intl"
    case chinaMainland = "cn"

    var webOrigin: URL {
        switch self {
        case .international:
            URL(string: "https://qoder.com")!
        case .chinaMainland:
            URL(string: "https://qoder.com.cn")!
        }
    }

    var usageURL: URL {
        webOrigin.appending(path: "api/v2/me/usages/big_model_credits")
    }

    var dashboardURL: URL {
        webOrigin.appending(path: "account/usage")
    }

    /// CodexBar imports every cookie for these exact domains; Qoder has no
    /// production session-name filter (`sid` is only an upstream test fixture).
    var cookieImportDomains: [String] {
        switch self {
        case .international:
            ["qoder.com", "www.qoder.com"]
        case .chinaMainland:
            ["qoder.com.cn", "www.qoder.com.cn"]
        }
    }
}

nonisolated enum QoderRegionPreference {
    static let defaultsKey = "usageProviderRegion.qoder"

    static func load(suiteName: String? = nil) -> QoderRegion {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        guard let rawValue = defaults.string(forKey: defaultsKey),
            let region = QoderRegion(rawValue: rawValue)
        else { return .international }
        return region
    }

    static func save(_ region: QoderRegion, suiteName: String? = nil) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        defaults.set(region.rawValue, forKey: defaultsKey)
    }
}

nonisolated struct QoderCookieStrategy: UsageFetchStrategy {
    let id = "qoder.cookie"

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let region: QoderRegion

    init(region: QoderRegion = QoderRegionPreference.load()) {
        self.region = region
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.cookieHeader(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let cookieHeader = Self.cookieHeader(in: context) else {
            throw QoderUsageError.missingCredential
        }

        var request = URLRequest(url: region.usageURL)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.webOrigin.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("2.5.35", forHTTPHeaderField: "Bx-V")

        let data: Data
        do {
            (data, _) = try await context.http.send(request, provider: .qoder)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw QoderUsageError.invalidCredentials
        }
        return try Self.parse(data, now: context.now)
    }

    func shouldFallback(on _: Error) -> Bool { false }

    static func parse(_ data: Data, now _: Date) throws -> UsageSnapshot {
        guard let response = try? JSONDecoder().decode(QoderUsageResponse.self, from: data),
            let totalSummary = response.totalQuota?.quotaSummary
        else {
            throw QoderUsageError.invalidResponse
        }

        let merged = try mergedQuota(base: totalSummary, shared: response.sharedQuota?.quotaSummary)
        return UsageSnapshot(
            providerID: .qoder,
            windows: [
                UsageWindow(
                    label: "credits",
                    percent: min(100, max(0, merged.usagePercentage)),
                    tokens: nil,
                    resetsAt: response.nextResetAt)
            ],
            costLine:
                "\(formatCredits(merged.usedCredits)) / \(formatCredits(merged.totalCredits)) credits",
            identity: nil)
    }

    private struct MergedQuota {
        let usedCredits: Double
        let totalCredits: Double
        let remainingCredits: Double
        let usagePercentage: Double
    }

    private static func mergedQuota(
        base: QoderQuotaSummary, shared: QoderQuotaSummary?
    ) throws -> MergedQuota {
        let baseRemaining = try remainingCredits(for: base)
        guard let shared else {
            return MergedQuota(
                usedCredits: base.usedValue,
                totalCredits: base.limitValue,
                remainingCredits: baseRemaining,
                usagePercentage: try usagePercentage(
                    used: base.usedValue,
                    total: base.limitValue,
                    remaining: baseRemaining,
                    provided: base.usagePercentage))
        }

        let sharedRemaining = try remainingCredits(for: shared)
        let used = base.usedValue + shared.usedValue
        let total = base.limitValue + shared.limitValue
        let remaining = baseRemaining + sharedRemaining
        return MergedQuota(
            usedCredits: used,
            totalCredits: total,
            remainingCredits: remaining,
            usagePercentage: try usagePercentage(
                used: used, total: total, remaining: remaining, provided: nil))
    }

    private static func remainingCredits(for summary: QoderQuotaSummary) throws -> Double {
        guard summary.usedValue >= 0, summary.limitValue >= 0,
            summary.remainingValue.map({ $0 >= 0 }) ?? true
        else { throw QoderUsageError.invalidResponse }
        return summary.remainingValue ?? max(0, summary.limitValue - summary.usedValue)
    }

    private static func usagePercentage(
        used: Double, total: Double, remaining: Double, provided: Double?
    ) throws -> Double {
        guard used >= 0, total >= 0, remaining >= 0 else {
            throw QoderUsageError.invalidResponse
        }
        guard total > 0 else {
            guard used == 0, remaining == 0 else {
                throw QoderUsageError.invalidResponse
            }
            return provided ?? 100
        }
        return provided ?? used / total * 100
    }

    private static func formatCredits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    private static func cookieHeader(in context: UsageFetchContext) -> String? {
        guard
            let header = context.cookieHeader(.qoder)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !header.isEmpty
        else { return nil }
        return header
    }
}

private nonisolated struct QoderUsageResponse: Decodable, Sendable {
    let totalQuota: QoderQuotaContainer?
    let sharedQuota: QoderQuotaContainer?
    let nextResetAt: Date?

    private enum CodingKeys: String, CodingKey {
        case totalQuota
        case totalQuotaSnake = "total_quota"
        case sharedQuota
        case sharedQuotaSnake = "shared_quota"
        case nextResetAt
        case nextResetAtSnake = "next_reset_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalQuota =
            try container.decodeIfPresent(QoderQuotaContainer.self, forKey: .totalQuota)
            ?? container.decodeIfPresent(QoderQuotaContainer.self, forKey: .totalQuotaSnake)
        sharedQuota =
            try container.decodeIfPresent(QoderQuotaContainer.self, forKey: .sharedQuota)
            ?? container.decodeIfPresent(QoderQuotaContainer.self, forKey: .sharedQuotaSnake)
        nextResetAt =
            Self.decodeDate(from: container, forKey: .nextResetAt)
            ?? Self.decodeDate(from: container, forKey: .nextResetAtSnake)
    }

    private static func decodeDate(
        from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) -> Date? {
        if let value = try? container.decode(String.self, forKey: key) {
            return UsageDateParsing.parseISO8601Fractional(value)
        }
        if let value = try? container.decode(Double.self, forKey: key) {
            let seconds = value > 10_000_000_000 ? value / 1_000 : value
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }
}

private nonisolated struct QoderQuotaContainer: Decodable, Sendable {
    let quotaSummary: QoderQuotaSummary?

    private enum CodingKeys: String, CodingKey {
        case quotaSummary
        case quotaSummarySnake = "quota_summary"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        quotaSummary =
            try container.decodeIfPresent(QoderQuotaSummary.self, forKey: .quotaSummary)
            ?? container.decodeIfPresent(QoderQuotaSummary.self, forKey: .quotaSummarySnake)
    }
}

private nonisolated struct QoderQuotaSummary: Decodable, Sendable {
    let usedValue: Double
    let limitValue: Double
    let remainingValue: Double?
    let usagePercentage: Double?

    private enum CodingKeys: String, CodingKey {
        case usedValue
        case usedValueSnake = "used_value"
        case limitValue
        case limitValueSnake = "limit_value"
        case remainingValue
        case remainingValueSnake = "remaining_value"
        case usagePercentage
        case usagePercentageSnake = "usage_percentage"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedValue =
            try container.decodeIfPresent(Double.self, forKey: .usedValue)
            ?? container.decode(Double.self, forKey: .usedValueSnake)
        limitValue =
            try container.decodeIfPresent(Double.self, forKey: .limitValue)
            ?? container.decode(Double.self, forKey: .limitValueSnake)
        remainingValue =
            try container.decodeIfPresent(Double.self, forKey: .remainingValue)
            ?? container.decodeIfPresent(Double.self, forKey: .remainingValueSnake)
        usagePercentage =
            try container.decodeIfPresent(Double.self, forKey: .usagePercentage)
            ?? container.decodeIfPresent(Double.self, forKey: .usagePercentageSnake)
    }
}
