// Adapted from CodexBar's AmpUsageFetcher.swift, AmpUsageParser.swift, and
// AmpProviderDescriptor.swift at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation

nonisolated enum AmpUsageError: Error, Sendable, Equatable {
    case missingCredential
    case unauthorized
    case invalidResponse
}

/// Amp's structured balance RPC is the only W7-supported path. CodexBar's
/// browser-cookie fallback downloads and scrapes the settings dashboard HTML,
/// which Rafu's provider plan explicitly rejects.
nonisolated struct AmpAPITokenStrategy: UsageFetchStrategy {
    let id = "amp.api-key"

    private static let usageURL = URL(
        string: "https://ampcode.com/api/internal?userDisplayBalanceInfo")!
    private static let maximumCredentialBytes = 16 * 1_024
    private static let maximumResponseBytes = 1 * 1_024 * 1_024

    private let environmentCredential: String?

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        environmentCredential = Self.cleanedCredential(environment["AMP_API_KEY"])
    }

    @concurrent
    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        credential(in: context) != nil
    }

    @concurrent
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard let token = credential(in: context) else {
            throw AmpUsageError.missingCredential
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard
            let body = try? JSONSerialization.data(withJSONObject: [
                "method": "userDisplayBalanceInfo",
                "params": [:] as [String: String],
            ])
        else { throw AmpUsageError.invalidResponse }
        request.httpBody = body

        let data: Data
        do {
            (data, _) = try await context.http.send(request, provider: .amp)
        } catch UsageHTTPError.httpStatus(let status) where status == 401 || status == 403 {
            throw AmpUsageError.unauthorized
        }
        try Task.checkCancellation()
        return try Self.parseResponse(data, now: context.now)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    static func parseResponse(_ data: Data, now: Date) throws -> UsageSnapshot {
        guard !data.isEmpty, data.count <= maximumResponseBytes,
            let response = try? JSONDecoder().decode(APIResponse.self, from: data)
        else { throw AmpUsageError.invalidResponse }

        guard response.ok else {
            if response.error?.code == "auth-required" {
                throw AmpUsageError.unauthorized
            }
            throw AmpUsageError.invalidResponse
        }
        guard let displayText = response.result?.displayText,
            !displayText.isEmpty,
            displayText.utf8.count <= maximumResponseBytes
        else { throw AmpUsageError.invalidResponse }
        return try parseDisplayText(displayText, now: now)
    }

    static func parseDisplayText(_ rawText: String, now: Date) throws -> UsageSnapshot {
        let text = stripANSICodes(rawText)
        let amount = #"([0-9][0-9,]*(?:\.[0-9]+)?)"#
        let freePattern =
            #"(?im)^\s*Amp Free:\s*\$?"# + amount + #"\s*/\s*\$?"# + amount
            + #"\s+remaining(?:\s*\(replenishes\s*\+\$?"# + amount
            + #"\s*/\s*hour\))?"#
        let percentPattern =
            #"(?im)^\s*Amp Free:\s*"# + amount
            + #"\s*%\s+remaining(?:\s+today)?(?:\s*\(resets\s+daily\))?"#

        var windows: [UsageWindow] = []
        if let captures = captures(in: text, pattern: freePattern),
            let remaining = number(element(captures, at: 0) ?? nil),
            let quota = number(element(captures, at: 1) ?? nil),
            remaining.isFinite,
            quota.isFinite,
            quota > 0
        {
            let clampedRemaining = min(quota, max(0, remaining))
            let used = quota - clampedRemaining
            let hourly = number(element(captures, at: 2) ?? nil)
            let resetsAt: Date?
            if let hourly, hourly.isFinite, hourly > 0 {
                resetsAt = now.addingTimeInterval(used / hourly * 60 * 60)
            } else {
                resetsAt = nil
            }
            windows.append(
                UsageWindow(
                    label: "Amp Free",
                    percent: used / quota * 100,
                    tokens: nil,
                    resetsAt: resetsAt))
        } else if let captures = captures(in: text, pattern: percentPattern),
            let remaining = number(element(captures, at: 0) ?? nil),
            remaining.isFinite
        {
            windows.append(
                UsageWindow(
                    label: "daily",
                    percent: min(100, max(0, 100 - remaining)),
                    tokens: nil,
                    resetsAt: nil))
        }

        let individualPattern =
            #"(?im)^\s*Individual credits:\s*\$?"# + amount + #"\s+remaining"#
        let workspacePattern =
            #"(?im)^\s*Workspace\s+.+?:\s*\$?"# + amount + #"\s+remaining"#
        let individual = captures(in: text, pattern: individualPattern)
            .flatMap { number(element($0, at: 0) ?? nil) }
            .flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        let workspaceBalances = allCaptures(in: text, pattern: workspacePattern)
            .compactMap { number(element($0, at: 0) ?? nil) }
            .filter { $0.isFinite && $0 >= 0 }
        let workspaceTotal = workspaceBalances.isEmpty ? nil : workspaceBalances.reduce(0, +)

        let costParts: [String] = [
            individual.map {
                String(
                    format: "Individual $%.2f remaining",
                    locale: Locale(identifier: "en_US_POSIX"),
                    $0)
            },
            workspaceTotal.map {
                String(
                    format: "Workspaces $%.2f remaining",
                    locale: Locale(identifier: "en_US_POSIX"),
                    $0)
            },
        ].compactMap { $0 }
        let costLine = costParts.isEmpty ? nil : costParts.joined(separator: " · ")

        let identityPattern =
            #"(?im)^\s*Signed in as\s+([^\s(]+)(?:\s+\([^\r\n)]+\))?\s*$"#
        let identity = captures(in: text, pattern: identityPattern)
            .flatMap { element($0, at: 0) ?? nil }

        let snapshot = UsageSnapshot(
            providerID: .amp,
            windows: windows,
            costLine: costLine,
            identity: identity)
        guard snapshot.renderable else { throw AmpUsageError.invalidResponse }
        return snapshot
    }

    private func credential(in context: UsageFetchContext) -> String? {
        Self.cleanedCredential(context.credential(.amp)) ?? environmentCredential
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

    private static func stripANSICodes(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u001B\[[0-?]*[ -/]*[@-~]"#)
        else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private static func captures(in text: String, pattern: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return captures(in: text, match: match)
    }

    private static func allCaptures(in text: String, pattern: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).map { captures(in: text, match: $0) }
    }

    private static func captures(in text: String, match: NSTextCheckingResult) -> [String?] {
        (1..<match.numberOfRanges).map { index in
            let capture = match.range(at: index)
            guard capture.location != NSNotFound, let range = Range(capture, in: text) else {
                return nil
            }
            return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func number(_ text: String?) -> Double? {
        text.flatMap { Double($0.replacingOccurrences(of: ",", with: "")) }
    }

    private static func element<T>(_ values: [T], at index: Int) -> T? {
        values.indices.contains(index) ? values[index] : nil
    }

    private struct APIResponse: Decodable, Sendable {
        let ok: Bool
        let result: Result?
        let error: APIError?

        struct Result: Decodable, Sendable {
            let displayText: String
        }

        struct APIError: Decodable, Sendable {
            let code: String?
        }
    }
}

nonisolated enum AmpProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .amp,
        displayName: "Amp",
        authPattern: .apiKey,
        disclosure:
            "Sends only the Amp API key you provide (or AMP_API_KEY) to ampcode.com/api/internal to fetch Amp Free and remaining credit balances. Browser-cookie dashboard scraping is not used.",
        defaultEnabled: false,
        makeStrategies: { _ in [AmpAPITokenStrategy()] }
    )
}
