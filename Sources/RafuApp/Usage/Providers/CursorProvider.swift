// Adapted from CodexBar (https://github.com/steipete/CodexBar), MIT
// License. The bound state.vscdb token lookup, JWT-derived Cursor session
// cookie, and usage-summary mapping follow CodexBar's Cursor provider.

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Payload-free failures keep Cursor's locally derived session cookie and
/// response body structurally absent from every surfaced error.
nonisolated enum CursorUsageError: Error, Sendable, Equatable {
    case noToken
    case invalidToken
    case invalidResponse
    case noUsage
}

/// Cursor.app's own signed-in token is read from its read-only SQLite state,
/// converted into Cursor's first-party session cookie, and sent only to
/// cursor.com for usage metrics. Browser-cookie fallback belongs to Wave B.
nonisolated struct CursorVSCDBStrategy: UsageFetchStrategy {
    let id = "cursor.vscdb-token"

    private let databasePath: String
    private let baseURL: URL
    private let fileExists: @Sendable (String) -> Bool

    init(
        databasePath: String = Self.defaultDatabasePath,
        baseURL: URL = URL(string: "https://cursor.com")!,
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) {
        self.databasePath = databasePath
        self.baseURL = baseURL
        self.fileExists = fileExists
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        guard fileExists(databasePath) else { return false }
        return (try? Self.cookieHeader(databasePath: databasePath)) != nil
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard fileExists(databasePath) else { throw CursorUsageError.noToken }
        let cookieHeader = try Self.cookieHeader(databasePath: databasePath)

        let summaryData = try await request(
            path: "api/usage-summary", cookieHeader: cookieHeader, context: context)

        // Identity is Settings-only enrichment. A valid usage response remains
        // useful when /api/auth/me is unavailable or changes shape.
        let identity: String?
        do {
            let identityData = try await request(
                path: "api/auth/me", cookieHeader: cookieHeader, context: context)
            identity = try Self.parseIdentity(identityData)
        } catch {
            identity = nil
        }

        let snapshot = try Self.parseUsageSummary(summaryData, identity: identity)
        guard snapshot.renderable else { throw CursorUsageError.noUsage }
        return snapshot
    }

    func shouldFallback(on error: Error) -> Bool { false }

    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            )
            .path
    }

    /// Uses the W0 read-only/bound SQLite shim; the token never enters SQL.
    static func accessToken(databasePath: String) throws -> String {
        let rows = try UsageSQLite.query(
            databasePath: databasePath,
            sql: "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;",
            parameters: ["cursorAuth/accessToken"],
            columns: ["value"]
        )
        guard let token = rows.first?["value"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !token.isEmpty
        else {
            throw CursorUsageError.noToken
        }
        return token
    }

    static func cookieHeader(databasePath: String) throws -> String {
        let token = try accessToken(databasePath: databasePath)
        return try cookieHeader(accessToken: token)
    }

    static func cookieHeader(accessToken: String) throws -> String {
        // A JWT should contain only base64url characters and separators. This
        // also prevents a compromised local value from injecting HTTP headers.
        let tokenCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard !accessToken.isEmpty,
            accessToken.unicodeScalars.allSatisfy(tokenCharacters.contains)
        else {
            throw CursorUsageError.invalidToken
        }
        let userID = try userID(accessToken: accessToken)
        // CodexBar's current Cursor implementation percent-encodes the two
        // colon separators in the cookie value.
        return "WorkosCursorSessionToken=\(userID)%3A%3A\(accessToken)"
    }

    static func userID(accessToken: String) throws -> String {
        let parts = accessToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw CursorUsageError.invalidToken }

        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)

        guard let data = Data(base64Encoded: payload),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let subject = object["sub"] as? String,
            let userID = subject.split(separator: "|", omittingEmptySubsequences: true).last.map(
                String.init),
            !userID.isEmpty
        else {
            throw CursorUsageError.invalidToken
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        guard userID.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CursorUsageError.invalidToken
        }
        return userID
    }

    static func parseUsageSummary(_ data: Data, identity: String?) throws -> UsageSnapshot {
        let summary: UsageSummary
        do {
            summary = try JSONDecoder().decode(UsageSummary.self, from: data)
        } catch {
            throw CursorUsageError.invalidResponse
        }

        let plan = summary.individualUsage?.plan
        let overall = summary.individualUsage?.overall
        let pooled = summary.teamUsage?.pooled
        let percent = planPercent(plan: plan, overall: overall, pooled: pooled)
        let reset = summary.billingCycleEnd.flatMap(UsageDateParsing.parseISO8601Fractional)

        var windows: [UsageWindow] = []
        if let percent {
            windows.append(
                UsageWindow(label: "monthly", percent: percent, tokens: nil, resetsAt: reset))
        }

        let personalOnDemand = summary.individualUsage?.onDemand
        let teamOnDemand = summary.teamUsage?.onDemand
        let resolvedOnDemand: Meter? =
            if (personalOnDemand?.limit ?? 0) > 0 {
                personalOnDemand
            } else if (teamOnDemand?.limit ?? 0) > 0 {
                teamOnDemand
            } else {
                personalOnDemand
            }

        let costLine: String?
        if let meter = resolvedOnDemand {
            let used = Double(meter.used ?? 0) / 100
            let limit = meter.limit.map { Double($0) / 100 }
            if used > 0 || (limit ?? 0) > 0 {
                if let limit, limit > 0 {
                    costLine = String(format: "$%.2f of $%.2f on demand", used, limit)
                } else {
                    costLine = String(format: "$%.2f on demand", used)
                }
            } else {
                costLine = nil
            }
        } else {
            costLine = nil
        }

        return UsageSnapshot(
            providerID: .cursor, windows: windows, costLine: costLine, identity: identity)
    }

    static func parseIdentity(_ data: Data) throws -> String? {
        do {
            return try JSONDecoder().decode(UserInfo.self, from: data).email
        } catch {
            throw CursorUsageError.invalidResponse
        }
    }

    private func request(
        path: String, cookieHeader: String, context: UsageFetchContext
    ) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        let (data, _) = try await context.http.send(request, provider: .cursor)
        return data
    }

    private static func planPercent(plan: Plan?, overall: Meter?, pooled: Meter?) -> Double? {
        let value: Double?
        if let total = plan?.totalPercentUsed {
            value = total
        } else if let auto = plan?.autoPercentUsed, let api = plan?.apiPercentUsed {
            value = (auto + api) / 2
        } else if let auto = plan?.autoPercentUsed {
            value = auto
        } else if let api = plan?.apiPercentUsed {
            value = api
        } else if let plan, let used = plan.used, let limit = plan.limit, limit > 0 {
            value = Double(used) / Double(limit) * 100
        } else if let overall, let used = overall.used, let limit = overall.limit, limit > 0 {
            value = Double(used) / Double(limit) * 100
        } else if let pooled, let used = pooled.used, let limit = pooled.limit, limit > 0 {
            value = Double(used) / Double(limit) * 100
        } else {
            value = nil
        }
        return value.map { max(0, min(100, $0)) }
    }

    private struct UsageSummary: Decodable, Sendable {
        let billingCycleEnd: String?
        let individualUsage: IndividualUsage?
        let teamUsage: TeamUsage?
    }

    private struct IndividualUsage: Decodable, Sendable {
        let plan: Plan?
        let onDemand: Meter?
        let overall: Meter?
    }

    private struct TeamUsage: Decodable, Sendable {
        let onDemand: Meter?
        let pooled: Meter?
    }

    private struct Plan: Decodable, Sendable {
        let used: Int?
        let limit: Int?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    private struct Meter: Decodable, Sendable {
        let used: Int?
        let limit: Int?
    }

    private struct UserInfo: Decodable, Sendable {
        let email: String?
    }
}

/// Piggyback network providers are opt-in: opening Settings can discover
/// this row without touching Cursor's database because strategy creation is
/// unconditional and all availability checks remain inside the strategy.
nonisolated enum CursorProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .cursor,
        displayName: "Cursor",
        authPattern: .piggybackNetwork,
        disclosure:
            "Reads Cursor's signed-in token from its local state.vscdb and sends only the derived session cookie to cursor.com to fetch plan usage. No message or prompt content is read.",
        defaultEnabled: false,
        makeStrategies: { _ in [CursorVSCDBStrategy()] }
    )
}
