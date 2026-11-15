import Foundation

/// Pure presentation rules for usage rings: the Used/Remaining display
/// mode, the ring palette, the pace estimate, ring levels, and window
/// labels. Ported from Cider's `UsagePace`/`ProviderUsage` logic in Rafu
/// style. Shared by the app and the WidgetKit extension (built with
/// `-application-extension`), so it imports Foundation only, every type is
/// `public` and `nonisolated`, and nothing here reads a clock: callers pass
/// `now`. The app's card-only rules stay in `RafuApp`
/// (`UsageCardPresentation.swift`).

/// Whether rings show the used or the remaining share of each limit.
/// Persisted by `UsageDisplayModeStore`.
public nonisolated enum UsageDisplayMode: String, CaseIterable, Codable, Sendable {
    case used
    case remaining

    /// The picker title: "Used" or "Remaining".
    public var title: String {
        switch self {
        case .used: "Used"
        case .remaining: "Remaining"
        }
    }

    /// The lower-case word for help text and VoiceOver.
    public var word: String { rawValue }

    /// The percentage the ring shows for `window`. `nil` when the window
    /// has no valid percentage (a token total, a cost line, or a bad value).
    public func percent(for window: UsageWindow) -> Double? {
        UsageWindowPresentation.usedPercent(window).map { self == .used ? $0 : 100 - $0 }
    }
}

/// How usage rings and their legend swatches are coloured. Persisted by
/// `UsageRingPaletteStore`. Presentation only: neither mode changes which
/// window a ring is (`UsageRingTone`) or how urgent it is
/// (`UsageRingLevel`) — `UsageCardInk` resolves tones per mode, and the
/// warning/critical glyph and text keep their colours in both.
public nonisolated enum UsageRingPalette: String, CaseIterable, Codable, Sendable {
    /// One stable theme hue per ring (accent, info, success).
    case color
    /// One neutral ink per ring at stepped opacities, outermost brightest.
    case monochrome

    /// The picker title: "Color" or "Monochrome".
    public var title: String {
        switch self {
        case .color: "Color"
        case .monochrome: "Monochrome"
        }
    }
}

/// Whether a window's current pace lasts until its reset. The estimate
/// assumes the average rate so far continues until the reset time.
public nonisolated struct UsagePace: Equatable, Sendable {
    public nonisolated enum State: Equatable, Sendable {
        case enough
        case tight
        case runningOut
        case exhausted
        case unknown
    }

    /// Why a pace is `.unknown`. Each reason has its own note.
    public nonisolated enum UnknownReason: Equatable, Sendable {
        case notReported
        case stale
        case resetUnavailable
        case resetPassed
        case windowUnavailable
        case tooEarly
    }

    public let state: State
    public let unknownReason: UnknownReason?
    public let note: String
    /// The used percentage the window reaches at reset if the pace holds.
    public let projectedUsedAtReset: Double?
    /// When the window reaches 100 % if the pace holds.
    public let estimatedExhaustion: Date?
    /// The average share of this limit used per hour so far.
    public let hourlyPercent: Double?

    /// `true` for the states that need the person's attention.
    public var warning: Bool {
        switch state {
        case .tight, .runningOut, .exhausted: true
        case .enough, .unknown: false
        }
    }

    /// An observation older than this cannot estimate a pace.
    public static let maximumObservationAge: TimeInterval = 20 * 60
    /// A clock skew allowance: an observation up to this far in the future
    /// still counts as fresh.
    public static let futureObservationTolerance: TimeInterval = 60
    /// Less than this much of the window is too little data for a rate.
    public static let minimumElapsed: TimeInterval = 15 * 60
    /// The longest window length (one year) that counts as plausible.
    public static let maximumWindowMinutes = 525_600
    /// A projection at or above this share of the limit is "tight".
    public static let tightThreshold: Double = 95

    public static func estimate(window: UsageWindow, observedAt: Date?, now: Date) -> UsagePace {
        guard let used = UsageWindowPresentation.usedPercent(window) else {
            return unknown(.notReported)
        }
        // A retained full window no longer describes the current limit
        // after its reset. Ask for fresh data instead of saying to wait.
        if let reset = window.resetsAt, reset <= now { return unknown(.resetPassed) }
        if used >= 100 {
            return UsagePace(
                state: .exhausted, unknownReason: nil, note: "Limit reached · wait for reset",
                projectedUsedAtReset: 100, estimatedExhaustion: nil, hourlyPercent: nil)
        }
        guard let observedAt else { return unknown(.stale) }
        let age = now.timeIntervalSince(observedAt)
        guard age >= -futureObservationTolerance, age <= maximumObservationAge else {
            return unknown(.stale)
        }
        guard let reset = window.resetsAt else { return unknown(.resetUnavailable) }
        guard reset > now else { return unknown(.resetPassed) }
        guard let minutes = window.windowMinutes, (1...maximumWindowMinutes).contains(minutes)
        else { return unknown(.windowUnavailable) }

        let duration = Double(minutes) * 60
        let elapsed = observedAt.timeIntervalSince(reset.addingTimeInterval(-duration))
        guard elapsed <= duration else { return unknown(.windowUnavailable) }
        guard elapsed >= minimumElapsed else { return unknown(.tooEarly) }

        let rate = used / elapsed
        let projected = rate * duration
        let exhaustion = rate > 0 ? observedAt.addingTimeInterval((100 - used) / rate) : nil
        let hourly = rate * 3_600

        let state: State
        let note: String
        if projected > 100 {
            state = .runningOut
            if let exhaustion {
                note =
                    exhaustion > now
                    ? "May run out in " + durationLabel(exhaustion.timeIntervalSince(now))
                    : "May be at limit · refresh"
            } else {
                note = "May run out before reset"
            }
        } else if projected >= tightThreshold {
            state = .tight
            note = "Tight · near the limit at reset"
        } else {
            state = .enough
            note = "On pace · ~\(Int((100 - projected).rounded()))% spare at reset"
        }
        return UsagePace(
            state: state, unknownReason: nil, note: note, projectedUsedAtReset: projected,
            estimatedExhaustion: exhaustion, hourlyPercent: hourly)
    }

    public static func unknown(_ reason: UnknownReason) -> UsagePace {
        UsagePace(
            state: .unknown, unknownReason: reason, note: note(for: reason),
            projectedUsedAtReset: nil, estimatedExhaustion: nil, hourlyPercent: nil)
    }

    public static func note(for reason: UnknownReason) -> String {
        switch reason {
        case .notReported: "Usage not reported"
        case .stale: "Refresh to estimate pace"
        case .resetUnavailable: "Reset time unavailable"
        case .resetPassed: "Reset passed · refreshing soon"
        case .windowUnavailable: "Window length unavailable"
        case .tooEarly: "Too early to estimate pace"
        }
    }

    /// `"45m"`, `"2h 10m"`, `"3d 4h"`. Always at least one minute, rounded
    /// up, so a countdown never reads "0m" before the reset. Bounded so an
    /// absurd interval can never trap the `Int` conversion.
    public static func durationLabel(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), 10 * 365 * 86_400) : 0
        let minutes = max(1, Int((bounded / 60).rounded(.up)))
        if minutes >= 1_440 { return "\(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// The used-percent thresholds for warning emphasis. One source for the
/// app's `UsageDisplayPolicy` and for `UsageRingLevel`, so the notch text,
/// the rings, and the widget warn at the same moment.
public nonisolated enum UsageLevelThresholds {
    /// At or above this used percent a window shows a warning.
    public static let high: Double = 80
    /// At or above this used percent a window is critical.
    public static let critical: Double = 95
}

extension UsageRingPalette {
    /// Monochrome ring opacities over the surface's primary ink, outermost
    /// first. Steps of roughly 0.25–0.4 keep three nested rings apart on the
    /// dark notch, in a light or dark Settings form, and in a widget;
    /// Increase Contrast lifts the two fainter rings, keeping the order.
    public static func monochromeOpacities(increasedContrast: Bool) -> [Double] {
        increasedContrast ? [1.0, 0.78, 0.58] : [1.0, 0.62, 0.38]
    }

    /// The monochrome track opacity over the same ink. It stays under the
    /// faintest ring's opacity so an unfilled track never reads as a fill.
    public static func monochromeTrackOpacity(increasedContrast: Bool) -> Double {
        increasedContrast ? 0.24 : 0.14
    }
}

/// How a ring signals its level. A level above `.normal` uses a warning
/// colour AND a glyph, never colour alone.
public nonisolated enum UsageRingLevel: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// The filled fraction of the ring, `0...1`. `nil` when there is no
    /// finite percentage to draw.
    public static func fraction(percent: Double?) -> Double? {
        guard let percent, percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    /// The level for a window's USED percentage and pace (independent of
    /// the display mode, so "Remaining" warns at the same moment "Used"
    /// does).
    public static func level(usedPercent: Double?, pace: UsagePace) -> UsageRingLevel {
        if pace.state == .exhausted { return .critical }
        if let usedPercent, usedPercent.isFinite {
            if usedPercent >= UsageLevelThresholds.critical { return .critical }
            if usedPercent >= UsageLevelThresholds.high { return .warning }
        }
        return pace.warning ? .warning : .normal
    }
}

/// Labels for one window: the short ring caption, the spoken title, and the
/// reset countdown.
public nonisolated enum UsageWindowPresentation {
    /// Labels that only name a window kind. When the provider reports the
    /// window length, the short label shows the length instead.
    private static let genericLabels: Set<String> = [
        "session", "weekly", "daily", "primary", "secondary", "usage", "limit",
    ]

    /// The valid used percentage, `0...100`, or `nil`.
    public static func usedPercent(_ window: UsageWindow) -> Double? {
        guard let percent = window.percent, percent.isFinite, (0...100).contains(percent) else {
            return nil
        }
        return percent
    }

    /// `"5h"`, `"7d"`, `"Opus 7d"`. Rafu providers already use short labels,
    /// so most labels pass through; a generic label ("Session", "weekly")
    /// becomes the window length when it is known.
    public static func shortLabel(for window: UsageWindow) -> String {
        guard let minutes = window.windowMinutes, minutes > 0,
            genericLabels.contains(window.label.lowercased())
        else { return window.label }
        return period(minutes: minutes)
    }

    /// `1_440` → `"1d"`, `300` → `"5h"`, `90` → `"90m"`.
    public static func period(minutes: Int) -> String {
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// The spoken name of a window: `"5h"` → `"5-hour session"`, `"7d"` →
    /// `"Weekly"`, `"Opus 7d"` → `"Opus weekly"`. Other labels pass through.
    public static func title(for window: UsageWindow) -> String {
        let label = window.label
        if let hours = wholeNumber(label, suffix: "h") {
            return "\(hours)-hour session"
        }
        if let days = wholeNumber(label, suffix: "d") {
            return days == 7 ? "Weekly" : "\(days)-day"
        }
        if label.hasSuffix(" 7d") {
            return String(label.dropLast(3)) + " weekly"
        }
        return label
    }

    /// `"↻ 2h 10m"` before the reset, `"Reset due"` after it, and a plain
    /// reason when no reset time is known.
    public static func resetLabel(for window: UsageWindow, now: Date) -> String {
        guard let reset = window.resetsAt else {
            return usedPercent(window) == nil ? "Not reported" : "Reset unknown"
        }
        return reset > now
            ? "↻ " + UsagePace.durationLabel(reset.timeIntervalSince(now)) : "Reset due"
    }

    /// The VoiceOver form of a reset time — a full sentence fragment rather
    /// than `resetLabel`'s terse countdown, because a spoken "two hours ten
    /// minutes" is harder to parse by ear than a clock time, a weekday, or
    /// a date: `"resets 4:20 PM"` the same day, `"resets Friday"` within
    /// the next week, `"resets Jul 31, 2026"` further out, `"reset due"` at
    /// or after `now`, and `"reset time unknown"` with no reset at all.
    /// `calendar`/`locale` are explicit so a test can pin both.
    public static func spokenReset(
        for window: UsageWindow, now: Date, calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        guard let reset = window.resetsAt else { return "reset time unknown" }
        if reset <= now { return "reset due" }
        // `Date.FormatStyle.timeZone(_:)` sets the TIME-ZONE-NAME component
        // ("GMT+5"), not the style's rendering zone — that one is the
        // `timeZone` PROPERTY, set after construction, every call below.
        if calendar.isDate(reset, inSameDayAs: now) {
            var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(locale)
            style.timeZone = calendar.timeZone
            return "resets " + reset.formatted(style)
        }
        let startOfToday = calendar.startOfDay(for: now)
        let startOfReset = calendar.startOfDay(for: reset)
        let days = calendar.dateComponents([.day], from: startOfToday, to: startOfReset).day
        if let days, (1...7).contains(days) {
            var style = Date.FormatStyle().weekday(.wide).locale(locale)
            style.timeZone = calendar.timeZone
            return "resets " + reset.formatted(style)
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(locale)
        style.timeZone = calendar.timeZone
        return "resets " + reset.formatted(style)
    }

    /// `"Average 4.25% of this limit per hour"` — at most two decimals, no
    /// trailing zeros, independent of the locale.
    public static func hourlyAverageText(_ hourly: Double) -> String {
        guard hourly.isFinite else { return "Average not available" }
        var number = String(format: "%.2f", (hourly * 100).rounded() / 100)
        while number.hasSuffix("0"), number.contains(".") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        return "Average \(number)% of this limit per hour"
    }

    /// The real age of the read: `"Just updated"` under 10 seconds, then
    /// `"Updated 30s ago"`, `"5m ago"` (whole minutes, rounded down, so a
    /// 61-second-old read never says 2m), `"2h 3m ago"`.
    public static func ageLabel(observedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(observedAt))
        if seconds < 10 { return "Just updated" }
        if seconds < 60 { return "Updated \(Int(seconds / 10) * 10)s ago" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
        return UsagePace.durationLabel(seconds) + " ago"
    }

    private static func wholeNumber(_ label: String, suffix: Character) -> Int? {
        guard label.last == suffix else { return nil }
        let digits = label.dropLast()
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(digits)
    }
}
