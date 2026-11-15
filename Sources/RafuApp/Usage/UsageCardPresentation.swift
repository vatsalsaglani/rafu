import Foundation

// The app-only usage card rules. They depend on `UsageSnapshot` and the
// provider registry, so they stay in `RafuApp`; the pure ring and pace
// rules they use live in `RafuWidgetShared` (`UsagePace.swift`).
// Every type is `nonisolated` in its PRIMARY declaration (see
// `UsageProviderCore.swift`) so tests and the off-main refresh path can use
// it, and nothing here reads a clock: callers pass `now`.

/// What a provider card offers when it shows only local data.
nonisolated enum UsageConnectPrompt: Equatable, Sendable {
    /// Not connected: "Connect for exact usage…".
    case connect
    /// Connected, but exact usage is not available now (for example, the
    /// credential expired): "Reconnect for exact usage…".
    case reconnect

    var buttonTitle: String {
        switch self {
        case .connect: "Connect for exact usage…"
        case .reconnect: "Reconnect for exact usage…"
        }
    }
}

/// One provider card's input: the snapshot plus refresh metadata. Built by
/// `NotchCompanionModel.usageCard(for:)`; the notch and Settings render it.
nonisolated struct UsageProviderCardModel: Equatable, Sendable {
    let snapshot: UsageSnapshot
    let observedAt: Date?
    /// The last refresh failed; this is the last successful snapshot.
    let isStale: Bool
    let hasNetworkConsent: Bool

    var providerID: UsageProviderID { snapshot.providerID }
}

/// The card's derived lines. Pure, so each rule has a test.
nonisolated enum UsageCardPresentation {
    /// Windows that can draw a ring (they carry a valid percentage).
    static func ringWindows(_ snapshot: UsageSnapshot, cap: Int? = nil) -> [UsageWindow] {
        let windows = snapshot.windows.filter { UsageWindowPresentation.usedPercent($0) != nil }
        return cap.map { Array(windows.prefix($0)) } ?? windows
    }

    /// `"5h 120K tok · 7d 1.4M tok"` for windows without a percentage, or
    /// `nil` when every window has a ring.
    static func tokenLine(_ snapshot: UsageSnapshot) -> String? {
        let parts = snapshot.windows.compactMap { window -> String? in
            guard UsageWindowPresentation.usedPercent(window) == nil, let tokens = window.tokens
            else { return nil }
            return "\(window.label) \(UsageFormat.compactTokenCount(tokens)) tok"
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// One line for the compact card: the most urgent warning, else the
    /// window closest to its limit at reset, else the first window's note.
    static func paceSummary(
        _ snapshot: UsageSnapshot, observedAt: Date?, now: Date
    ) -> (text: String, warning: Bool)? {
        let estimates = ringWindows(snapshot).map { window in
            (window, UsagePace.estimate(window: window, observedAt: observedAt, now: now))
        }
        func projected(_ pace: UsagePace) -> Double { pace.projectedUsedAtReset ?? 0 }
        let selected =
            estimates.filter { $0.1.warning }.max { projected($0.1) < projected($1.1) }
            ?? estimates.filter { $0.1.state != .unknown }.max {
                projected($0.1) < projected($1.1)
            }
            ?? estimates.first
        guard let (window, pace) = selected else { return nil }
        return (UsageWindowPresentation.shortLabel(for: window) + " · " + pace.note, pace.warning)
    }

    /// Where the numbers came from, in words. `nil` when the provider does
    /// not say.
    static func sourceLabel(for snapshot: UsageSnapshot, displayName: String) -> String? {
        switch snapshot.source {
        case .providerAPI:
            switch snapshot.providerID {
            case .claude: "Exact · Anthropic usage service"
            case .codex: "Exact · ChatGPT usage service"
            default: "Exact · \(displayName) usage service"
            }
        case .localEstimate:
            snapshot.providerID == .claude
                ? "Estimated from local transcripts" : "Estimated from local files"
        case .localReport:
            snapshot.providerID == .codex
                ? "From the newest local Codex session" : "From local files"
        case .unspecified:
            nil
        }
    }

    /// The Connect prompt for a provider whose exact usage needs Connect
    /// (`.piggybackNetwork`: Claude, Codex) while it shows local data.
    static func connectPrompt(
        for snapshot: UsageSnapshot?, authPattern: UsageAuthPattern, hasNetworkConsent: Bool
    ) -> UsageConnectPrompt? {
        guard authPattern == .piggybackNetwork else { return nil }
        switch snapshot?.source {
        case .providerAPI:
            return nil
        case .localEstimate, .localReport, .unspecified, nil:
            return hasNetworkConsent ? .reconnect : .connect
        }
    }
}

/// Keeps the last good snapshot when a refresh fails, so a transient
/// network error shows "Showing the last successful update" instead of
/// hiding the card.
nonisolated enum UsageSnapshotRetention {
    /// A retained snapshot older than this is dropped.
    static let maximumStaleAge: TimeInterval = 6 * 60 * 60

    nonisolated struct Result: Equatable, Sendable {
        let snapshots: [UsageSnapshot]
        let observedAt: [UsageProviderID: Date]
        let staleProviderIDs: Set<UsageProviderID>
    }

    /// `fresh` snapshots win. A provider missing from `fresh` keeps its
    /// previous snapshot (marked stale) only while it is still enabled, the
    /// data is younger than `maximumStaleAge`, and — for exact data from a
    /// provider service — network consent still exists, so Disconnect never
    /// leaves exact numbers on screen. The result follows `registryOrder`.
    static func merge(
        previous: [UsageSnapshot],
        previousObservedAt: [UsageProviderID: Date],
        fresh: [UsageSnapshot],
        now: Date,
        enabled: Set<UsageProviderID>,
        networkConsent: Set<UsageProviderID>,
        registryOrder: [UsageProviderID]
    ) -> Result {
        var observedAt: [UsageProviderID: Date] = [:]
        var stale: Set<UsageProviderID> = []
        // Settings can change while a request is in flight. Apply the
        // current enablement and consent to new results as well as old ones.
        var combined = fresh.filter {
            enabled.contains($0.providerID)
                && ($0.source != .providerAPI || networkConsent.contains($0.providerID))
        }
        let freshIDs = Set(combined.map(\.providerID))
        for snapshot in combined { observedAt[snapshot.providerID] = now }

        for snapshot in previous where !freshIDs.contains(snapshot.providerID) {
            let id = snapshot.providerID
            guard enabled.contains(id), let observed = previousObservedAt[id],
                now.timeIntervalSince(observed) <= maximumStaleAge,
                snapshot.source != .providerAPI || networkConsent.contains(id)
            else { continue }
            combined.append(snapshot)
            observedAt[id] = observed
            stale.insert(id)
        }

        let rank = Dictionary(
            registryOrder.enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let ordered = combined.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.providerID] ?? Int.max
            let right = rank[rhs.element.providerID] ?? Int.max
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        return Result(snapshots: ordered, observedAt: observedAt, staleProviderIDs: stale)
    }
}
