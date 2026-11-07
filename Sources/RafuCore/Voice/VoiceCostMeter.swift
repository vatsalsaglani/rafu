import Foundation

/// Session minutes per calendar month. GPT-Live bills $0.05 a minute, per
/// second, for the whole open session (idle included). The server reports
/// cumulative `usage.seconds`, so the meter keeps the largest value per session.
public nonisolated struct VoiceCostMeter: Codable, Equatable, Sendable {
    public static let dollarsPerMinute = 0.05
    public static let defaultCapDollars = 5.0
    /// Open sessions beyond this are folded into their month's total.
    static let maximumOpenSessions = 16

    private struct Entry: Codable, Equatable {
        var month: String
        var seconds: Double
    }

    /// Month ("2026-11") → seconds of finished sessions.
    private var totals: [String: Double] = [:]
    /// Session id → the largest reported seconds so far.
    private var open: [String: Entry] = [:]

    public init() {}

    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    public mutating func recordUsage(sessionID: String, seconds: Double, month: String) {
        guard seconds.isFinite, seconds >= 0 else { return }
        var entry = open[sessionID] ?? Entry(month: month, seconds: 0)
        entry.seconds = max(entry.seconds, seconds)
        open[sessionID] = entry
        if open.count > Self.maximumOpenSessions {
            let oldest = open.filter { $0.key != sessionID }.keys.sorted().first
            if let oldest { finish(sessionID: oldest) }
        }
    }

    /// Moves a closed session into its month's total.
    public mutating func finish(sessionID: String) {
        guard let entry = open.removeValue(forKey: sessionID) else { return }
        totals[entry.month, default: 0] += entry.seconds
        // Keep a year of months at most.
        if totals.count > 12, let oldest = totals.keys.sorted().first {
            totals.removeValue(forKey: oldest)
        }
    }

    public func monthlySeconds(month: String) -> Double {
        (totals[month] ?? 0)
            + open.values.filter { $0.month == month }.reduce(0) { $0 + $1.seconds }
    }

    public func monthlyCost(month: String) -> Double {
        monthlySeconds(month: month) / 60 * Self.dollarsPerMinute
    }

    /// The soft cap blocks a new session, never a running one.
    public func allowsNewSession(cap: Double, month: String) -> Bool {
        monthlyCost(month: month) < cap
    }
}
