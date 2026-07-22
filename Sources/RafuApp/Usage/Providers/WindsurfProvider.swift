// Adapted from CodexBar's WindsurfStatusProbe.swift at commit
// cc8da27cec92029a6435bfee4a703a719290234e (MIT License).

import Foundation
import SQLite3

nonisolated enum WindsurfUsageError: Error, Sendable, Equatable {
    case noLocalData
    case invalidResponse
}

/// Reads only the bounded cached-plan value Windsurf keeps in its local
/// state.vscdb. CodexBar's web path uses four Chromium localStorage values
/// and a protobuf request, not browser cookies, so W1's cookie-header cache
/// cannot represent it honestly.
nonisolated struct WindsurfLocalCachedPlanStrategy: UsageFetchStrategy {
    let id = "windsurf.local-cached-plan"

    private static let maximumPlanBytes = 64 * 1_024
    private static let planKey = "windsurf.settings.cachedPlanInfo"

    private let databasePath: String
    private let readPlan: @Sendable (String) -> String?

    init(
        databasePath: String = Self.defaultDatabasePath,
        readPlan: @escaping @Sendable (String) -> String? = Self.readCachedPlan
    ) {
        self.databasePath = databasePath
        self.readPlan = readPlan
    }

    @concurrent
    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        _ = context
        return readPlan(databasePath) != nil
    }

    @concurrent
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        _ = context
        try Task.checkCancellation()
        guard let contents = readPlan(databasePath) else {
            throw WindsurfUsageError.noLocalData
        }
        try Task.checkCancellation()
        return try Self.parseCachedPlan(contents)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Windsurf/User/globalStorage/state.vscdb"
            )
            .path
    }

    static func parseCachedPlan(_ contents: String) throws -> UsageSnapshot {
        guard !contents.isEmpty, contents.utf8.count <= maximumPlanBytes,
            let data = contents.data(using: .utf8),
            let plan = try? JSONDecoder().decode(CachedPlanInfo.self, from: data)
        else {
            throw WindsurfUsageError.invalidResponse
        }

        var windows: [UsageWindow] = []
        if let quota = plan.quotaUsage {
            if let daily = quota.dailyRemainingPercent,
                let percent = usedPercent(remainingPercent: daily)
            {
                windows.append(
                    UsageWindow(
                        label: "daily",
                        percent: percent,
                        tokens: nil,
                        resetsAt: date(unixSeconds: quota.dailyResetAtUnix)))
            }
            if let weekly = quota.weeklyRemainingPercent,
                let percent = usedPercent(remainingPercent: weekly)
            {
                windows.append(
                    UsageWindow(
                        label: "weekly",
                        percent: percent,
                        tokens: nil,
                        resetsAt: date(unixSeconds: quota.weeklyResetAtUnix)))
            }
        }

        if windows.isEmpty, let usage = plan.usage {
            if let messages = makeCountWindow(
                label: "messages",
                used: usage.usedMessages,
                remaining: usage.remainingMessages,
                total: usage.messages)
            {
                windows.append(messages)
            }
            if let actions = makeCountWindow(
                label: "flow actions",
                used: usage.usedFlowActions,
                remaining: usage.remainingFlowActions,
                total: usage.flowActions)
            {
                windows.append(actions)
            }
            if let flex = makeCountWindow(
                label: "flex credits",
                used: usage.usedFlexCredits,
                remaining: usage.remainingFlexCredits,
                total: usage.flexCredits)
            {
                windows.append(flex)
            }
        }

        guard !windows.isEmpty else { throw WindsurfUsageError.invalidResponse }
        return UsageSnapshot(
            providerID: .windsurf,
            windows: Array(windows.prefix(3)),
            costLine: nil,
            identity: cleaned(plan.planName))
    }

    static func decodeSQLiteValue(_ data: Data) -> String? {
        guard !data.isEmpty, data.count <= maximumPlanBytes else { return nil }
        let encodings: [String.Encoding] =
            data.contains(0)
            ? [.utf16LittleEndian, .utf8]
            : [.utf8, .utf16LittleEndian]
        for encoding in encodings {
            guard let decoded = String(data: data, encoding: encoding) else { continue }
            let trimmed = decoded.trimmingCharacters(in: .controlCharacters)
            guard !trimmed.isEmpty, trimmed.utf8.count <= maximumPlanBytes else { continue }
            return trimmed
        }
        return nil
    }

    private static func readCachedPlan(databasePath: String) -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK
        else {
            if database != nil { sqlite3_close(database) }
            return nil
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        var statement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "SELECT value FROM ItemTable WHERE key = ? LIMIT 1;",
                -1,
                &statement,
                nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(statement) }

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard
            planKey.withCString({
                sqlite3_bind_text(statement, 1, $0, -1, transient)
            }) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_ROW
        else { return nil }

        switch sqlite3_column_type(statement, 0) {
        case SQLITE_TEXT:
            guard let bytes = sqlite3_column_text(statement, 0) else { return nil }
            let value = String(cString: bytes)
            return value.utf8.count <= maximumPlanBytes ? value : nil
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, count <= maximumPlanBytes,
                let bytes = sqlite3_column_blob(statement, 0)
            else { return nil }
            return decodeSQLiteValue(Data(bytes: bytes, count: count))
        default:
            return nil
        }
    }

    private static func usedPercent(remainingPercent: Double) -> Double? {
        guard remainingPercent.isFinite else { return nil }
        return min(100, max(0, 100 - remainingPercent))
    }

    private static func makeCountWindow(
        label: String, used rawUsed: Int?, remaining: Int?, total: Int?
    ) -> UsageWindow? {
        guard let total, total > 0 else { return nil }
        let used = rawUsed ?? remaining.map { total - $0 }
        guard let used else { return nil }
        let clampedUsed = min(total, max(0, used))
        return UsageWindow(
            label: label,
            percent: Double(clampedUsed) / Double(total) * 100,
            tokens: nil,
            resetsAt: nil)
    }

    private static func date(unixSeconds: Int64?) -> Date? {
        guard let unixSeconds, unixSeconds > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(unixSeconds))
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !cleaned.isEmpty
        else { return nil }
        return cleaned
    }

    private struct CachedPlanInfo: Decodable, Sendable {
        let planName: String?
        let usage: Usage?
        let quotaUsage: QuotaUsage?
    }

    private struct Usage: Decodable, Sendable {
        let messages: Int?
        let usedMessages: Int?
        let remainingMessages: Int?
        let flowActions: Int?
        let usedFlowActions: Int?
        let remainingFlowActions: Int?
        let flexCredits: Int?
        let usedFlexCredits: Int?
        let remainingFlexCredits: Int?
    }

    private struct QuotaUsage: Decodable, Sendable {
        let dailyRemainingPercent: Double?
        let weeklyRemainingPercent: Double?
        let dailyResetAtUnix: Int64?
        let weeklyResetAtUnix: Int64?
    }
}

nonisolated enum WindsurfProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .windsurf,
        displayName: "Windsurf",
        authPattern: .localZeroConfig,
        disclosure:
            "Reads cached plan and quota fields from Windsurf's local state.vscdb. No network request is made; Windsurf's web session uses browser localStorage rather than cookies and is not imported.",
        defaultEnabled: false,
        makeStrategies: { _ in [WindsurfLocalCachedPlanStrategy()] }
    )
}
