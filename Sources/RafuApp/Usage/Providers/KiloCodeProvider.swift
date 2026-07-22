// Provider mechanism adapted from CodexBar at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum KiloCodeProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .kiloCode,
        displayName: "Kilo Code",
        authPattern: .apiKey,
        disclosure:
            "Reads the Kilo CLI token in ~/.local/share/kilo/auth.json first, then may use the Kilo API key you provide (or KILO_API_KEY); sends only the selected bearer token to app.kilo.ai/api/trpc to fetch credit and Kilo Pass usage.",
        defaultEnabled: false,
        makeStrategies: { _ in [KiloCodeCLITokenStrategy(), KiloCodeAPIKeyStrategy()] }
    )
}

nonisolated enum KiloCodeUsageError: Error, Sendable, Equatable {
    case missingCredential
    case invalidCredentials
    case invalidResponse
}

nonisolated struct KiloCodeCLITokenStrategy: UsageFetchStrategy {
    let id = "kilo-code.cli-token"

    private static let authPath = ".local/share/kilo/auth.json"
    private static let maximumAuthFileBytes = 64 * 1_024

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        Self.token(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let token = Self.token(in: context) else {
            throw KiloCodeUsageError.missingCredential
        }
        return try await KiloCodeUsageClient.fetch(token: token, context: context)
    }

    func shouldFallback(on error: Error) -> Bool {
        guard let error = error as? KiloCodeUsageError else { return false }
        return error == .missingCredential || error == .invalidCredentials
    }

    private struct AuthFile: Decodable, Sendable {
        let kilo: KiloSection?

        struct KiloSection: Decodable, Sendable {
            let access: String?
        }
    }

    private static func token(in context: UsageFetchContext) -> String? {
        guard let contents = context.readFile(Self.authPath),
            contents.utf8.count <= Self.maximumAuthFileBytes,
            let data = contents.data(using: .utf8),
            let auth = try? JSONDecoder().decode(AuthFile.self, from: data)
        else { return nil }
        return KiloCodeCredentialCleaning.cleaned(auth.kilo?.access)
    }
}

nonisolated struct KiloCodeAPIKeyStrategy: UsageFetchStrategy {
    let id = "kilo-code.api-key"

    private let environmentCredential: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentCredential = KiloCodeCredentialCleaning.cleaned(environment["KILO_API_KEY"])
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let token = credential(in: context) else {
            throw KiloCodeUsageError.missingCredential
        }
        return try await KiloCodeUsageClient.fetch(token: token, context: context)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    private func credential(in context: UsageFetchContext) -> String? {
        KiloCodeCredentialCleaning.cleaned(context.credential(.kiloCode))
            ?? environmentCredential
    }
}

private nonisolated enum KiloCodeCredentialCleaning {
    static func cleaned(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty,
            value.utf8.count <= 64 * 1_024,
            !value.contains("\r"),
            !value.contains("\n")
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

private nonisolated enum KiloCodeUsageClient {
    private static let endpoint = URL(string: "https://app.kilo.ai/api/trpc")!
    private static let procedures = [
        "user.getCreditBlocks",
        "kiloPass.getState",
        "user.getAutoTopUpPaymentMethod",
    ]
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    static func fetch(token: String, context: UsageFetchContext) async throws -> UsageSnapshot {
        let request = try Self.makeRequest(token: token)
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await context.http.send(request, provider: .kiloCode)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw KiloCodeUsageError.invalidCredentials
        } catch UsageHTTPError.httpStatus(let status) where (300..<400).contains(status) {
            throw KiloCodeUsageError.invalidCredentials
        }
        guard data.count <= Self.maximumResponseBytes else {
            throw KiloCodeUsageError.invalidResponse
        }
        guard !Self.looksSignedOut(data: data, response: response) else {
            throw KiloCodeUsageError.invalidCredentials
        }
        return try Self.parse(data)
    }

    private struct Credits: Sendable {
        let total: Double?
        let remaining: Double?

        var used: Double? {
            guard let total, let remaining else { return nil }
            return max(0, total - remaining)
        }
    }

    private struct Pass: Sendable {
        let used: Double?
        let total: Double?
        let resetsAt: Date?
    }

    private static func makeRequest(token: String) throws -> URLRequest {
        let joinedProcedures = Self.procedures.joined(separator: ",")
        let pathURL = Self.endpoint.appendingPathComponent(joinedProcedures)
        let input = Dictionary(
            uniqueKeysWithValues: Self.procedures.indices.map {
                (String($0), ["json": NSNull()])
            })
        let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        guard let inputString = String(data: inputData, encoding: .utf8),
            var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false)
        else { throw KiloCodeUsageError.invalidResponse }
        components.queryItems = [
            URLQueryItem(name: "batch", value: "1"),
            URLQueryItem(name: "input", value: inputString),
        ]
        guard let url = components.url else { throw KiloCodeUsageError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static func parse(_ data: Data) throws -> UsageSnapshot {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            entries.count <= Self.procedures.count
        else { throw KiloCodeUsageError.invalidResponse }

        var payloads: [Int: Any] = [:]
        for (index, entry) in entries.enumerated() {
            if let error = entry["error"] as? [String: Any] {
                guard index < 2 else { continue }
                if Self.isInvalidCredentials(error) {
                    throw KiloCodeUsageError.invalidCredentials
                }
                if index < 2 {
                    throw KiloCodeUsageError.invalidResponse
                }
                continue
            }
            if let payload = Self.resultPayload(entry) {
                payloads[index] = payload
            }
        }

        let credits = Self.credits(from: payloads[0])
        let pass = Self.pass(from: payloads[1])
        var windows: [UsageWindow] = []
        if let total = credits.total,
            let remaining = credits.remaining,
            total > 0
        {
            windows.append(
                UsageWindow(
                    label: "credits",
                    percent: min(100, max(0, (total - remaining) / total * 100)),
                    tokens: nil,
                    resetsAt: nil))
        }
        if let used = pass.used, let total = pass.total, total > 0 {
            windows.append(
                UsageWindow(
                    label: "Kilo Pass",
                    percent: min(100, max(0, used / total * 100)),
                    tokens: nil,
                    resetsAt: pass.resetsAt))
        }

        let costLine: String?
        if let used = credits.used, let remaining = credits.remaining {
            costLine = String(
                format: "$%.2f used · $%.2f remaining",
                locale: Locale(identifier: "en_US_POSIX"),
                used,
                max(0, remaining))
        } else if let remaining = credits.remaining {
            costLine = String(
                format: "$%.2f remaining",
                locale: Locale(identifier: "en_US_POSIX"),
                max(0, remaining))
        } else {
            costLine = nil
        }

        guard !windows.isEmpty || costLine != nil else {
            throw KiloCodeUsageError.invalidResponse
        }
        return UsageSnapshot(
            providerID: .kiloCode,
            windows: windows,
            costLine: costLine,
            identity: nil)
    }

    private static func resultPayload(_ entry: [String: Any]) -> Any? {
        guard let result = entry["result"] as? [String: Any] else { return nil }
        if let data = result["data"] as? [String: Any] {
            if let json = data["json"], !(json is NSNull) { return json }
            return data
        }
        if let json = result["json"], !(json is NSNull) { return json }
        return nil
    }

    private static func credits(from payload: Any?) -> Credits {
        guard let payload = payload as? [String: Any] else {
            return Credits(total: nil, remaining: nil)
        }
        let blocks = payload["creditBlocks"] as? [[String: Any]] ?? []
        var total = 0.0
        var remaining = 0.0
        var sawTotal = false
        var sawRemaining = false
        for block in blocks {
            if let value = Self.double(block["amount_mUsd"]) {
                total += value / 1_000_000
                sawTotal = true
            }
            if let value = Self.double(block["balance_mUsd"]) {
                remaining += value / 1_000_000
                sawRemaining = true
            }
        }
        if !sawRemaining, let value = Self.double(payload["totalBalance_mUsd"]) {
            remaining = value / 1_000_000
            sawRemaining = true
        }
        return Credits(
            total: sawTotal ? max(0, total) : nil,
            remaining: sawRemaining ? max(0, remaining) : nil)
    }

    private static func pass(from payload: Any?) -> Pass {
        guard let payload = payload as? [String: Any] else {
            return Pass(used: nil, total: nil, resetsAt: nil)
        }
        let subscription: [String: Any]?
        if let nested = payload["subscription"] as? [String: Any] {
            subscription = nested
        } else if payload["currentPeriodUsageUsd"] != nil
            || payload["currentPeriodBaseCreditsUsd"] != nil
            || payload["currentPeriodBonusCreditsUsd"] != nil
        {
            subscription = payload
        } else {
            subscription = nil
        }
        guard let subscription else { return Pass(used: nil, total: nil, resetsAt: nil) }
        let used = Self.double(subscription["currentPeriodUsageUsd"]).map { max(0, $0) }
        let base = Self.double(subscription["currentPeriodBaseCreditsUsd"]).map { max(0, $0) }
        let bonus = max(0, Self.double(subscription["currentPeriodBonusCreditsUsd"]) ?? 0)
        let resetsAt = ["nextBillingAt", "nextRenewalAt", "renewsAt", "renewAt"]
            .lazy
            .compactMap { Self.date(subscription[$0]) }
            .first
        return Pass(used: used, total: base.map { $0 + bonus }, resetsAt: resetsAt)
    }

    private static func isInvalidCredentials(_ error: [String: Any]) -> Bool {
        let fragments = Self.strings(in: error, depth: 0)
            .joined(separator: " ")
            .lowercased()
        return fragments.contains("unauthorized") || fragments.contains("forbidden")
    }

    private static func strings(in value: Any, depth: Int) -> [String] {
        guard depth <= 3 else { return [] }
        if let value = value as? String { return [value] }
        if let value = value as? NSNumber { return [value.stringValue] }
        if let value = value as? [String: Any] {
            return value.values.flatMap { Self.strings(in: $0, depth: depth + 1) }
        }
        if let value = value as? [Any] {
            return value.flatMap { Self.strings(in: $0, depth: depth + 1) }
        }
        return []
    }

    private static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            let result = value.doubleValue
            return result.isFinite ? result : nil
        }
        if let value = value as? String, let result = Double(value), result.isFinite {
            return result
        }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? String {
            return UsageDateParsing.parseISO8601Fractional(value)
                ?? Double(value).flatMap(Self.dateFromTimestamp)
        }
        return Self.double(value).flatMap(Self.dateFromTimestamp)
    }

    private static func dateFromTimestamp(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = value > 10_000_000_000 ? value / 1_000 : value
        return Date(timeIntervalSince1970: seconds)
    }

    private static func looksSignedOut(data: Data, response: HTTPURLResponse) -> Bool {
        let host = response.url?.host?.lowercased() ?? ""
        let path = response.url?.path.lowercased() ?? ""
        if host != "app.kilo.ai" || path.contains("sign-in") || path.contains("signin")
            || path.contains("login")
        {
            return true
        }
        if response.mimeType?.lowercased() == "text/html" { return true }
        let prefix = String(decoding: data.prefix(512), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return prefix.hasPrefix("<!doctype html") || prefix.hasPrefix("<html")
    }
}
