// Adapted from CodexBar (https://github.com/steipete/CodexBar), MIT
// License. The message/part cost de-duplication query, five-hour session,
// UTC week, anchored month, and $12/$30/$60 caps follow CodexBar's current
// OpenCode Go local reader. W3 applies the same bounded local shape to the
// separate non-Go OpenCode tile while excluding Go rows from that tile.

import Foundation

/// The one local SQLite implementation shared by OpenCode and OpenCode Go.
/// It reads only provider/role/timestamp/cost metric fields through W0's
/// read-only `UsageSQLite`; message and prompt content never leaves SQLite.
nonisolated struct OpenCodeLocalUsageStrategy: UsageFetchStrategy {
    enum Scope: Sendable {
        case openCode
        case openCodeGo
    }

    struct Limits: Sendable {
        let session: Double
        let weekly: Double
        let monthly: Double
    }

    struct UsageRow: Sendable {
        let createdMs: Int64
        let cost: Double
    }

    let id: String

    private let providerID: UsageProviderID
    private let scope: Scope
    private let databasePath: String
    private let authPath: String
    private let fileExists: @Sendable (String) -> Bool

    static let limits = Limits(session: 12, weekly: 30, monthly: 60)
    static let defaultAuthPath = ".local/share/opencode/auth.json"
    static var defaultDatabasePath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
            .path
    }

    init(
        providerID: UsageProviderID = .openCode,
        scope: Scope = .openCode,
        databasePath: String = Self.defaultDatabasePath,
        authPath: String = Self.defaultAuthPath,
        fileExists: @escaping @Sendable (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) {
        self.providerID = providerID
        self.scope = scope
        self.databasePath = databasePath
        self.authPath = authPath
        self.fileExists = fileExists
        id = providerID == .openCodeGo ? "opencode-go.local-sqlite" : "opencode.local-sqlite"
    }

    func isAvailable(_ context: UsageFetchContext) async -> Bool {
        guard fileExists(databasePath),
            Self.hasAuth(context.readFile(authPath), scope: scope)
        else {
            return false
        }
        return true
    }

    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot {
        guard await isAvailable(context) else { throw UsageLocalDataError.noData }
        let rows: [UsageRow]
        do {
            rows = try readRows()
        } catch {
            // The shim's payload-free SQLite errors are deliberately collapsed
            // into the provider-wide no-data result exposed to the pipeline.
            throw UsageLocalDataError.noData
        }
        guard !rows.isEmpty else { throw UsageLocalDataError.noData }
        return Self.snapshot(providerID: providerID, rows: rows, now: context.now)
    }

    func shouldFallback(on error: Error) -> Bool { false }

    static func hasAuth(_ contents: String?, scope: Scope) -> Bool {
        guard let data = contents?.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        switch scope {
        case .openCode:
            // A Go-only login belongs exclusively to the Go tile. Any other
            // configured provider establishes the local OpenCode tool login.
            return object.keys.contains { $0 != "opencode-go" }
        case .openCodeGo:
            guard let entry = object["opencode-go"] as? [String: Any],
                let key = entry["key"] as? String
            else {
                return false
            }
            return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func snapshot(
        providerID: UsageProviderID, rows: [UsageRow], now: Date
    ) -> UsageSnapshot {
        let nowMs = Int64(now.timeIntervalSince1970 * 1_000)
        let sessionStartMs = nowMs - Int64(5 * 60 * 60 * 1_000)
        let weekStart = startOfUTCWeek(now: now)
        let weekStartMs = Int64(weekStart.timeIntervalSince1970 * 1_000)
        let weekEndMs = weekStartMs + Int64(7 * 24 * 60 * 60 * 1_000)
        let month = monthBounds(now: now, anchorMs: rows.map(\.createdMs).min())

        var sessionCost = 0.0
        var weeklyCost = 0.0
        var monthlyCost = 0.0
        var oldestSessionMs: Int64?
        for row in rows {
            if row.createdMs >= sessionStartMs, row.createdMs < nowMs {
                sessionCost += row.cost
                if oldestSessionMs.map({ row.createdMs < $0 }) ?? true {
                    oldestSessionMs = row.createdMs
                }
            }
            if row.createdMs >= weekStartMs, row.createdMs < weekEndMs {
                weeklyCost += row.cost
            }
            if row.createdMs >= month.startMs, row.createdMs < month.endMs {
                monthlyCost += row.cost
            }
        }

        let sessionResetMs = (oldestSessionMs ?? nowMs) + Int64(5 * 60 * 60 * 1_000)
        let windows = [
            UsageWindow(
                label: "5h", percent: percent(used: sessionCost, limit: limits.session),
                tokens: nil,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(sessionResetMs) / 1_000)),
            UsageWindow(
                label: "7d", percent: percent(used: weeklyCost, limit: limits.weekly),
                tokens: nil,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(weekEndMs) / 1_000)),
            UsageWindow(
                label: "monthly", percent: percent(used: monthlyCost, limit: limits.monthly),
                tokens: nil,
                resetsAt: Date(timeIntervalSince1970: TimeInterval(month.endMs) / 1_000)),
        ]

        return UsageSnapshot(
            providerID: providerID,
            windows: windows,
            costLine: String(format: "$%.2f of $%.0f (5h)", sessionCost, limits.session),
            identity: nil
        )
    }

    private func readRows() throws -> [UsageRow] {
        let hasPartTable = try !UsageSQLite.query(
            databasePath: databasePath,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
            parameters: ["part"],
            columns: ["name"]
        ).isEmpty

        let comparison = scope == .openCodeGo ? "=" : "<>"
        let sql =
            hasPartTable
            ? Self.messageAndPartSQL(comparison: comparison)
            : Self.messageSQL(comparison: comparison)
        let rows = try UsageSQLite.query(
            databasePath: databasePath,
            sql: sql,
            parameters: ["opencode-go"],
            columns: ["createdMs", "cost"]
        )
        return rows.compactMap { row in
            guard let created = row["createdMs"].flatMap(Int64.init), created > 0,
                let cost = row["cost"].flatMap(Double.init), cost >= 0, cost.isFinite
            else {
                return nil
            }
            return UsageRow(createdMs: created, cost: cost)
        }
    }

    private static func messageSQL(comparison: String) -> String {
        """
        SELECT
          CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
          CAST(json_extract(data, '$.cost') AS REAL) AS cost
        FROM message
        WHERE json_valid(data)
          AND json_extract(data, '$.providerID') \(comparison) ?
          AND json_extract(data, '$.role') = 'assistant'
          AND json_type(data, '$.cost') IN ('integer', 'real')
        """
    }

    private static func messageAndPartSQL(comparison: String) -> String {
        """
        WITH provider_messages AS (
          SELECT
            id AS messageID,
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost,
            json_type(data, '$.cost') IN ('integer', 'real') AS hasCost
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') \(comparison) ?
            AND json_extract(data, '$.role') = 'assistant'
        )
        SELECT
          CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
            AS createdMs,
          CAST(json_extract(p.data, '$.cost') AS REAL) AS cost
        FROM part p
        JOIN provider_messages m ON m.messageID = p.message_id
        WHERE json_valid(p.data)
          AND json_extract(p.data, '$.type') = 'step-finish'
          AND json_type(p.data, '$.cost') IN ('integer', 'real')
        UNION ALL
        SELECT createdMs, cost
        FROM provider_messages m
        WHERE hasCost
          AND NOT EXISTS (
            SELECT 1
            FROM part p
            WHERE p.message_id = m.messageID
              AND json_valid(p.data)
              AND json_extract(p.data, '$.type') = 'step-finish'
              AND json_type(p.data, '$.cost') IN ('integer', 'real')
          )
        """
    }

    private static func percent(used: Double, limit: Double) -> Double {
        guard used.isFinite, limit > 0 else { return 0 }
        let value = max(0, min(100, used / limit * 100))
        return (value * 10).rounded() / 10
    }

    private static func startOfUTCWeek(now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        return calendar.date(from: components) ?? now
    }

    private static func monthBounds(
        now: Date, anchorMs: Int64?
    ) -> (startMs: Int64, endMs: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        guard let anchorMs else {
            let start =
                calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (
                Int64(start.timeIntervalSince1970 * 1_000), Int64(end.timeIntervalSince1970 * 1_000)
            )
        }

        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMs) / 1_000)
        let anchorComponents = calendar.dateComponents(
            [.day, .hour, .minute, .second, .nanosecond], from: anchor)
        var currentMonth = calendar.dateComponents([.year, .month], from: now)
        var start = anchoredMonth(calendar: calendar, month: currentMonth, anchor: anchorComponents)
        if start > now,
            let previous = calendar.date(byAdding: .month, value: -1, to: start)
        {
            currentMonth = calendar.dateComponents([.year, .month], from: previous)
            start = anchoredMonth(calendar: calendar, month: currentMonth, anchor: anchorComponents)
        }
        let end = anchoredMonth(
            calendar: calendar,
            month: monthComponents(after: currentMonth, calendar: calendar),
            anchor: anchorComponents)
        return (
            Int64(start.timeIntervalSince1970 * 1_000), Int64(end.timeIntervalSince1970 * 1_000)
        )
    }

    private static func monthComponents(
        after month: DateComponents, calendar: Calendar
    ) -> DateComponents {
        let monthStart = calendar.date(from: month) ?? Date()
        let next = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
        return calendar.dateComponents([.year, .month], from: next)
    }

    private static func anchoredMonth(
        calendar: Calendar, month: DateComponents, anchor: DateComponents
    ) -> Date {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = month.year
        components.month = month.month
        components.day = anchor.day
        components.hour = anchor.hour
        components.minute = anchor.minute
        components.second = anchor.second
        components.nanosecond = anchor.nanosecond

        if let date = calendar.date(from: components),
            calendar.component(.month, from: date) == month.month
        {
            return date
        }
        components.day =
            calendar.range(
                of: .day, in: .month, for: calendar.date(from: month) ?? Date())?.count
        return calendar.date(from: components) ?? Date()
    }
}

nonisolated enum OpenCodeProvider {
    static let descriptor = UsageProviderDescriptor(
        id: .openCode,
        displayName: "OpenCode",
        authPattern: .localZeroConfig,
        disclosure:
            "Reads cost and timestamp metric fields from ~/.local/share/opencode/opencode.db after detecting auth.json. Local only — no network and no message or prompt content.",
        defaultEnabled: true,
        makeStrategies: { _ in [OpenCodeLocalUsageStrategy()] }
    )
}
