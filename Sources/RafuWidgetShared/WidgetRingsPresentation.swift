import Foundation

/// What the Rings widget shows for one snapshot at one timeline date. Pure
/// and clock-free: the timeline passes each entry's date as `now`, so the
/// countdown, staleness, and pace age without a reload. Uses the app's own
/// `UsageRingClusterBuilder` and `UsagePace`, so the widget and the menu
/// bar card agree.
public struct WidgetRingsPresentation: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case notConnected(NotConnectedReason)
        case providers([WidgetProviderCard])
    }

    public enum NotConnectedReason: Equatable, Sendable {
        /// No snapshot, or no provider with data.
        case noData
        /// The snapshot is older than `abandonedAge`: Rafu has not run.
        case rafuNotRunning
    }

    /// Data older than this is stale: dimmed rings, "⚠ 25m old", no pace.
    /// The same 20 minutes after which `UsagePace` cannot estimate a pace.
    public static let staleAge: TimeInterval = UsagePace.maximumObservationAge
    /// A snapshot older than this is not shown at all (the app keeps a
    /// stale provider for the same 6 hours, `UsageSnapshotRetention`).
    public static let abandonedAge: TimeInterval = 6 * 60 * 60

    public let content: Content
    public let mode: UsageDisplayMode
    public let palette: UsageRingPalette
    /// One sentence for the whole widget, read as one VoiceOver element.
    public let accessibilityLabel: String

    public static func make(
        snapshot: WidgetUsageSnapshot?, now: Date, maxProviders: Int,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> WidgetRingsPresentation {
        let mode = snapshot?.resolvedDisplayMode ?? .used
        let palette = snapshot?.resolvedPalette ?? .color
        guard let snapshot else {
            return notConnected(.noData, mode: mode, palette: palette)
        }
        if now.timeIntervalSince(snapshot.writtenAt) > abandonedAge {
            return notConnected(.rafuNotRunning, mode: mode, palette: palette)
        }
        let snapshotStale = now.timeIntervalSince(snapshot.writtenAt) > staleAge
        let cards = snapshot.providers.prefix(max(1, maxProviders)).compactMap { provider in
            WidgetProviderCard.make(
                provider: provider, snapshotStale: snapshotStale, mode: mode, now: now,
                calendar: calendar, locale: locale)
        }
        guard !cards.isEmpty else { return notConnected(.noData, mode: mode, palette: palette) }
        return WidgetRingsPresentation(
            content: .providers(cards), mode: mode, palette: palette,
            accessibilityLabel: cards.map(\.accessibilityLabel).joined(separator: ". "))
    }

    private static func notConnected(
        _ reason: NotConnectedReason, mode: UsageDisplayMode, palette: UsageRingPalette
    ) -> WidgetRingsPresentation {
        let label =
            switch reason {
            case .noData: "Agent usage, not connected. Open Rafu to connect a provider"
            case .rafuNotRunning: "Agent usage, Rafu is not running. Open Rafu to refresh"
            }
        return WidgetRingsPresentation(
            content: .notConnected(reason), mode: mode, palette: palette,
            accessibilityLabel: label)
    }
}

/// One provider in the widget: its ring cluster, its status, and its
/// spoken sentence.
public struct WidgetProviderCard: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    /// `nil` for a local estimate (token totals only, no percent).
    public let cluster: UsageRingCluster?
    public let status: WidgetProviderStatus
    public let tokenSummary: String?
    /// The leading window's reset when it is still ahead, for the live
    /// `Text(_, style: .relative)` countdown.
    public let resetsAt: Date?
    public let accessibilityLabel: String

    /// `true` when the rings show old numbers and draw dimmed.
    public var isDimmed: Bool {
        switch status {
        case .stale, .resetPassed: true
        case .pace, .localEstimate: false
        }
    }

    static func make(
        provider: WidgetUsageSnapshot.Provider, snapshotStale: Bool, mode: UsageDisplayMode,
        now: Date, calendar: Calendar, locale: Locale
    ) -> WidgetProviderCard? {
        let windows = provider.usageWindows
        let cluster = UsageRingClusterBuilder.make(
            windows: windows, observedAt: provider.observedAt, mode: mode,
            displayName: provider.displayName, now: now, calendar: calendar, locale: locale)
        let status: WidgetProviderStatus
        if let cluster {
            let leadingReset = windows.first?.resetsAt
            if let leadingReset, leadingReset <= now {
                status = .resetPassed
            } else if provider.isStale || snapshotStale
                || now.timeIntervalSince(provider.observedAt) > WidgetRingsPresentation.staleAge
            {
                status = .stale(age: max(0, now.timeIntervalSince(provider.observedAt)))
            } else {
                status = .pace(WidgetProviderStatus.leadingPace(cluster))
            }
        } else if provider.tokenSummary != nil {
            status = .localEstimate
        } else {
            return nil
        }
        let resetsAt = windows.first?.resetsAt.flatMap { $0 > now ? $0 : nil }
        let spokenName: String
        if let cluster {
            spokenName = cluster.accessibilityLabel
        } else {
            spokenName = provider.displayName
        }
        return WidgetProviderCard(
            id: provider.id, displayName: provider.displayName, cluster: cluster, status: status,
            tokenSummary: provider.tokenSummary, resetsAt: resetsAt,
            accessibilityLabel: spokenName + ", " + status.spokenText(now: now))
    }
}

/// The one status line under a provider's rings. A warning always has a
/// glyph and words, never colour alone.
public enum WidgetProviderStatus: Equatable, Sendable {
    /// Fresh data: the most urgent window's pace.
    case pace(UsagePace)
    /// The leading window's reset passed and no new read came.
    case resetPassed
    /// The data is older than `WidgetRingsPresentation.staleAge`, or the
    /// app's last refresh failed.
    case stale(age: TimeInterval)
    /// Token totals only (`UsageDataSource.localEstimate`).
    case localEstimate

    /// The pace the status line names: a window at its limit first, then
    /// the warning window closest to its limit at reset, then the leading
    /// window (`UsageCardPresentation.paceSummary` uses the same order).
    static func leadingPace(_ cluster: UsageRingCluster) -> UsagePace {
        let paces = cluster.legend.map(\.pace)
        if let exhausted = paces.first(where: { $0.state == .exhausted }) { return exhausted }
        func projected(_ pace: UsagePace) -> Double { pace.projectedUsedAtReset ?? 0 }
        if let warning = paces.filter(\.warning).max(by: { projected($0) < projected($1) }) {
            return warning
        }
        return paces.first ?? .unknown(.notReported)
    }

    /// How urgent the line is, for its glyph colour.
    public var level: UsageRingLevel {
        switch self {
        case .pace(let pace):
            switch pace.state {
            case .exhausted: .critical
            case .runningOut, .tight: .warning
            case .enough, .unknown: .normal
            }
        case .stale: .warning
        case .resetPassed, .localEstimate: .normal
        }
    }

    /// The small widget's short form: "✓ On pace", "▲ Out in ~9h",
    /// "■ At limit", "⚠ 25m old".
    public func shortText(now: Date) -> String {
        switch self {
        case .pace(let pace):
            switch pace.state {
            case .enough: return "✓ On pace"
            case .tight: return "▲ Tight"
            case .runningOut:
                guard let exhaustion = pace.estimatedExhaustion, exhaustion > now else {
                    return "▲ May run out"
                }
                return "▲ Out in ~" + Self.compactDuration(exhaustion.timeIntervalSince(now))
            case .exhausted: return "■ At limit"
            case .unknown: return pace.note
            }
        case .resetPassed: return "Reset passed"
        case .stale(let age): return "⚠ " + Self.compactDuration(age) + " old"
        case .localEstimate: return "Estimated"
        }
    }

    /// The medium widget's form: the app's own pace notes
    /// (`UsagePace.note`), or an instruction for the person.
    public func longText(now: Date) -> String {
        switch self {
        case .pace(let pace): pace.note
        case .resetPassed: "Reset passed · open Rafu to refresh"
        case .stale(let age): "⚠ " + Self.compactDuration(age) + " old · open Rafu to refresh"
        case .localEstimate: "Estimated · connect in Rafu for exact usage"
        }
    }

    /// The VoiceOver form: words, never glyphs or "~".
    public func spokenText(now: Date) -> String {
        switch self {
        case .pace(let pace):
            switch pace.state {
            case .enough:
                guard let projected = pace.projectedUsedAtReset else { return "on pace" }
                return "on pace, about \(Int((100 - projected).rounded())) percent spare at reset"
            case .tight: return "tight, near the limit at reset"
            case .runningOut:
                guard let exhaustion = pace.estimatedExhaustion, exhaustion > now else {
                    return "may run out before reset"
                }
                return "may run out in " + Self.spokenDuration(exhaustion.timeIntervalSince(now))
            case .exhausted: return "limit reached, wait for reset"
            case .unknown: return pace.note
            }
        case .resetPassed: return "reset passed, open Rafu to refresh"
        case .stale(let age):
            return "data " + Self.spokenDuration(age) + " old, open Rafu to refresh"
        case .localEstimate:
            return "estimated from local token totals, connect in Rafu for exact usage"
        }
    }

    /// `"45m"`, `"9h"`, `"3d"`: the largest whole unit, at least one minute.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), 10 * 365 * 86_400) : 0
        let minutes = max(1, Int(bounded / 60))
        if minutes >= 1_440 { return "\(minutes / 1_440)d" }
        if minutes >= 60 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// `"45 minutes"`, `"9 hours"`, `"3 days"`: the largest whole unit.
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), 10 * 365 * 86_400) : 0
        let minutes = max(1, Int(bounded / 60))
        func unit(_ value: Int, _ name: String) -> String {
            "\(value) \(name)\(value == 1 ? "" : "s")"
        }
        if minutes >= 1_440 { return unit(minutes / 1_440, "day") }
        if minutes >= 60 { return unit(minutes / 60, "hour") }
        return unit(minutes, "minute")
    }
}

/// When the widget's timeline needs a new entry without new data: now,
/// each hour up to `horizon`, each window's reset, the moment each
/// provider's pace goes unknown and the snapshot turns stale, and the
/// moment it is abandoned. The timeline ends at the last date
/// (`.atEnd`), so WidgetKit asks again within `horizon`.
public enum WidgetTimelinePlan {
    public static let horizon: TimeInterval = 6 * 60 * 60

    public static func entryDates(snapshot: WidgetUsageSnapshot?, now: Date) -> [Date] {
        var candidates = (1...6).map { now.addingTimeInterval(Double($0) * 3_600) }
        if let snapshot {
            candidates.append(
                snapshot.writtenAt.addingTimeInterval(WidgetRingsPresentation.staleAge))
            candidates.append(
                snapshot.writtenAt.addingTimeInterval(WidgetRingsPresentation.abandonedAge))
            for provider in snapshot.providers {
                candidates.append(
                    provider.observedAt.addingTimeInterval(WidgetRingsPresentation.staleAge))
                candidates.append(contentsOf: provider.windows.compactMap(\.resetsAt))
            }
        }
        let end = now.addingTimeInterval(horizon)
        let future = candidates.filter { $0 > now && $0 <= end }
        // Whole seconds, so two moments a few milliseconds apart are one entry.
        let unique = Set(future.map { $0.timeIntervalSinceReferenceDate.rounded(.up) })
        return [now] + unique.sorted().map(Date.init(timeIntervalSinceReferenceDate:))
    }
}
