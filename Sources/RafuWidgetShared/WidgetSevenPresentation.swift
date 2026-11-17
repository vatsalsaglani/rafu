import Foundation

/// What the Seven widget shows for one snapshot at one timeline date: one
/// column for each day of the current weekly limit window, one dot for each
/// 1% of the weekly limit, stacked in the column of the day it was used.
/// Pure and clock-free, like `WidgetHundredPresentation`: the timeline
/// passes each entry's date as `now`, so "today", the countdown,
/// staleness, and pace age without a reload.
///
/// A day is a 24-hour slice from the window start (the app's
/// `UsageDailyBreakdown`), not a calendar day. Each column is labelled with
/// the weekday of its slice midpoint.
///
/// Columns:
/// - `.past`: the day's used dots, filled.
/// - `.today`: today's used dots so far, the brightest fill, plus hollow
///   dots up to the pace line (what an even day still permits).
/// - `.future`: hollow dots up to the pace line.
///
/// A column holds `maxDotsPerColumn` dots (`rows` × 2). A day above that is
/// cut at the top and reports the rest as `overflow` ("+N").
///
/// The pace line: in Used mode, an even daily pace of the whole limit
/// (100 ÷ 7 ≈ 14.3% a day). In Remaining mode, the even daily share of what
/// is left, counted from the start of today:
/// (left + today's use) ÷ days left including today. Each day at or under
/// the line keeps the week on pace.
public struct WidgetSevenPresentation: Equatable, Sendable {
    public static let dayCount = UsageDailyWeek.days
    /// Dot rows in a column. Two dots wide, so `maxDotsPerColumn` is 16.
    public static let rows = 8
    public static let dotsPerRow = 2
    public static let maxDotsPerColumn = rows * dotsPerRow
    /// 100 ÷ 7: the share of the limit an even day uses.
    public static let evenDailyPercent = 100.0 / Double(dayCount)

    public enum Content: Equatable, Sendable {
        case notConnected(WidgetRingsPresentation.NotConnectedReason)
        case providers([WidgetSevenCard])
    }

    public let content: Content
    public let mode: UsageDisplayMode
    public let palette: UsageRingPalette
    /// One sentence for the whole widget, read as one VoiceOver element.
    public let accessibilityLabel: String

    public static func make(
        snapshot: WidgetUsageSnapshot?, now: Date, maxProviders: Int,
        calendar: Calendar = .current, locale: Locale = .current
    ) -> WidgetSevenPresentation {
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
            WidgetSevenCard.make(
                provider: provider, snapshotStale: snapshotStale, mode: mode, now: now,
                calendar: calendar, locale: locale)
        }
        guard !cards.isEmpty else { return notConnected(.noData, mode: mode, palette: palette) }
        // Two stacked panels never share a dot shape (as in Hundred), so
        // the providers differ by shape and not by colour alone.
        if cards.count > 1, cards[1].shape == cards[0].shape {
            cards[1].shape = cards[0].shape == .circle ? .roundedSquare : .circle
        }
        return WidgetSevenPresentation(
            content: .providers(cards), mode: mode, palette: palette,
            accessibilityLabel: cards.map(\.accessibilityLabel).joined(separator: ". "))
    }

    private static func notConnected(
        _ reason: WidgetRingsPresentation.NotConnectedReason, mode: UsageDisplayMode,
        palette: UsageRingPalette
    ) -> WidgetSevenPresentation {
        let label =
            switch reason {
            case .noData: "Agent usage, not connected. Open Rafu to connect a provider"
            case .rafuNotRunning: "Agent usage, Rafu is not running. Open Rafu to refresh"
            }
        return WidgetSevenPresentation(
            content: .notConnected(reason), mode: mode, palette: palette,
            accessibilityLabel: label)
    }
}

/// One day column of the Seven chart.
public struct WidgetSevenColumn: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case past
        case today
        case future
    }

    /// The day index in the window, 0...6.
    public let id: Int
    public let kind: Kind
    /// The weekday of the slice midpoint: `"M"`, `"T"`, …
    public let label: String
    /// `"Monday"`, for the spoken sentence.
    public let weekday: String
    /// The day's use in whole percent (dots). `nil` for a future day, and
    /// for a past day without a day split.
    public let percent: Int?
    /// Filled dots drawn, at most `maxDotsPerColumn`.
    public let filled: Int
    /// Hollow dots drawn above the filled ones, up to the pace line.
    public let hollow: Int
    /// Dots past the top of the column, shown as "+N". 0 when it fits.
    public let overflow: Int
}

/// One provider's panel: headline, columns, pace line, status, sentence.
public struct WidgetSevenCard: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public internal(set) var shape: WidgetDotShape
    /// Seven columns, or `nil` when there is nothing to place by day: a
    /// local estimate, a window without a reset, or a passed reset.
    public let columns: [WidgetSevenColumn]?
    /// `true` when the snapshot has a day split. Without one (no sample log
    /// yet, or an older snapshot) the columns show only the pace hollows.
    public let hasDailySplit: Bool
    /// `true` when the app spread a log gap over days: show "est.".
    public let isEstimated: Bool
    /// The pace line in percent a day (see `WidgetSevenPresentation`).
    public let paceLinePercent: Double
    /// The pace line height in dot rows from the column bottom, capped at
    /// `WidgetSevenPresentation.rows`.
    public let paceLineRow: Double
    /// `"41%"`, or `"—"` after the reset.
    public let headline: String
    /// `"used"` or `"left"`.
    public let headlineCaption: String
    /// `"6% today"` by the user's calendar day (`"<1% today"` under half a
    /// percent), with a day split only. See `WidgetTodayText`.
    public let todayText: String?
    /// `"Day 6 of 7"`.
    public let dayText: String?
    /// `"Even pace · 14% a day"` or `"Each day left · ~11%"`.
    public let paceLineText: String
    public let status: WidgetProviderStatus
    public let tokenSummary: String?
    /// The weekly window's reset when it is still ahead.
    public let resetsAt: Date?
    public let accessibilityLabel: String

    /// `true` when the chart shows old numbers and draws dimmed.
    public var isDimmed: Bool {
        switch status {
        case .stale, .resetPassed: true
        case .pace, .localEstimate: false
        }
    }

    static func make(
        provider: WidgetUsageSnapshot.Provider, snapshotStale: Bool, mode: UsageDisplayMode,
        now: Date, calendar: Calendar, locale: Locale
    ) -> WidgetSevenCard? {
        let shape = WidgetDotShape.forProvider(provider.id)
        let evenPercent = WidgetSevenPresentation.evenDailyPercent
        guard let window = WidgetHundredCard.primaryWindow(provider) else {
            guard provider.tokenSummary != nil else { return nil }
            let status = WidgetProviderStatus.localEstimate
            return WidgetSevenCard(
                id: provider.id, displayName: provider.displayName, shape: shape, columns: nil,
                hasDailySplit: false, isEstimated: false, paceLinePercent: evenPercent,
                paceLineRow: rowFor(evenPercent), headline: "—", headlineCaption: "",
                todayText: nil, dayText: nil, paceLineText: evenPaceText, status: status,
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
        let leftCount = 100 - usedCount
        let dayCount = WidgetSevenPresentation.dayCount
        let isWeekly = window.windowMinutes == UsageDailyWeek.windowMinutes

        // The window start: the snapshot's own, else reset minus 7 days.
        let start: Date? =
            isWeekly
            ? (window.windowStart
                ?? window.resetsAt.map { $0.addingTimeInterval(-Double(dayCount) * 86_400) })
            : nil
        var todayIndex: Int?
        if !resetPassed, let start, now >= start {
            todayIndex = min(dayCount - 1, Int(now.timeIntervalSince(start) / 86_400))
        }

        // Whole-percent dots per day by cumulative rounding, so the columns
        // add up to the headline; today takes the rest.
        var dayCounts: [Int]?
        if let todayIndex, let daily = window.daily, !daily.isEmpty, window.windowStart != nil {
            var total = 0.0
            var previousEnd = 0
            var counts: [Int] = []
            for day in 0...todayIndex {
                let value = day < daily.count ? (daily[day] ?? 0) : 0
                total += value.isFinite ? max(0, value) : 0
                let end = day == todayIndex ? usedCount : min(usedCount, Int(total.rounded()))
                counts.append(max(0, end - previousEnd))
                previousEnd = max(previousEnd, end)
            }
            dayCounts = counts
        }
        let todayCount = dayCounts.flatMap { counts in todayIndex.map { counts[$0] } }

        // The pace line.
        let paceLinePercent: Double
        let paceLineText: String
        if mode == .remaining, let todayIndex {
            let daysLeft = Double(dayCount - todayIndex)
            paceLinePercent = Double(leftCount + (todayCount ?? 0)) / daysLeft
            paceLineText = "Each day left · ~\(Int(paceLinePercent.rounded()))%"
        } else {
            paceLinePercent = evenPercent
            paceLineText = evenPaceText
        }
        let paceDots = min(
            WidgetSevenPresentation.maxDotsPerColumn, Int(paceLinePercent.rounded()))

        var columns: [WidgetSevenColumn]?
        if !resetPassed, let start, let todayIndex {
            var weekdayCalendar = calendar
            weekdayCalendar.locale = locale
            let letters = weekdayCalendar.veryShortStandaloneWeekdaySymbols
            let names = weekdayCalendar.standaloneWeekdaySymbols
            columns = (0..<dayCount).map { day in
                let midpoint = start.addingTimeInterval((Double(day) + 0.5) * 86_400)
                let weekdayIndex = weekdayCalendar.component(.weekday, from: midpoint) - 1
                let kind: WidgetSevenColumn.Kind =
                    day < todayIndex ? .past : day == todayIndex ? .today : .future
                let percent: Int? = kind == .future ? nil : dayCounts?[day]
                let dots = percent ?? 0
                let filled = min(dots, WidgetSevenPresentation.maxDotsPerColumn)
                let hollow: Int =
                    switch kind {
                    case .past: 0
                    case .today: max(0, paceDots - filled)
                    case .future: paceDots
                    }
                return WidgetSevenColumn(
                    id: day, kind: kind, label: letters[weekdayIndex], weekday: names[weekdayIndex],
                    percent: percent, filled: filled, hollow: hollow,
                    overflow: max(0, dots - WidgetSevenPresentation.maxDotsPerColumn))
            }
        }

        let shownPercent = mode == .remaining ? leftCount : usedCount
        let headline = resetPassed ? "—" : "\(shownPercent)%"
        let caption = mode == .remaining ? "left" : "used"
        let dayText = todayIndex.map { "Day \($0 + 1) of \(dayCount)" }
        let resetsAt = window.resetsAt.flatMap { $0 > now ? $0 : nil }
        let isEstimated = dayCounts != nil && window.isDailyEstimated

        var spoken = [provider.displayName]
        let title = UsageWindowPresentation.title(for: usageWindow)
        let limitName = (title.prefix(1).lowercased() + title.dropFirst()) + " limit"
        if resetPassed {
            spoken.append(limitName)
        } else {
            spoken.append(
                limitName + " \(shownPercent) percent " + (mode == .remaining ? "left" : "used"))
            if let todayIndex { spoken.append("day \(todayIndex + 1) of \(dayCount)") }
            if let columns, dayCounts != nil {
                let days = columns.filter { $0.kind != .future }.map { column in
                    let value = column.percent ?? 0
                    return column.kind == .today
                        ? WidgetTodayText.spokenSoFar(
                            window: window, now: now, calendar: calendar, sliceCount: value)
                        : "\(column.weekday) \(value) percent"
                }
                spoken.append(contentsOf: days)
                if isEstimated { spoken.append("daily values estimated") }
            }
            if mode == .remaining, todayIndex != nil {
                spoken.append(
                    "about \(Int(paceLinePercent.rounded())) percent for each day left")
            }
        }
        spoken.append(status.spokenText(now: now))
        if !resetPassed, window.resetsAt != nil {
            spoken.append(
                UsageWindowPresentation.spokenReset(
                    for: usageWindow, now: now, calendar: calendar, locale: locale))
        }

        return WidgetSevenCard(
            id: provider.id, displayName: provider.displayName, shape: shape, columns: columns,
            hasDailySplit: dayCounts != nil, isEstimated: isEstimated,
            paceLinePercent: paceLinePercent, paceLineRow: rowFor(paceLinePercent),
            headline: headline, headlineCaption: caption,
            todayText: todayCount.flatMap {
                WidgetTodayText.text(
                    window: window, now: now, calendar: calendar, sliceCount: $0)
            }, dayText: dayText,
            paceLineText: paceLineText, status: status, tokenSummary: provider.tokenSummary,
            resetsAt: resetsAt, accessibilityLabel: spoken.joined(separator: ", "))
    }

    static let evenPaceText =
        "Even pace · \(Int(WidgetSevenPresentation.evenDailyPercent.rounded()))% a day"

    /// Percent a day as dot rows from the column bottom (two dots a row).
    static func rowFor(_ percent: Double) -> Double {
        let rows = Double(WidgetSevenPresentation.rows)
        guard percent.isFinite else { return rows }
        return min(max(percent / Double(WidgetSevenPresentation.dotsPerRow), 0), rows)
    }
}
