import Foundation

/// What the Board widget shows for one snapshot at one timeline date: one
/// row for each connected agent, each with the Hundred grid and the Seven
/// columns of that agent. Pure and clock-free, like the Hundred and Seven
/// presentations it reuses: each row holds the same `WidgetHundredCard`
/// and `WidgetSevenCard` those widgets make, so the three widgets agree.
///
/// Row order and the row cap:
/// - When every provider fits (`maxRows` or fewer), the rows keep the
///   snapshot order (the app writes Claude, then Codex, then the others),
///   so rows never change places between timeline entries.
/// - When there are more providers than rows, the board shows the
///   `maxRows` most urgent providers (`urgencyRank`, then the higher used
///   percent, then the snapshot order), still in snapshot order, and says
///   "+N more" for the rest.
///
/// Shapes: each provider starts with its own mark (Claude circles, Codex
/// rounded squares, others circles). A row with the same mark as the row
/// above takes the other mark, so neighbouring rows never differ by colour
/// alone. A row's Hundred grid and Seven columns use the same mark.
public struct WidgetBoardPresentation: Equatable, Sendable {
    /// The rows the landscape and portrait boards draw.
    public static let defaultMaxRows = 3

    public enum Content: Equatable, Sendable {
        case notConnected(WidgetRingsPresentation.NotConnectedReason)
        /// `hiddenCount` providers did not fit.
        case providers(rows: [WidgetBoardRow], hiddenCount: Int)
    }

    public let content: Content
    public let mode: UsageDisplayMode
    public let palette: UsageRingPalette
    /// When the app wrote the snapshot, for the header's update time.
    /// `nil` when not connected.
    public let updatedAt: Date?
    /// `"+1 more"` when providers did not fit, else `nil`.
    public let moreText: String?
    /// One sentence for the whole widget, read as one VoiceOver element.
    public let accessibilityLabel: String

    public static func make(
        snapshot: WidgetUsageSnapshot?, now: Date, maxRows: Int = defaultMaxRows,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> WidgetBoardPresentation {
        let mode = snapshot?.resolvedDisplayMode ?? .used
        let palette = snapshot?.resolvedPalette ?? .color
        guard let snapshot else {
            return notConnected(.noData, mode: mode, palette: palette)
        }
        if now.timeIntervalSince(snapshot.writtenAt) > WidgetRingsPresentation.abandonedAge {
            return notConnected(.rafuNotRunning, mode: mode, palette: palette)
        }
        let snapshotStale =
            now.timeIntervalSince(snapshot.writtenAt) > WidgetRingsPresentation.staleAge
        let all: [WidgetBoardRow] = snapshot.providers.compactMap { provider in
            guard
                let hundred = WidgetHundredCard.make(
                    provider: provider, snapshotStale: snapshotStale, mode: mode, now: now,
                    calendar: calendar, locale: locale),
                let seven = WidgetSevenCard.make(
                    provider: provider, snapshotStale: snapshotStale, mode: mode, now: now,
                    calendar: calendar, locale: locale)
            else { return nil }
            return WidgetBoardRow(hundred: hundred, seven: seven)
        }
        guard !all.isEmpty else { return notConnected(.noData, mode: mode, palette: palette) }

        let cap = max(1, maxRows)
        var rows = all
        if all.count > cap {
            let kept = Set(
                all.indices.sorted { lhs, rhs in
                    let left = all[lhs]
                    let right = all[rhs]
                    if left.urgencyRank != right.urgencyRank {
                        return left.urgencyRank > right.urgencyRank
                    }
                    let leftUsed = left.hundred.counts?.used ?? -1
                    let rightUsed = right.hundred.counts?.used ?? -1
                    if leftUsed != rightUsed { return leftUsed > rightUsed }
                    return lhs < rhs
                }.prefix(cap))
            rows = all.indices.filter { kept.contains($0) }.map { all[$0] }
        }
        for index in rows.indices.dropFirst() where rows[index].shape == rows[index - 1].shape {
            rows[index].shape = rows[index].shape == .circle ? .roundedSquare : .circle
        }
        let hidden = all.count - rows.count

        let time = snapshot.writtenAt.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone))
        var spoken = ["Agent usage, updated \(time)"]
        spoken += rows.map(\.accessibilityLabel)
        if hidden > 0 {
            spoken.append("\(hidden) more agent\(hidden == 1 ? "" : "s") not shown")
        }
        return WidgetBoardPresentation(
            content: .providers(rows: rows, hiddenCount: hidden), mode: mode, palette: palette,
            updatedAt: snapshot.writtenAt, moreText: hidden > 0 ? "+\(hidden) more" : nil,
            accessibilityLabel: spoken.joined(separator: ". "))
    }

    private static func notConnected(
        _ reason: WidgetRingsPresentation.NotConnectedReason, mode: UsageDisplayMode,
        palette: UsageRingPalette
    ) -> WidgetBoardPresentation {
        let label =
            switch reason {
            case .noData: "Agent usage, not connected. Open Rafu to connect a provider"
            case .rafuNotRunning: "Agent usage, Rafu is not running. Open Rafu to refresh"
            }
        return WidgetBoardPresentation(
            content: .notConnected(reason), mode: mode, palette: palette, updatedAt: nil,
            moreText: nil, accessibilityLabel: label)
    }
}

/// One agent on the board: its Hundred grid and its Seven columns.
public struct WidgetBoardRow: Equatable, Sendable, Identifiable {
    public internal(set) var hundred: WidgetHundredCard
    public internal(set) var seven: WidgetSevenCard

    public var id: String { hundred.id }
    public var displayName: String { hundred.displayName }
    /// The mark both the grid and the columns draw.
    public var shape: WidgetDotShape {
        get { hundred.shape }
        set {
            hundred.shape = newValue
            seven.shape = newValue
        }
    }
    public var status: WidgetProviderStatus { hundred.status }
    public var isDimmed: Bool { hundred.isDimmed }

    /// The Hundred sentence (headline, day, today, pace, reset), plus a
    /// note when the Seven day split is an estimate. The Seven day-by-day
    /// list is left out, so a board of three agents stays one short
    /// sentence each.
    public var accessibilityLabel: String {
        seven.isEstimated
            ? hundred.accessibilityLabel + ", daily values estimated"
            : hundred.accessibilityLabel
    }

    /// Higher is more urgent: at the limit 4, may run out 3, tight 2, a
    /// fresh or stale percent 1, a passed reset or a local estimate 0.
    public var urgencyRank: Int {
        switch status {
        case .pace(let pace):
            switch pace.state {
            case .exhausted: 4
            case .runningOut: 3
            case .tight: 2
            case .enough, .unknown: 1
            }
        case .stale: 1
        case .resetPassed, .localEstimate: 0
        }
    }
}
