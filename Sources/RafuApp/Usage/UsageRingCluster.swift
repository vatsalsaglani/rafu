import Foundation

/// The colour slot a ring/legend row occupies in a cluster — an ordinal,
/// never a `Color` itself, so this type stays UI-agnostic and
/// headless-testable. `UsageCardInk.color(for:level:)` resolves it against
/// the active theme (Settings) or `NotchInk` (the notch).
nonisolated enum UsageRingTone: Equatable, Sendable {
    case primary, secondary, tertiary
}

/// One ring's presentation, distilled from a `UsageWindow` and its
/// `UsagePace`. Pure: nothing here reads a clock or a theme, and every
/// field is `Equatable`/`Sendable` so a cluster can be compared in a test.
nonisolated struct UsageRingArc: Equatable, Sendable {
    /// `"5h"`, `"7d"` — the ring's short caption (`UsageWindowPresentation.
    /// shortLabel`).
    let shortLabel: String
    /// `"5-hour session"`, `"Weekly"` — the spoken title
    /// (`UsageWindowPresentation.title`).
    let title: String
    /// `0...1`, clamped; `nil` when the window carries no usable
    /// percentage (`UsageRingLevel.fraction`).
    let fraction: Double?
    /// `"83%"` / `"—"` — derived from the SAME `fraction` above, so the
    /// centre text and the legend can never disagree with the ring.
    let percentText: String
    let level: UsageRingLevel
    let tone: UsageRingTone
    /// `"↻ 2h 10m"`, `"Reset due"` (`UsageWindowPresentation.resetLabel`).
    let resetText: String
    /// `"resets 4:20 PM"`, `"reset due"` (`UsageWindowPresentation.
    /// spokenReset`) — the spoken form VoiceOver reads.
    let resetSpoken: String
    let pace: UsagePace
}

/// One provider's Activity-style ring cluster: up to `maxArcs` concentric
/// rings, plus a legend row for EVERY window the provider reports —
/// including windows past `maxArcs`, which show in the legend only (no
/// ring). Claude alone can emit up to six windows at once
/// (agent-usage-providers.md), so the overflow partition is not a rare
/// edge case.
nonisolated struct UsageRingCluster: Equatable, Sendable {
    /// The ring view never draws more than this many concentric rings —
    /// past this, the rings crowd into unreadable hairlines.
    static let maxArcs = 3

    /// The arcs actually drawn as rings, outermost first.
    let arcs: [UsageRingArc]
    /// Windows past `maxArcs`: legend rows only, no ring. Tone is clamped
    /// to `.tertiary` (`UsageRingClusterBuilder.tone(forIndex:maxArcs:)`).
    let overflow: [UsageRingArc]
    /// The outermost ring's percent — the cluster's centre text.
    let centerText: String
    /// One sentence covering every window, read as a single VoiceOver
    /// element (`UsageRingClusterView` sets `.accessibilityElement(children:
    /// .ignore)`).
    let accessibilityLabel: String

    /// Every row the legend renders: `arcs`, then `overflow`.
    var legend: [UsageRingArc] { arcs + overflow }
}

/// Builds a `UsageRingCluster` from a snapshot. `nonisolated` and
/// clock-free: callers pass `now`, `calendar`, and `locale` explicitly, so
/// the result never depends on ambient state the caller did not choose.
nonisolated enum UsageRingClusterBuilder {
    /// `nil` when the snapshot has no window with a usable percentage — the
    /// token-only and "No usage yet" card paths stay unchanged.
    static func make(
        snapshot: UsageSnapshot, observedAt: Date?, mode: UsageDisplayMode, displayName: String,
        now: Date, maxArcs: Int = UsageRingCluster.maxArcs, calendar: Calendar = .current,
        locale: Locale = .current
    ) -> UsageRingCluster? {
        let windows = UsageCardPresentation.ringWindows(snapshot)
        guard !windows.isEmpty else { return nil }
        let arcCap = max(1, maxArcs)

        let allArcs = windows.enumerated().map { index, window in
            arc(
                for: window, index: index, arcCap: arcCap, observedAt: observedAt, mode: mode,
                now: now, calendar: calendar, locale: locale)
        }
        let arcs = Array(allArcs.prefix(arcCap))
        let overflow = Array(allArcs.dropFirst(arcCap))
        return UsageRingCluster(
            arcs: arcs, overflow: overflow, centerText: arcs.first?.percentText ?? "—",
            accessibilityLabel: accessibilityLabel(
                displayName: displayName, mode: mode, arcs: allArcs))
    }

    private static func arc(
        for window: UsageWindow, index: Int, arcCap: Int, observedAt: Date?, mode: UsageDisplayMode,
        now: Date, calendar: Calendar, locale: Locale
    ) -> UsageRingArc {
        let pace = UsagePace.estimate(window: window, observedAt: observedAt, now: now)
        let level = UsageRingLevel.level(
            usedPercent: UsageWindowPresentation.usedPercent(window), pace: pace)
        let fraction = UsageRingLevel.fraction(percent: mode.percent(for: window))
        let percentText = fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        return UsageRingArc(
            shortLabel: UsageWindowPresentation.shortLabel(for: window),
            title: UsageWindowPresentation.title(for: window), fraction: fraction,
            percentText: percentText, level: level, tone: tone(forIndex: index, arcCap: arcCap),
            resetText: UsageWindowPresentation.resetLabel(for: window, now: now),
            resetSpoken: UsageWindowPresentation.spokenReset(
                for: window, now: now, calendar: calendar, locale: locale),
            pace: pace)
    }

    /// The first two arcs get their own tone; every arc from the third ring
    /// on — including every overflow, legend-only row — shares `.tertiary`.
    private static func tone(forIndex index: Int, arcCap: Int) -> UsageRingTone {
        guard index < arcCap else { return .tertiary }
        switch index {
        case 0: return .primary
        case 1: return .secondary
        default: return .tertiary
        }
    }

    /// `"Claude, 5-hour session 83%, resets 4:20 PM; Weekly 64%, resets
    /// Friday"`. Remaining mode names "remaining" once, on the provider
    /// name, never once per window.
    private static func accessibilityLabel(
        displayName: String, mode: UsageDisplayMode, arcs: [UsageRingArc]
    ) -> String {
        let name = mode == .remaining ? "\(displayName) remaining" : displayName
        let windows = arcs.map { arc -> String in
            let value = arc.percentText == "—" ? "not reported" : arc.percentText
            return "\(arc.title) \(value), \(arc.resetSpoken)"
        }
        return "\(name), " + windows.joined(separator: "; ")
    }
}
