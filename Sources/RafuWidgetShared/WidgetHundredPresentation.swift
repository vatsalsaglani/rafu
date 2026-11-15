import Foundation

/// What the Hundred widget shows for one snapshot at one timeline date: a
/// 10 × 10 grid where 100 dots are one weekly limit and one dot is 1%.
/// Pure and clock-free, like `WidgetRingsPresentation`: the timeline passes
/// each entry's date as `now`, so "today", the time marker, staleness, and
/// pace age without a reload.
///
/// Dots, in Used mode from the first dot on:
/// - `.used(band:)`: used on an earlier day of the window. Neighbouring
///   days alternate `band` 0 and 1, so the day bands show.
/// - `.today`: used today (the current 24-hour slice of the window).
/// - `.projected`: what the current pace adds by the reset.
/// - `.spare`: left at the reset.
///
/// Remaining mode reverses the grid: the spare dots come first and the
/// used dots fill from the end. Without a day split (a v1 or v2 snapshot,
/// or no sample log yet) every used dot is `.used(band: 0)` and there is
/// no today group.
public struct WidgetHundredPresentation: Equatable, Sendable {
    public static let dotCount = 100
    public static let columns = 10

    public enum Content: Equatable, Sendable {
        case notConnected(WidgetRingsPresentation.NotConnectedReason)
        case providers([WidgetHundredCard])
    }

    public let content: Content
    public let mode: UsageDisplayMode
    public let palette: UsageRingPalette
    /// One sentence for the whole widget, read as one VoiceOver element.
    public let accessibilityLabel: String

    public static func make(
        snapshot: WidgetUsageSnapshot?, now: Date, maxProviders: Int,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> WidgetHundredPresentation {
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
        var cards = snapshot.providers.prefix(max(1, maxProviders)).compactMap { provider in
            WidgetHundredCard.make(
                provider: provider, snapshotStale: snapshotStale, mode: mode, now: now,
                calendar: calendar, locale: locale)
        }
        guard !cards.isEmpty else { return notConnected(.noData, mode: mode, palette: palette) }
        // Two cards side by side never share a dot shape, so the providers
        // differ by shape and not by colour alone.
        if cards.count > 1, cards[1].shape == cards[0].shape {
            cards[1].shape = cards[0].shape == .circle ? .roundedSquare : .circle
        }
        return WidgetHundredPresentation(
            content: .providers(cards), mode: mode, palette: palette,
            accessibilityLabel: cards.map(\.accessibilityLabel).joined(separator: ". "))
    }

    private static func notConnected(
        _ reason: WidgetRingsPresentation.NotConnectedReason, mode: UsageDisplayMode,
        palette: UsageRingPalette
    ) -> WidgetHundredPresentation {
        let label =
            switch reason {
            case .noData: "Agent usage, not connected. Open Rafu to connect a provider"
            case .rafuNotRunning: "Agent usage, Rafu is not running. Open Rafu to refresh"
            }
        return WidgetHundredPresentation(
            content: .notConnected(reason), mode: mode, palette: palette,
            accessibilityLabel: label)
    }
}

/// One dot of the Hundred grid.
public enum WidgetHundredDot: Equatable, Sendable {
    /// Used on an earlier day; `band` alternates 0 and 1 by day.
    case used(band: Int)
    case today
    case projected
    case spare
}

/// The mark each provider draws. Claude uses circles and Codex rounded
/// squares; other providers take a circle, and the second card of a pair
/// takes the other shape.
public enum WidgetDotShape: Equatable, Sendable {
    case circle
    case roundedSquare

    static func forProvider(_ id: String) -> WidgetDotShape {
        id == "codex" ? .roundedSquare : .circle
    }
}

/// One provider's grid, labels, status, and spoken sentence.
public struct WidgetHundredCard: Equatable, Sendable, Identifiable {
    /// How many dots of each kind the grid has. They add up to 100.
    public struct Counts: Equatable, Sendable {
        public let used: Int
        /// The part of `used` that is today's. `nil` without a day split.
        public let today: Int?
        public let projected: Int
        public let spare: Int
    }

    public let id: String
    public let displayName: String
    public internal(set) var shape: WidgetDotShape
    /// 100 dots in drawing order (row by row from the top left). `nil` for
    /// a local estimate: there is no percent to draw.
    public let dots: [WidgetHundredDot]?
    public let counts: Counts?
    /// The dot that marks how much of the window has gone, in drawing
    /// order. `nil` without a window start or after the reset.
    public let elapsedMarkerIndex: Int?
    /// `"41%"`, or `"—"` after the reset.
    public let headline: String
    /// `"used"` or `"left"`.
    public let headlineCaption: String
    /// `"6% today"`, with a day split only.
    public let todayText: String?
    /// `"Day 6 of 7"`.
    public let dayText: String?
    public let status: WidgetProviderStatus
    public let tokenSummary: String?
    /// The weekly window's reset when it is still ahead.
    public let resetsAt: Date?
    public let accessibilityLabel: String

    /// `true` when the grid shows old numbers and draws dimmed.
    public var isDimmed: Bool {
        switch status {
        case .stale, .resetPassed: true
        case .pace, .localEstimate: false
        }
    }

    /// The weekly window the grid shows: the first window with a 7-day
    /// length, else the first window.
    static func primaryWindow(_ provider: WidgetUsageSnapshot.Provider)
        -> WidgetUsageSnapshot.Window?
    {
        provider.windows.first { $0.windowMinutes == UsageDailyWeek.windowMinutes }
            ?? provider.windows.first
    }

    static func make(
        provider: WidgetUsageSnapshot.Provider, snapshotStale: Bool, mode: UsageDisplayMode,
        now: Date, calendar: Calendar, locale: Locale
    ) -> WidgetHundredCard? {
        let shape = WidgetDotShape.forProvider(provider.id)
        guard let window = primaryWindow(provider) else {
            guard provider.tokenSummary != nil else { return nil }
            let status = WidgetProviderStatus.localEstimate
            return WidgetHundredCard(
                id: provider.id, displayName: provider.displayName, shape: shape, dots: nil,
                counts: nil, elapsedMarkerIndex: nil, headline: "—", headlineCaption: "",
                todayText: nil, dayText: nil, status: status,
                tokenSummary: provider.tokenSummary, resetsAt: nil,
                accessibilityLabel: provider.displayName + ", " + status.spokenText(now: now))
        }
        let usageWindow = UsageWindow(
            label: window.label, percent: window.usedPercent, tokens: nil,
            resetsAt: window.resetsAt, windowMinutes: window.windowMinutes)
        let status: WidgetProviderStatus
        if let reset = window.resetsAt, reset <= now {
            status = .resetPassed
        } else if provider.isStale || snapshotStale
            || now.timeIntervalSince(provider.observedAt) > WidgetRingsPresentation.staleAge
        {
            status = .stale(age: max(0, now.timeIntervalSince(provider.observedAt)))
        } else {
            status = .pace(
                UsagePace.estimate(window: usageWindow, observedAt: provider.observedAt, now: now))
        }
        let resetPassed = status == .resetPassed

        let used = window.usedPercent.isFinite ? min(max(window.usedPercent, 0), 100) : 0
        let usedCount = resetPassed ? 0 : Int(used.rounded())

        // The window start: the snapshot's own, else reset minus length.
        let start =
            window.windowStart
            ?? window.resetsAt.flatMap { reset in
                window.windowMinutes.map { reset.addingTimeInterval(-Double($0) * 60) }
            }
        let duration = window.windowMinutes.map { Double($0) * 60 }

        // The day split: cumulative dot counts at the end of each day.
        var dayEnds: [Int]?
        var todayIndex: Int?
        if !resetPassed, let daily = window.daily, let start = window.windowStart, now >= start,
            !daily.isEmpty
        {
            let index = min(daily.count - 1, Int(now.timeIntervalSince(start) / 86_400))
            var total = 0.0
            var ends: [Int] = []
            for day in 0...index {
                let value = daily[day] ?? 0
                total += value.isFinite ? max(0, value) : 0
                ends.append(min(usedCount, Int(total.rounded())))
            }
            ends[index] = usedCount
            dayEnds = ends
            todayIndex = index
        }

        var dots: [WidgetHundredDot] = []
        dots.reserveCapacity(WidgetHundredPresentation.dotCount)
        for dot in 0..<usedCount {
            if let dayEnds, let todayIndex {
                let day = dayEnds.firstIndex { dot < $0 } ?? todayIndex
                dots.append(day == todayIndex ? .today : .used(band: day % 2))
            } else {
                dots.append(.used(band: 0))
            }
        }
        var projectedCount = 0
        if case .pace(let pace) = status {
            switch pace.state {
            case .runningOut:
                projectedCount = 100 - usedCount
            case .enough, .tight:
                if let projected = pace.projectedUsedAtReset, projected.isFinite {
                    projectedCount = min(
                        max(0, Int(min(projected, 100).rounded()) - usedCount), 100 - usedCount)
                }
            case .exhausted, .unknown:
                break
            }
        }
        dots += Array(repeating: .projected, count: projectedCount)
        let spareCount = 100 - usedCount - projectedCount
        dots += Array(repeating: .spare, count: spareCount)

        var marker: Int?
        if !resetPassed, let start, let duration, duration > 0, now >= start {
            let fraction = min(max(now.timeIntervalSince(start) / duration, 0), 1)
            marker = min(max(Int((fraction * 100).rounded()) - 1, 0), 99)
        }
        if mode == .remaining {
            dots.reverse()
            marker = marker.map { 99 - $0 }
        }

        let todayCount = dayEnds.flatMap { ends in
            todayIndex.map { usedCount - ($0 > 0 ? ends[$0 - 1] : 0) }
        }
        let shownPercent = mode == .remaining ? 100 - usedCount : usedCount
        let headline = resetPassed ? "—" : "\(shownPercent)%"
        let caption = mode == .remaining ? "left" : "used"
        let days = duration.map { max(1, Int(($0 / 86_400).rounded())) }
        var dayNumber: Int?
        if !resetPassed, let start, let days, now >= start {
            dayNumber = min(days, Int(now.timeIntervalSince(start) / 86_400) + 1)
        }
        let dayText = dayNumber.flatMap { number in days.map { "Day \(number) of \($0)" } }
        let resetsAt = window.resetsAt.flatMap { $0 > now ? $0 : nil }

        var spoken = [provider.displayName]
        let title = UsageWindowPresentation.title(for: usageWindow)
        let limitName = (title.prefix(1).lowercased() + title.dropFirst()) + " limit"
        if resetPassed {
            spoken.append(limitName)
        } else {
            spoken.append(
                limitName + " \(shownPercent) percent " + (mode == .remaining ? "left" : "used"))
            if let dayNumber, let days { spoken.append("day \(dayNumber) of \(days)") }
            if let todayCount { spoken.append("\(todayCount) percent today") }
        }
        spoken.append(status.spokenText(now: now))
        if !resetPassed, window.resetsAt != nil {
            spoken.append(
                UsageWindowPresentation.spokenReset(
                    for: usageWindow, now: now, calendar: calendar, locale: locale))
        }

        return WidgetHundredCard(
            id: provider.id, displayName: provider.displayName, shape: shape, dots: dots,
            counts: Counts(
                used: usedCount, today: todayCount, projected: projectedCount, spare: spareCount),
            elapsedMarkerIndex: marker, headline: headline, headlineCaption: caption,
            todayText: todayCount.map { "\($0)% today" }, dayText: dayText, status: status,
            tokenSummary: provider.tokenSummary, resetsAt: resetsAt,
            accessibilityLabel: spoken.joined(separator: ", "))
    }
}

/// The weekly window the day split describes.
public enum UsageDailyWeek {
    public static let windowMinutes = 10_080
    public static let days = 7
}
