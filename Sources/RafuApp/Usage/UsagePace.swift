import Foundation

/// Pure presentation rules for usage rings and cards: the Used/Remaining
/// display mode, the pace estimate, window labels, and the card's summary
/// lines. Ported from Cider's `UsagePace`/`ProviderUsage` logic in Rafu
/// style. Every type is `nonisolated` in its PRIMARY declaration (see
/// `UsageProviderCore.swift`) so tests and the off-main refresh path can use
/// it, and nothing here reads a clock: callers pass `now`.

/// Whether rings show the used or the remaining share of each limit.
/// Persisted by `UsageDisplayModeStore`.
nonisolated enum UsageDisplayMode: String, CaseIterable, Codable, Sendable {
    case used
    case remaining

    /// The picker title: "Used" or "Remaining".
    var title: String {
        switch self {
        case .used: "Used"
        case .remaining: "Remaining"
        }
    }

    /// The lower-case word for help text and VoiceOver.
    var word: String { rawValue }

    /// The percentage the ring shows for `window`. `nil` when the window
    /// has no valid percentage (a token total, a cost line, or a bad value).
    func percent(for window: UsageWindow) -> Double? {
        UsageWindowPresentation.usedPercent(window).map { self == .used ? $0 : 100 - $0 }
    }
}

/// How usage rings and their legend swatches are coloured. Persisted by
/// `UsageRingPaletteStore`. Presentation only: neither mode changes which
/// window a ring is (`UsageRingTone`) or how urgent it is
/// (`UsageRingLevel`) — `UsageCardInk` resolves tones per mode, and the
/// warning/critical glyph and text keep their colours in both.
nonisolated enum UsageRingPalette: String, CaseIterable, Codable, Sendable {
    /// One stable theme hue per ring (accent, info, success).
    case color
    /// One neutral ink per ring at stepped opacities, outermost brightest.
    case monochrome

    /// The picker title: "Color" or "Monochrome".
    var title: String {
        switch self {
        case .color: "Color"
        case .monochrome: "Monochrome"
        }
    }
}

/// Whether a window's current pace lasts until its reset. The estimate
/// assumes the average rate so far continues until the reset time.
nonisolated struct UsagePace: Equatable, Sendable {
    nonisolated enum State: Equatable, Sendable {
        case enough
        case tight
        case runningOut
        case exhausted
        case unknown
    }

    /// Why a pace is `.unknown`. Each reason has its own note.
    nonisolated enum UnknownReason: Equatable, Sendable {
        case notReported
        case stale
        case resetUnavailable
        case resetPassed
        case windowUnavailable
        case tooEarly
    }

    let state: State
    let unknownReason: UnknownReason?
    let note: String
    /// The used percentage the window reaches at reset if the pace holds.
    let projectedUsedAtReset: Double?
    /// When the window reaches 100 % if the pace holds.
    let estimatedExhaustion: Date?
    /// The average share of this limit used per hour so far.
    let hourlyPercent: Double?

    /// `true` for the states that need the person's attention.
    var warning: Bool {
        switch state {
        case .tight, .runningOut, .exhausted: true
        case .enough, .unknown: false
        }
    }

    /// An observation older than this cannot estimate a pace.
    static let maximumObservationAge: TimeInterval = 20 * 60
    /// A clock skew allowance: an observation up to this far in the future
    /// still counts as fresh.
    static let futureObservationTolerance: TimeInterval = 60
    /// Less than this much of the window is too little data for a rate.
    static let minimumElapsed: TimeInterval = 15 * 60
    /// The longest window length (one year) that counts as plausible.
    static let maximumWindowMinutes = 525_600
    /// A projection at or above this share of the limit is "tight".
    static let tightThreshold: Double = 95

    static func estimate(window: UsageWindow, observedAt: Date?, now: Date) -> UsagePace {
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

    static func unknown(_ reason: UnknownReason) -> UsagePace {
        UsagePace(
            state: .unknown, unknownReason: reason, note: note(for: reason),
            projectedUsedAtReset: nil, estimatedExhaustion: nil, hourlyPercent: nil)
    }

    static func note(for reason: UnknownReason) -> String {
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
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let bounded = seconds.isFinite ? min(max(0, seconds), 10 * 365 * 86_400) : 0
        let minutes = max(1, Int((bounded / 60).rounded(.up)))
        if minutes >= 1_440 { return "\(minutes / 1_440)d \((minutes % 1_440) / 60)h" }
        if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes)m"
    }
}

/// How a ring signals its level. A level above `.normal` uses a warning
/// colour AND a glyph, never colour alone.
nonisolated enum UsageRingLevel: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// The filled fraction of the ring, `0...1`. `nil` when there is no
    /// finite percentage to draw.
    static func fraction(percent: Double?) -> Double? {
        guard let percent, percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    /// The level for a window's USED percentage and pace (independent of
    /// the display mode, so "Remaining" warns at the same moment "Used"
    /// does).
    static func level(usedPercent: Double?, pace: UsagePace) -> UsageRingLevel {
        if pace.state == .exhausted { return .critical }
        if let usedPercent, usedPercent.isFinite {
            if usedPercent >= UsageDisplayPolicy.criticalUsageThreshold { return .critical }
            if usedPercent >= UsageDisplayPolicy.highUsageThreshold { return .warning }
        }
        return pace.warning ? .warning : .normal
    }
}

/// Labels for one window: the short ring caption, the spoken title, and the
/// reset countdown.
nonisolated enum UsageWindowPresentation {
    /// Labels that only name a window kind. When the provider reports the
    /// window length, the short label shows the length instead.
    private static let genericLabels: Set<String> = [
        "session", "weekly", "daily", "primary", "secondary", "usage", "limit",
    ]

    /// The valid used percentage, `0...100`, or `nil`.
    static func usedPercent(_ window: UsageWindow) -> Double? {
        guard let percent = window.percent, percent.isFinite, (0...100).contains(percent) else {
            return nil
        }
        return percent
    }

    /// `"5h"`, `"7d"`, `"Opus 7d"`. Rafu providers already use short labels,
    /// so most labels pass through; a generic label ("Session", "weekly")
    /// becomes the window length when it is known.
    static func shortLabel(for window: UsageWindow) -> String {
        guard let minutes = window.windowMinutes, minutes > 0,
            genericLabels.contains(window.label.lowercased())
        else { return window.label }
        return period(minutes: minutes)
    }

    /// `1_440` → `"1d"`, `300` → `"5h"`, `90` → `"90m"`.
    static func period(minutes: Int) -> String {
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// The spoken name of a window: `"5h"` → `"5-hour session"`, `"7d"` →
    /// `"Weekly"`, `"Opus 7d"` → `"Opus weekly"`. Other labels pass through.
    static func title(for window: UsageWindow) -> String {
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
    static func resetLabel(for window: UsageWindow, now: Date) -> String {
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
    static func spokenReset(
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
    static func hourlyAverageText(_ hourly: Double) -> String {
        guard hourly.isFinite else { return "Average not available" }
        var number = String(format: "%.2f", (hourly * 100).rounded() / 100)
        while number.hasSuffix("0"), number.contains(".") { number.removeLast() }
        if number.hasSuffix(".") { number.removeLast() }
        return "Average \(number)% of this limit per hour"
    }

    /// `"Just updated"` under a minute, then `"5m ago"`, `"2h 3m ago"`.
    static func ageLabel(observedAt: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(observedAt)
        return seconds < 60 ? "Just updated" : UsagePace.durationLabel(seconds) + " ago"
    }

    private static func wholeNumber(_ label: String, suffix: Character) -> Int? {
        guard label.last == suffix else { return nil }
        let digits = label.dropLast()
        guard !digits.isEmpty, digits.count <= 4, digits.allSatisfy({ $0.isASCII && $0.isNumber })
        else { return nil }
        return Int(digits)
    }
}

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
