import Foundation

/// Adapted from CodexBar's `AlibabaCodingPlanAPIRegion.swift`,
/// `AlibabaCodingPlanUsageFetcher.swift`, `AlibabaCodingPlanUsageSnapshot.swift`,
/// and `AlibabaCodingPlanSettingsReader.swift` at commit
/// cc8da27cec92029a6435bfee4a703a719290234e (MIT license).
///
/// W4 implements only Alibaba Coding Plan's API-key path. The Alibaba Token
/// Plan source is cookie-only and remains W8 scope.
nonisolated enum QwenProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .qwen,
        displayName: "Qwen",
        authPattern: .apiKey,
        disclosure:
            "Sends only the Alibaba Qwen API key you provide to modelstudio.console.alibabacloud.com or bailian.console.aliyun.com, according to your region preference, to fetch Coding Plan quota metrics.",
        defaultEnabled: false,
        makeStrategies: { _ in [QwenAPIKeyStrategy()] }
    )
}

nonisolated enum QwenUsageError: Error, Sendable, Equatable {
    case missingCredential
    case unauthorized
    case invalidResponse
    case apiKeyUnavailableInRegion
}

/// Region metadata intentionally stays in one small primary declaration so
/// W8 can reuse it when appending Qwen's cookie strategy.
nonisolated enum QwenAPIRegion: String, CaseIterable, Sendable {
    case international = "intl"
    case chinaMainland = "cn"

    var gatewayBaseURL: URL {
        switch self {
        case .international:
            URL(string: "https://modelstudio.console.alibabacloud.com")!
        case .chinaMainland:
            URL(string: "https://bailian.console.aliyun.com")!
        }
    }

    var dashboardURL: URL {
        switch self {
        case .international:
            URL(
                string:
                    "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=coding-plan#/efm/coding_plan"
            )!
        case .chinaMainland:
            URL(
                string:
                    "https://bailian.console.aliyun.com/cn-beijing/?tab=model#/efm/coding_plan"
            )!
        }
    }

    var currentRegionID: String {
        switch self {
        case .international: "ap-southeast-1"
        case .chinaMainland: "cn-beijing"
        }
    }

    var commodityCode: String {
        switch self {
        case .international: "sfm_codingplan_public_intl"
        case .chinaMainland: "sfm_codingplan_public_cn"
        }
    }

    var quotaURL: URL {
        var components = URLComponents(
            url: gatewayBaseURL.appendingPathComponent("data/api.json"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(
                name: "action",
                value: "zeldaEasy.broadscope-bailian.codingPlan.queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "product", value: "broadscope-bailian"),
            URLQueryItem(name: "api", value: "queryCodingPlanInstanceInfoV2"),
            URLQueryItem(name: "currentRegionId", value: currentRegionID),
        ]
        return components.url!
    }

    var requestBody: Data {
        let object: [String: Any] = [
            "queryCodingPlanInstanceInfoRequest": ["commodityCode": commodityCode]
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }
}

/// Per-provider region preference. W8 can use the same store when it appends
/// cookie authentication without restructuring the descriptor.
nonisolated enum QwenRegionPreference {
    static let defaultsKey = "usageProviderRegion.qwen"

    static func load(suiteName: String? = nil) -> QwenAPIRegion {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        guard let rawValue = defaults.string(forKey: defaultsKey),
            let region = QwenAPIRegion(rawValue: rawValue)
        else { return .international }
        return region
    }

    static func save(_ region: QwenAPIRegion, suiteName: String? = nil) {
        let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        defaults.set(region.rawValue, forKey: defaultsKey)
    }
}

nonisolated struct QwenAPIKeyStrategy: UsageFetchStrategy {
    let id = "qwen.api-key"

    private let region: QwenAPIRegion
    private let environmentCredential: String?

    init(
        region: QwenAPIRegion = QwenRegionPreference.load(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.region = region
        environmentCredential =
            [
                "ALIBABA_CODING_PLAN_API_KEY", "ALIBABA_QWEN_API_KEY", "DASHSCOPE_API_KEY",
            ].lazy.compactMap { Self.cleaned(environment[$0]) }.first
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let apiKey = credential(in: context) else {
            throw QwenUsageError.missingCredential
        }

        var request = URLRequest(url: region.quotaURL)
        request.httpMethod = "POST"
        request.httpBody = region.requestBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiKey, forHTTPHeaderField: "X-DashScope-API-Key")
        request.setValue("Rafu", forHTTPHeaderField: "User-Agent")
        request.setValue(region.gatewayBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(region.dashboardURL.absoluteString, forHTTPHeaderField: "Referer")

        let data: Data
        do {
            (data, _) = try await context.http.send(request, provider: .qwen)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw QwenUsageError.unauthorized
        }
        return try Self.parse(data, now: context.now)
    }

    func shouldFallback(on error: Error) -> Bool {
        (error as? QwenUsageError) == .apiKeyUnavailableInRegion
    }

    static func parse(_ data: Data, now: Date) throws -> UsageSnapshot {
        guard let response = try? JSONDecoder().decode(QwenCodingPlanResponse.self, from: data)
        else {
            throw QwenUsageError.invalidResponse
        }

        if let statusCode = response.effectiveStatusCode,
            statusCode != 0, statusCode != 200
        {
            if statusCode == 401 || statusCode == 403 {
                throw QwenUsageError.unauthorized
            }
            throw QwenUsageError.invalidResponse
        }

        let errorText = [response.code, response.status, response.message, response.msg]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if errorText.contains("needlogin") || errorText.contains("need login")
            || errorText.contains("log in") || errorText.contains("login")
            || errorText.contains("console session")
            || errorText.contains("api key mode may be unavailable")
        {
            throw QwenUsageError.apiKeyUnavailableInRegion
        }

        guard let payload = response.data else { throw QwenUsageError.invalidResponse }
        let selectedInstance =
            payload.codingPlanInstanceInfos?.first(where: { instance in
                guard let status = instance.status?.uppercased() else { return false }
                return status == "VALID" || status == "ACTIVE"
            }) ?? payload.codingPlanInstanceInfos?.first
        guard let quota = selectedInstance?.codingPlanQuotaInfo ?? payload.codingPlanQuotaInfo
        else {
            throw QwenUsageError.invalidResponse
        }

        var windows: [UsageWindow] = []
        if let window = usageWindow(
            label: "5h",
            used: quota.fiveHourUsed,
            total: quota.fiveHourTotal,
            resetsAt: normalizedFiveHourReset(quota.fiveHourReset?.date, now: now))
        {
            windows.append(window)
        }
        if let window = usageWindow(
            label: "7d",
            used: quota.weeklyUsed,
            total: quota.weeklyTotal,
            resetsAt: quota.weeklyReset?.date)
        {
            windows.append(window)
        }
        if let window = usageWindow(
            label: "monthly",
            used: quota.monthlyUsed,
            total: quota.monthlyTotal,
            resetsAt: quota.monthlyReset?.date)
        {
            windows.append(window)
        }

        guard !windows.isEmpty else { throw QwenUsageError.invalidResponse }
        let planName =
            selectedInstance?.planName ?? payload.codingPlanInstanceInfos?.first?.planName
        return UsageSnapshot(
            providerID: .qwen,
            windows: windows,
            costLine: nil,
            identity: planName?.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func usageWindow(
        label: String,
        used: QwenMetric?,
        total: QwenMetric?,
        resetsAt: Date?
    ) -> UsageWindow? {
        guard let used = used?.value, let total = total?.value, total > 0 else { return nil }
        let normalizedUsed = min(total, max(0, used))
        return UsageWindow(
            label: label,
            percent: normalizedUsed / total * 100,
            tokens: nil,
            resetsAt: resetsAt)
    }

    private static func normalizedFiveHourReset(_ raw: Date?, now: Date) -> Date? {
        guard let raw else { return nil }
        if raw.timeIntervalSince(now) >= 60 { return raw }
        let shifted = raw.addingTimeInterval(5 * 60 * 60)
        return shifted.timeIntervalSince(now) >= 60
            ? shifted
            : now.addingTimeInterval(5 * 60 * 60)
    }

    private func credential(in context: UsageFetchContext) -> String? {
        if let stored = Self.cleaned(context.credential(.qwen)) {
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

private nonisolated struct QwenCodingPlanResponse: Decodable, Sendable {
    let data: QwenCodingPlanPayload?
    let statusCode: Int?
    let statusCodeSnake: Int?
    let code: String?
    let status: String?
    let message: String?
    let msg: String?

    var effectiveStatusCode: Int? { statusCode ?? statusCodeSnake ?? Int(code ?? "") }

    private enum CodingKeys: String, CodingKey {
        case data
        case statusCode
        case statusCodeSnake = "status_code"
        case code
        case status
        case message
        case msg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decodeIfPresent(QwenCodingPlanPayload.self, forKey: .data)
        statusCode = try Self.decodeIntIfPresent(container, forKey: .statusCode)
        statusCodeSnake = try Self.decodeIntIfPresent(container, forKey: .statusCodeSnake)
        code = try Self.decodeStringIfPresent(container, forKey: .code)
        status = try Self.decodeStringIfPresent(container, forKey: .status)
        message = try Self.decodeStringIfPresent(container, forKey: .message)
        msg = try Self.decodeStringIfPresent(container, forKey: .msg)
    }

    private static func decodeIntIfPresent(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) { return Int(raw) }
        return nil
    }

    private static func decodeStringIfPresent(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

private nonisolated struct QwenCodingPlanPayload: Decodable, Sendable {
    let codingPlanInstanceInfos: [QwenCodingPlanInstance]?
    let codingPlanQuotaInfo: QwenCodingPlanQuota?
}

private nonisolated struct QwenCodingPlanInstance: Decodable, Sendable {
    let planName: String?
    let status: String?
    let codingPlanQuotaInfo: QwenCodingPlanQuota?
}

private nonisolated struct QwenCodingPlanQuota: Decodable, Sendable {
    let fiveHourUsed: QwenMetric?
    let fiveHourTotal: QwenMetric?
    let fiveHourReset: QwenTimestamp?
    let weeklyUsed: QwenMetric?
    let weeklyTotal: QwenMetric?
    let weeklyReset: QwenTimestamp?
    let monthlyUsed: QwenMetric?
    let monthlyTotal: QwenMetric?
    let monthlyReset: QwenTimestamp?

    private enum CodingKeys: String, CodingKey {
        case per5HourUsedQuota
        case perFiveHourUsedQuota
        case per5HourTotalQuota
        case perFiveHourTotalQuota
        case per5HourQuotaNextRefreshTime
        case perFiveHourQuotaNextRefreshTime
        case perWeekUsedQuota
        case perWeekTotalQuota
        case perWeekQuotaNextRefreshTime
        case perBillMonthUsedQuota
        case perMonthUsedQuota
        case perBillMonthTotalQuota
        case perMonthTotalQuota
        case perBillMonthQuotaNextRefreshTime
        case perMonthQuotaNextRefreshTime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fiveHourUsed =
            try container.decodeIfPresent(QwenMetric.self, forKey: .per5HourUsedQuota)
            ?? container.decodeIfPresent(QwenMetric.self, forKey: .perFiveHourUsedQuota)
        fiveHourTotal =
            try container.decodeIfPresent(QwenMetric.self, forKey: .per5HourTotalQuota)
            ?? container.decodeIfPresent(QwenMetric.self, forKey: .perFiveHourTotalQuota)
        fiveHourReset =
            try container.decodeIfPresent(
                QwenTimestamp.self, forKey: .per5HourQuotaNextRefreshTime)
            ?? container.decodeIfPresent(
                QwenTimestamp.self, forKey: .perFiveHourQuotaNextRefreshTime)
        weeklyUsed = try container.decodeIfPresent(QwenMetric.self, forKey: .perWeekUsedQuota)
        weeklyTotal = try container.decodeIfPresent(QwenMetric.self, forKey: .perWeekTotalQuota)
        weeklyReset = try container.decodeIfPresent(
            QwenTimestamp.self, forKey: .perWeekQuotaNextRefreshTime)
        monthlyUsed =
            try container.decodeIfPresent(
                QwenMetric.self, forKey: .perBillMonthUsedQuota)
            ?? container.decodeIfPresent(QwenMetric.self, forKey: .perMonthUsedQuota)
        monthlyTotal =
            try container.decodeIfPresent(
                QwenMetric.self, forKey: .perBillMonthTotalQuota)
            ?? container.decodeIfPresent(QwenMetric.self, forKey: .perMonthTotalQuota)
        monthlyReset =
            try container.decodeIfPresent(
                QwenTimestamp.self, forKey: .perBillMonthQuotaNextRefreshTime)
            ?? container.decodeIfPresent(QwenTimestamp.self, forKey: .perMonthQuotaNextRefreshTime)
    }
}

private nonisolated struct QwenMetric: Decodable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let raw = try? container.decode(String.self) {
            value = Double(raw)
        } else {
            value = nil
        }
    }
}

private nonisolated struct QwenTimestamp: Decodable, Sendable {
    let date: Date?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            date = Date(timeIntervalSince1970: seconds)
            return
        }
        guard let raw = try? container.decode(String.self) else {
            date = nil
            return
        }
        if let number = Double(raw) {
            let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
            date = Date(timeIntervalSince1970: seconds)
            return
        }
        if let parsed = UsageDateParsing.parseISO8601Fractional(raw) {
            date = parsed
            return
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = raw.count > 16 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
        date = formatter.date(from: raw)
    }
}
