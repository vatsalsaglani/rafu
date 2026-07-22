// Adapted from CodexBar's FactorySettingsReader.swift,
// FactoryStatusProbe.swift, and FactoryProviderDescriptor.swift at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum FactoryDroidUsageError: Error, Sendable, Equatable {
    case missingCredential
    case unauthorized
    case invalidResponse
    case noUsage
}

nonisolated struct FactoryDroidAPIKeyStrategy: UsageFetchStrategy {
    let id = "factory-droid.api-key"

    private let environmentCredential: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentCredential = FactoryDroidAuth.cleanedCredential(environment["FACTORY_API_KEY"])
    }

    @concurrent
    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    @concurrent
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let credential = credential(in: context) else {
            throw FactoryDroidUsageError.missingCredential
        }
        return try await FactoryDroidUsageClient.fetch(
            auth: FactoryDroidRequestAuth(cookieHeader: nil, bearerToken: credential),
            context: context)
    }

    /// An authenticated failure must not silently switch to a browser account.
    func shouldFallback(on error: Error) -> Bool { false }

    private func credential(in context: UsageFetchContext) -> String? {
        if let stored = FactoryDroidAuth.cleanedCredential(context.credential(.factoryDroid)) {
            return stored
        }
        if let environmentCredential { return environmentCredential }
        return context.readFile(".factory/.env")
            .flatMap(FactoryDroidAuth.apiKeyFromDotEnv)
    }
}

nonisolated struct FactoryDroidCookieStrategy: UsageFetchStrategy {
    let id = "factory-droid.cookie"

    @concurrent
    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        FactoryDroidAuth.normalizedCookieHeader(context.cookieHeader(.factoryDroid)) != nil
    }

    @concurrent
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard
            let cookieHeader = FactoryDroidAuth.normalizedCookieHeader(
                context.cookieHeader(.factoryDroid))
        else { throw FactoryDroidUsageError.missingCredential }
        let bearer = FactoryDroidAuth.cookieValue(named: "access-token", in: cookieHeader)
        return try await FactoryDroidUsageClient.fetch(
            auth: FactoryDroidRequestAuth(cookieHeader: cookieHeader, bearerToken: bearer),
            context: context)
    }

    func shouldFallback(on error: Error) -> Bool { false }
}

private nonisolated enum FactoryDroidAuth {
    static let maximumCredentialBytes = 16 * 1_024
    static let allowedCookieNames = Set(UsageCookieImportCatalog.factoryDroidCookieNames)

    static func cleanedCredential(_ raw: String?) -> String? {
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

    static func apiKeyFromDotEnv(_ contents: String) -> String? {
        guard contents.utf8.count <= maximumCredentialBytes else { return nil }
        for rawLine in contents.split(whereSeparator: \Character.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
            guard key == "FACTORY_API_KEY" else { continue }
            return cleanedCredential(String(line[line.index(after: separator)...]))
        }
        return nil
    }

    static func normalizedCookieHeader(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty,
            raw.utf8.count <= maximumCredentialBytes,
            !raw.contains("\r"),
            !raw.contains("\n")
        else { return nil }

        let pairs = raw.split(separator: ";").compactMap { segment -> String? in
            let pair = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { return nil }
            let name = String(pair[..<separator])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pair[pair.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowedCookieNames.contains(name), !value.isEmpty,
                value.unicodeScalars.allSatisfy({ scalar in
                    scalar.value >= 0x20 && scalar.value != 0x7F && scalar != ";"
                })
            else { return nil }
            return "\(name)=\(value)"
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.joined(separator: "; ")
    }

    static func cookieValue(named name: String, in header: String) -> String? {
        for segment in header.split(separator: ";") {
            let pair = segment.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = pair.firstIndex(of: "=") else { continue }
            if pair[..<separator].trimmingCharacters(in: .whitespacesAndNewlines) == name {
                return String(pair[pair.index(after: separator)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

private nonisolated struct FactoryDroidRequestAuth: Sendable {
    let cookieHeader: String?
    let bearerToken: String?
}

private nonisolated enum FactoryDroidUsageClient {
    private static let baseURL = URL(string: "https://api.factory.ai")!
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    static func fetch(
        auth: FactoryDroidRequestAuth, context: UsageFetchContext
    ) async throws -> UsageSnapshot {
        let authData = try await send(
            path: "/api/app/auth/me", auth: auth, context: context)
        guard let authInfo = decode(AuthResponse.self, data: authData) else {
            throw FactoryDroidUsageError.invalidResponse
        }

        if let billing = try await fetchBillingLimits(auth: auth, context: context),
            billing.usesTokenRateLimitsBilling,
            let standard = billing.limits?.standard
        {
            return try makeBillingSnapshot(
                standard: standard,
                balanceCents: billing.extraUsageBalanceCents,
                authInfo: authInfo,
                now: context.now)
        }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/organization/subscription/usage"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "useCache", value: "true")]
        if let userID = cleaned(authInfo.userProfile?.id) {
            components?.queryItems?.append(URLQueryItem(name: "userId", value: userID))
        }
        guard let usageURL = components?.url else {
            throw FactoryDroidUsageError.invalidResponse
        }
        let usageData = try await send(url: usageURL, auth: auth, context: context)
        guard let usage = decode(LegacyUsageResponse.self, data: usageData) else {
            throw FactoryDroidUsageError.invalidResponse
        }
        return try makeLegacySnapshot(usage: usage, authInfo: authInfo)
    }

    private static func fetchBillingLimits(
        auth: FactoryDroidRequestAuth, context: UsageFetchContext
    ) async throws -> BillingLimitsResponse? {
        do {
            let data = try await send(
                path: "/api/billing/limits", auth: auth, context: context)
            return decode(BillingLimitsResponse.self, data: data)
        } catch FactoryDroidUsageError.unauthorized {
            throw FactoryDroidUsageError.unauthorized
        } catch let error as UsageHTTPError {
            try Task.checkCancellation()
            if case .rateLimited = error { throw error }
            return nil
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // The structured limits endpoint is an enrichment over Factory's
            // legacy organization usage endpoint.
            return nil
        }
    }

    private static func send(
        path: String, auth: FactoryDroidRequestAuth, context: UsageFetchContext
    ) async throws -> Data {
        try await send(
            url: baseURL.appendingPathComponent(path), auth: auth, context: context)
    }

    private static func send(
        url: URL, auth: FactoryDroidRequestAuth, context: UsageFetchContext
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://app.factory.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://app.factory.ai/", forHTTPHeaderField: "Referer")
        request.setValue("web-app", forHTTPHeaderField: "x-factory-client")
        if let cookieHeader = auth.cookieHeader {
            request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let bearerToken = auth.bearerToken {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (data, _) = try await context.http.send(request, provider: .factoryDroid)
            guard !data.isEmpty, data.count <= maximumResponseBytes else {
                throw FactoryDroidUsageError.invalidResponse
            }
            try Task.checkCancellation()
            return data
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw FactoryDroidUsageError.unauthorized
        }
    }

    private static func makeBillingSnapshot(
        standard: LimitPool,
        balanceCents: Int?,
        authInfo: AuthResponse,
        now: Date
    ) throws -> UsageSnapshot {
        let windows = [
            makeBillingWindow(label: "5h", source: standard.fiveHour, now: now),
            makeBillingWindow(label: "7d", source: standard.weekly, now: now),
            makeBillingWindow(label: "monthly", source: standard.monthly, now: now),
        ].compactMap { $0 }
        let costLine: String?
        if let balanceCents, balanceCents > 0 {
            costLine = String(
                format: "Extra usage balance $%.2f",
                locale: Locale(identifier: "en_US_POSIX"),
                Double(balanceCents) / 100)
        } else {
            costLine = nil
        }
        let snapshot = UsageSnapshot(
            providerID: .factoryDroid,
            windows: windows,
            costLine: costLine,
            identity: identity(authInfo))
        guard snapshot.renderable else { throw FactoryDroidUsageError.noUsage }
        return snapshot
    }

    private static func makeBillingWindow(
        label: String, source: BillingWindow, now: Date
    ) -> UsageWindow? {
        guard source.usedPercent.isFinite, source.usedPercent >= 0 else { return nil }
        let reset: Date?
        if let seconds = source.secondsRemaining, seconds.isFinite, seconds > 0 {
            reset = now.addingTimeInterval(seconds)
        } else if let end = source.windowEnd?.date, end > now {
            reset = end
        } else {
            reset = nil
        }
        let effectivePercent =
            reset == nil && source.windowEnd != nil && source.secondsRemaining == nil
            ? 0
            : min(100, source.usedPercent)
        return UsageWindow(
            label: label, percent: effectivePercent, tokens: nil, resetsAt: reset)
    }

    private static func makeLegacySnapshot(
        usage response: LegacyUsageResponse, authInfo: AuthResponse
    ) throws -> UsageSnapshot {
        guard let usage = response.usage else { throw FactoryDroidUsageError.noUsage }
        let reset = usage.endDate.flatMap(millisecondsDate)
        var windows: [UsageWindow] = []
        if let window = makeLegacyWindow(label: "standard", source: usage.standard, reset: reset) {
            windows.append(window)
        }
        if let window = makeLegacyWindow(label: "premium", source: usage.premium, reset: reset) {
            windows.append(window)
        }
        guard !windows.isEmpty else { throw FactoryDroidUsageError.noUsage }
        return UsageSnapshot(
            providerID: .factoryDroid,
            windows: windows,
            costLine: nil,
            identity: identity(authInfo))
    }

    private static func makeLegacyWindow(
        label: String, source: TokenUsage?, reset: Date?
    ) -> UsageWindow? {
        guard let source else { return nil }
        let percent: Double?
        if let ratio = source.usedRatio, ratio.isFinite, (0...1).contains(ratio) {
            percent = ratio * 100
        } else if let used = source.userTokens, used >= 0,
            let allowance = source.totalAllowance,
            (1...1_000_000_000_000).contains(allowance)
        {
            percent = min(100, Double(used) / Double(allowance) * 100)
        } else {
            percent = nil
        }
        guard let percent else { return nil }
        return UsageWindow(
            label: label, percent: percent, tokens: nil, resetsAt: reset)
    }

    private static func identity(_ auth: AuthResponse) -> String? {
        cleaned(auth.userProfile?.email)
            ?? cleaned(auth.organization?.name)
            ?? cleaned(auth.organization?.subscription?.orbSubscription?.plan?.name)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else { return nil }
        return value
    }

    private static func millisecondsDate(_ value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value) / 1_000)
    }

    private static func decode<T: Decodable>(_ type: T.Type, data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    private struct AuthResponse: Decodable, Sendable {
        let organization: Organization?
        let userProfile: UserProfile?
    }

    private struct UserProfile: Decodable, Sendable {
        let id: String?
        let email: String?
    }

    private struct Organization: Decodable, Sendable {
        let name: String?
        let subscription: Subscription?
    }

    private struct Subscription: Decodable, Sendable {
        let factoryTier: String?
        let orbSubscription: OrbSubscription?
    }

    private struct OrbSubscription: Decodable, Sendable {
        let plan: Plan?
    }

    private struct Plan: Decodable, Sendable {
        let name: String?
    }

    private struct BillingLimitsResponse: Decodable, Sendable {
        let usesTokenRateLimitsBilling: Bool
        let limits: TokenRateLimits?
        let extraUsageBalanceCents: Int?

        private enum CodingKeys: String, CodingKey {
            case usesTokenRateLimitsBilling
            case limits
            case extraUsageBalanceCents
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            usesTokenRateLimitsBilling =
                try container.decodeIfPresent(Bool.self, forKey: .usesTokenRateLimitsBilling)
                ?? false
            limits = try container.decodeIfPresent(TokenRateLimits.self, forKey: .limits)
            extraUsageBalanceCents = try container.decodeIfPresent(
                Int.self, forKey: .extraUsageBalanceCents)
        }
    }

    private struct TokenRateLimits: Decodable, Sendable {
        let standard: LimitPool?
    }

    private struct LimitPool: Decodable, Sendable {
        let fiveHour: BillingWindow
        let weekly: BillingWindow
        let monthly: BillingWindow
    }

    private struct BillingWindow: Decodable, Sendable {
        let usedPercent: Double
        let windowEnd: FlexibleDate?
        let secondsRemaining: Double?
    }

    private struct FlexibleDate: Decodable, Sendable {
        let date: Date

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let number = try? container.decode(Double.self), number.isFinite {
                date = Date(timeIntervalSince1970: number > 1e12 ? number / 1_000 : number)
                return
            }
            let string = try container.decode(String.self)
            if let number = Double(string), number.isFinite {
                date = Date(timeIntervalSince1970: number > 1e12 ? number / 1_000 : number)
                return
            }
            guard let parsed = UsageDateParsing.parseISO8601Fractional(string) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid Factory date")
            }
            date = parsed
        }
    }

    private struct LegacyUsageResponse: Decodable, Sendable {
        let usage: LegacyUsage?
    }

    private struct LegacyUsage: Decodable, Sendable {
        let endDate: Int64?
        let standard: TokenUsage?
        let premium: TokenUsage?
    }

    private struct TokenUsage: Decodable, Sendable {
        let userTokens: Int64?
        let totalAllowance: Int64?
        let usedRatio: Double?
    }
}

nonisolated enum FactoryDroidProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .factoryDroid,
        displayName: "Factory Droid",
        authPattern: .cookieImport,
        disclosure:
            "Uses a Rafu key, FACTORY_API_KEY, or ~/.factory/.env first; otherwise sends only cached factory.ai/app.factory.ai/auth.factory.ai session cookies to api.factory.ai to fetch Droid quota fields. WorkOS refresh tokens are never imported or refreshed.",
        defaultEnabled: false,
        makeStrategies: { _ in
            [FactoryDroidAPIKeyStrategy(), FactoryDroidCookieStrategy()]
        }
    )
}
