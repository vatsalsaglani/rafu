import Foundation

/// Adapted from CodexBar's `AlibabaCodingPlanAPIRegion.swift`,
/// `AlibabaCodingPlanUsageFetcher.swift`, `AlibabaCodingPlanUsageSnapshot.swift`,
/// and `AlibabaCodingPlanSettingsReader.swift` at commit
/// cc8da27cec92029a6435bfee4a703a719290234e (MIT license).
///
/// W4 implements Alibaba Coding Plan's API-key path. W8 appends the Alibaba
/// Token Plan cookie path without restructuring the existing key strategy.
nonisolated enum QwenProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .qwen,
        displayName: "Qwen",
        authPattern: .apiKey,
        disclosure:
            "Sends only the Alibaba Qwen API key or browser cookie you provide to modelstudio.console.alibabacloud.com or bailian.console.aliyun.com, according to your region preference, to fetch Coding Plan or Token Plan quota metrics.",
        defaultEnabled: false,
        makeStrategies: { _ in [QwenAPIKeyStrategy(), QwenCookieStrategy()] }
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

    var tokenPlanDashboardURL: URL {
        switch self {
        case .international:
            URL(
                string:
                    "https://modelstudio.console.alibabacloud.com/ap-southeast-1/?tab=plan#/efm/subscription/token-plan"
            )!
        case .chinaMainland:
            URL(
                string:
                    "https://bailian.console.aliyun.com/cn-beijing?tab=plan#/efm/subscription/token-plan"
            )!
        }
    }

    var tokenPlanProductCode: String {
        switch self {
        case .international: "sfm_tokenplanteams_dp_intl"
        case .chinaMainland: "sfm_tokenplanteams_dp_cn"
        }
    }

    var tokenPlanQuotaURL: URL {
        var components = URLComponents(
            url: gatewayBaseURL.appendingPathComponent("data/api.json"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "action", value: "GetSubscriptionSummary"),
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "_tag", value: ""),
        ]
        return components.url!
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

// MARK: - Alibaba Token Plan cookie path (W8)

/// Adapted from CodexBar's `AlibabaTokenPlanAPIRegion.swift`,
/// `AlibabaTokenPlanUsageFetcher.swift`, `AlibabaTokenPlanUsageSnapshot.swift`,
/// `AlibabaTokenPlanCookieHeader.swift`, and
/// `AlibabaCodingPlanCookieImporter.swift` at commit
/// cc8da27cec92029a6435bfee4a703a719290234e (MIT license).
nonisolated struct QwenCookieStrategy: UsageFetchStrategy {
    let id = "qwen.cookie"

    /// The upstream importer reads all cookies for this bounded domain set,
    /// then validates `login_aliyunid_ticket` plus one account cookie. W1's
    /// import call should therefore use `names: nil`, not a widened jar read.
    static let cookieImportDomains = [
        "bailian-singapore-cs.alibabacloud.com",
        "bailian-cs.console.aliyun.com",
        "bailian-beijing-cs.aliyuncs.com",
        "modelstudio.console.alibabacloud.com",
        "bailian.console.aliyun.com",
        "free.aliyun.com",
        "account.aliyun.com",
        "signin.aliyun.com",
        "passport.alibabacloud.com",
        "console.alibabacloud.com",
        "console.aliyun.com",
        "alibabacloud.com",
        "aliyun.com",
    ]

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let region: QwenAPIRegion

    init(region: QwenAPIRegion = QwenRegionPreference.load()) {
        self.region = region
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let credential = Self.credential(in: context) else {
            throw QwenUsageError.missingCredential
        }

        var request = URLRequest(url: region.tokenPlanQuotaURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = Self.requestBody(
            region: region, securityToken: credential.valuesByName["sec_token"])
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(credential.header, forHTTPHeaderField: "Cookie")
        if let csrf = credential.valuesByName["login_aliyunid_csrf"]
            ?? credential.valuesByName["csrf"]
        {
            request.setValue(csrf, forHTTPHeaderField: "x-xsrf-token")
            request.setValue(csrf, forHTTPHeaderField: "x-csrf-token")
        }
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(region.gatewayBaseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(
            region.tokenPlanDashboardURL.absoluteString,
            forHTTPHeaderField: "Referer")

        let data: Data
        do {
            (data, _) = try await context.http.send(request, provider: .qwen)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw QwenUsageError.unauthorized
        }
        return try Self.parse(data, now: context.now)
    }

    func shouldFallback(on _: Error) -> Bool { false }

    static func parse(_ data: Data, now _: Date) throws -> UsageSnapshot {
        guard !data.isEmpty else { throw QwenUsageError.invalidResponse }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            if let text = String(data: data, encoding: .utf8)?.lowercased(),
                text.contains("<html"),
                text.contains("login") || text.contains("sign in") || text.contains("signin")
            {
                throw QwenUsageError.unauthorized
            }
            throw QwenUsageError.invalidResponse
        }
        guard let root = expandedRoot(object) else { throw QwenUsageError.invalidResponse }
        try validateStatus(root)

        let summary = dictionary(forKeys: ["Data", "data"], in: root) ?? root
        let total = double(forKeys: totalQuotaKeys, in: summary)
        let remaining = double(forKeys: remainingQuotaKeys, in: summary)
        let explicitUsed = double(forKeys: usedQuotaKeys, in: summary)
        let used =
            explicitUsed
            ?? total.flatMap { total in
                remaining.map { max(0, total - $0) }
            }

        guard let total, total > 0, let used, used >= 0,
            remaining.map({ $0 >= 0 }) ?? true
        else { throw QwenUsageError.invalidResponse }

        let normalizedUsed = min(total, used)
        let reset =
            date(forKeys: resetDateKeys, in: summary)
            ?? date(forKeys: resetDateKeys, in: root)
        let totalCount = double(forKeys: subscriptionCountKeys, in: summary)
        let suppliedPlan = string(forKeys: planNameKeys, in: summary)
        let identity = suppliedPlan ?? ((totalCount ?? 0) > 0 || total > 0 ? "TOKEN PLAN" : nil)

        return UsageSnapshot(
            providerID: .qwen,
            windows: [
                UsageWindow(
                    label: "monthly",
                    percent: normalizedUsed / total * 100,
                    tokens: nil,
                    resetsAt: reset)
            ],
            costLine: quotaDetail(used: used, total: total, remaining: remaining),
            identity: identity)
    }

    private struct CookieCredential {
        let header: String
        let valuesByName: [String: String]
    }

    private static let accountCookieNames = [
        "login_aliyunid_pk", "login_current_pk", "login_aliyunid",
    ]

    private static func credential(in context: UsageFetchContext) -> CookieCredential? {
        guard
            let header = context.cookieHeader(.qwen)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !header.isEmpty
        else { return nil }
        let values = cookieValues(in: header)
        guard values["login_aliyunid_ticket"] != nil,
            accountCookieNames.contains(where: { values[$0] != nil })
        else { return nil }
        return CookieCredential(header: header, valuesByName: values)
    }

    private static func cookieValues(in header: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let pieces = pair.split(separator: "=", maxSplits: 1)
            guard pieces.count == 2 else { continue }
            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else { continue }
            values[name] = value
        }
        return values
    }

    private static func requestBody(region: QwenAPIRegion, securityToken: String?) -> Data {
        let paramsData = try? JSONSerialization.data(
            withJSONObject: ["ProductCode": region.tokenPlanProductCode])
        let params = paramsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        var items = [
            URLQueryItem(name: "product", value: "BssOpenAPI-V3"),
            URLQueryItem(name: "action", value: "GetSubscriptionSummary"),
            URLQueryItem(name: "params", value: params),
            URLQueryItem(name: "region", value: region.currentRegionID),
        ]
        if let securityToken, !securityToken.isEmpty {
            items.append(URLQueryItem(name: "sec_token", value: securityToken))
        }
        var components = URLComponents()
        components.queryItems = items
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    /// Expands only the source's known `successResponse.body` wrapper. This
    /// avoids retaining or recursively walking arbitrary response content.
    private static func expandedRoot(_ object: Any) -> [String: Any]? {
        guard let root = object as? [String: Any] else { return nil }
        for key in ["successResponse", "success_response"] {
            guard let wrapper = root[key] else { continue }
            if let dictionary = expandedDictionary(wrapper) {
                if let body = dictionary["body"], let expanded = expandedDictionary(body) {
                    return expanded
                }
                return dictionary
            }
        }
        return root
    }

    private static func expandedDictionary(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        guard let string = value as? String, string.utf8.count <= 1_048_576,
            let data = string.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }

    private static func validateStatus(_ root: [String: Any]) throws {
        for key in ["successResponse", "success_response"] {
            if let success = parsedBool(root[key]), !success {
                if loginRequired(root) { throw QwenUsageError.unauthorized }
                throw QwenUsageError.invalidResponse
            }
        }
        if let success = bool(forKeys: ["Success", "success"], in: root), !success {
            if loginRequired(root) { throw QwenUsageError.unauthorized }
            throw QwenUsageError.invalidResponse
        }
        if let status = integer(forKeys: ["statusCode", "status_code", "Code", "code"], in: root),
            status != 0, status != 200
        {
            if status == 401 || status == 403 || loginRequired(root) {
                throw QwenUsageError.unauthorized
            }
            throw QwenUsageError.invalidResponse
        }
        if loginRequired(root) { throw QwenUsageError.unauthorized }
    }

    private static func loginRequired(_ root: [String: Any]) -> Bool {
        let combined = [
            string(forKeys: ["Code", "code", "status", "statusCode"], in: root),
            string(forKeys: ["Message", "message", "msg", "statusMessage"], in: root),
        ]
        .compactMap { $0?.lowercased() }
        .joined(separator: " ")
        return combined.contains("needlogin") || combined.contains("login")
            || combined.contains("postonlyortokenerror") || combined.contains("tokenerror")
            || combined.contains("request has expired") || combined.contains("refresh page")
            || combined.contains("请求已经过期")
    }

    private static let planNameKeys = [
        "planName", "plan_name", "packageName", "package_name", "commodityName",
        "commodity_name", "instanceName", "instance_name", "displayName", "display_name",
        "ProductName", "productName", "name", "title", "planType", "plan_type",
    ]
    private static let usedQuotaKeys = [
        "usedQuota", "used_quota", "usedCredits", "usedCredit", "consumedCredits", "usage",
        "used", "usedAmount", "consumeAmount", "usedValue", "UsedValue", "consumedValue",
        "ConsumedValue",
    ]
    private static let totalQuotaKeys = [
        "totalQuota", "total_quota", "totalCredits", "totalCredit", "quota", "creditLimit",
        "creditsTotal", "monthlyTotalQuota", "amount", "totalValue", "TotalValue",
    ]
    private static let remainingQuotaKeys = [
        "remainingQuota", "remainQuota", "remainingCredits", "remainingCredit",
        "availableCredits", "balance", "remaining", "availableAmount", "remainAmount",
        "totalSurplusValue", "TotalSurplusValue", "surplusValue", "SurplusValue",
    ]
    private static let subscriptionCountKeys = [
        "totalCount", "TotalCount", "subscriptionTotalNumber", "SubscriptionTotalNumber",
    ]
    private static let resetDateKeys = [
        "nextRefreshTime", "resetTime", "periodEndTime", "billingCycleEnd",
        "billCycleEndTime", "expireTime", "expirationTime", "endTime", "validEndTime",
        "instanceEndTime", "nearestExpireDate", "NearestExpireDate",
    ]

    private static func dictionary(
        forKeys keys: [String], in dictionary: [String: Any]
    ) -> [String: Any]? {
        keys.lazy.compactMap { dictionary[$0] as? [String: Any] }.first
    }

    private static func string(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let value = dictionary[key] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func double(forKeys keys: [String], in dictionary: [String: Any]) -> Double? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber { return number.doubleValue }
            if let raw = dictionary[key] as? String {
                let cleaned = raw.replacingOccurrences(of: ",", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let value = Double(cleaned) { return value }
            }
        }
        return nil
    }

    private static func integer(forKeys keys: [String], in dictionary: [String: Any]) -> Int? {
        for key in keys {
            if let number = dictionary[key] as? NSNumber { return number.intValue }
            if let raw = dictionary[key] as? String, let value = Int(raw) { return value }
        }
        return nil
    }

    private static func bool(forKeys keys: [String], in dictionary: [String: Any]) -> Bool? {
        for key in keys {
            if let value = parsedBool(dictionary[key]) { return value }
        }
        return nil
    }

    private static func parsedBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let number = raw as? NSNumber { return number.boolValue }
        if let value = raw as? String {
            switch value.lowercased() {
            case "true", "1", "yes", "active", "valid", "normal": return true
            case "false", "0", "no", "inactive", "invalid", "expired": return false
            default: return nil
            }
        }
        return nil
    }

    private static func date(forKeys keys: [String], in dictionary: [String: Any]) -> Date? {
        for key in keys {
            if let number = double(forKeys: [key], in: dictionary) {
                let seconds = number > 1_000_000_000_000 ? number / 1_000 : number
                if seconds > 1_000_000_000 { return Date(timeIntervalSince1970: seconds) }
            }
            if let raw = string(forKeys: [key], in: dictionary),
                let value = UsageDateParsing.parseISO8601Fractional(raw)
            {
                return value
            }
        }
        return nil
    }

    private static func quotaDetail(
        used: Double?, total: Double?, remaining: Double?
    ) -> String? {
        if let used, let total, total > 0 {
            return "\(format(used)) / \(format(total)) credits used"
        }
        if let remaining, let total, total > 0 {
            return "\(format(remaining)) / \(format(total)) credits left"
        }
        if let remaining { return "\(format(remaining)) credits left" }
        return nil
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }
}
