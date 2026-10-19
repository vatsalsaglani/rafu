import Foundation
import SwiftUI
import Testing

@testable import RafuApp

// Synthetic data only: no test here reads `~`, the network, or a Keychain.

// 2026-07-23T10:00:00Z, a Thursday.
private let clusterNow = Date(timeIntervalSince1970: 1_784_800_800)
private let clusterCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let clusterLocale = Locale(identifier: "en_US")

private func window(
    _ label: String, percent: Double?, resetIn: TimeInterval? = nil, tokens: Int? = nil
) -> UsageWindow {
    UsageWindow(
        label: label, percent: percent, tokens: tokens,
        resetsAt: resetIn.map { clusterNow.addingTimeInterval($0) })
}

private func snapshot(_ windows: [UsageWindow]) -> UsageSnapshot {
    UsageSnapshot(providerID: .claude, windows: windows, costLine: nil, identity: nil)
}

private func cluster(
    _ windows: [UsageWindow], mode: UsageDisplayMode = .used,
    maxArcs: Int = UsageRingCluster.maxArcs,
    displayName: String = "Claude"
) -> UsageRingCluster? {
    UsageRingClusterBuilder.make(
        snapshot: snapshot(windows), observedAt: clusterNow, mode: mode, displayName: displayName,
        now: clusterNow, maxArcs: maxArcs, calendar: clusterCalendar, locale: clusterLocale)
}

// MARK: - Cluster shape

@Test("A token-only snapshot draws no cluster — the token-line card path stays unchanged")
func clusterTokenOnlyIsNil() {
    let windows = [window("5h", percent: nil, tokens: 120_000)]
    #expect(cluster(windows) == nil)
}

@Test("An empty snapshot draws no cluster")
func clusterEmptySnapshotIsNil() {
    #expect(cluster([]) == nil)
}

@Test(
    "Two windows become two arcs with primary/secondary tones; the centre text is the outer ring's")
func clusterTwoWindows() throws {
    let windows = [window("5h", percent: 83, resetIn: 4 * 3_600), window("7d", percent: 36)]
    let built = try #require(cluster(windows))
    #expect(built.arcs.count == 2)
    #expect(built.overflow.isEmpty)
    #expect(built.arcs.map(\.tone) == [.primary, .secondary])
    #expect(built.centerText == built.arcs[0].percentText)
    #expect(built.centerText == "83%")
    #expect(built.legend.count == 2)
}

@Test(
    "Six windows (Claude's maximum) cap at three drawn rings; the rest stay legend-only, tertiary")
func clusterSixWindowsOverflow() throws {
    let windows = (0..<6).map { window("w\($0)", percent: Double($0 + 1) * 10) }
    let built = try #require(cluster(windows))
    #expect(built.arcs.count == 3)
    #expect(built.overflow.count == 3)
    #expect(built.legend.count == 6)
    #expect(built.overflow.allSatisfy { $0.tone == .tertiary })
}

// MARK: - Fraction, percent text, and level

@Test("A window at exactly 100% used clamps to a full ring and \"100%\", never past it")
func clusterFullWindowClamps() throws {
    let built = try #require(cluster([window("5h", percent: 100)]))
    #expect(built.arcs[0].fraction == 1)
    #expect(built.arcs[0].percentText == "100%")
}

@Test(
    "A window whose percent is out of the 0...100 range or non-finite is treated as not reported — the SAME filter `UsageWindowPresentation.usedPercent` already applies, so it never reaches a ring at all (mirrors Claude's own clamp-at-parse-time contract)"
)
func clusterInvalidPercentNeverBecomesARing() {
    #expect(cluster([window("5h", percent: .nan)]) == nil)
    #expect(cluster([window("5h", percent: 140)]) == nil)
    // Mixed with a valid window: the invalid one is simply absent, not a
    // legend row reading "—".
    let built = cluster([window("5h", percent: 50), window("7d", percent: .nan)])
    #expect(built?.legend.count == 1)
}

@Test("Remaining mode shows the complementary percentage; the LEVEL still follows the used share")
func clusterRemainingModeUsesComplementButLevelFollowsUsed() throws {
    let built = try #require(cluster([window("5h", percent: 83)], mode: .remaining))
    let arc = built.arcs[0]
    #expect(abs((arc.fraction ?? -1) - 0.17) < 0.001)
    #expect(arc.percentText == "17%")
    #expect(arc.level == .warning)  // 83% used, not 17% remaining.
}

@Test("Ring levels at the used-percentage thresholds: 80 warns, 95 is critical")
func clusterLevelThresholds() throws {
    let warning = try #require(cluster([window("5h", percent: 80)]))
    #expect(warning.arcs[0].level == .warning)
    let critical = try #require(cluster([window("5h", percent: 95)]))
    #expect(critical.arcs[0].level == .critical)
}

// MARK: - Accessibility label

@Test(
    "The accessibility label joins every drawn arc; Remaining names \"remaining\" once, on the provider"
)
func clusterAccessibilityLabel() throws {
    let five = window("5h", percent: 83, resetIn: 4 * 3_600)
    let weekly = window("7d", percent: 36, resetIn: 3 * 86_400)
    let built = try #require(cluster([five, weekly], mode: .used, displayName: "Claude"))

    let fiveSpoken = UsageWindowPresentation.spokenReset(
        for: five, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
    let weeklySpoken = UsageWindowPresentation.spokenReset(
        for: weekly, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)

    #expect(
        built.accessibilityLabel
            == "Claude, 5-hour session 83%, \(fiveSpoken); Weekly 36%, \(weeklySpoken)")

    let remaining = try #require(cluster([five, weekly], mode: .remaining, displayName: "Claude"))
    #expect(
        remaining.accessibilityLabel
            == "Claude remaining, 5-hour session 17%, \(fiveSpoken); Weekly 64%, \(weeklySpoken)")
}

// MARK: - Spoken reset

@Test("Spoken reset: same day gives a time, no reset gives \"reset time unknown\"")
func spokenResetSameDayAndUnknown() {
    let sameDay = window("5h", percent: 1, resetIn: 4 * 3_600 + 20 * 60)
    var style = Date.FormatStyle(date: .omitted, time: .shortened).locale(clusterLocale)
    style.timeZone = clusterCalendar.timeZone
    let expectedTime = sameDay.resetsAt!.formatted(style)
    #expect(
        UsageWindowPresentation.spokenReset(
            for: sameDay, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
            == "resets " + expectedTime)

    let noReset = window("5h", percent: 1)
    #expect(
        UsageWindowPresentation.spokenReset(
            for: noReset, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
            == "reset time unknown")
}

@Test("Spoken reset: within the next 7 days gives a weekday; at or before now gives \"reset due\"")
func spokenResetWeekdayAndDue() {
    let threeDays = window("7d", percent: 1, resetIn: 3 * 86_400)
    var weekdayStyle = Date.FormatStyle().weekday(.wide).locale(clusterLocale)
    weekdayStyle.timeZone = clusterCalendar.timeZone
    let expectedWeekday = threeDays.resetsAt!.formatted(weekdayStyle)
    #expect(
        UsageWindowPresentation.spokenReset(
            for: threeDays, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
            == "resets " + expectedWeekday)

    let past = window("5h", percent: 1, resetIn: -60)
    #expect(
        UsageWindowPresentation.spokenReset(
            for: past, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
            == "reset due")
    let dueNow = window("5h", percent: 1, resetIn: 0)
    #expect(
        UsageWindowPresentation.spokenReset(
            for: dueNow, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
            == "reset due")
}

@Test("Spoken reset: past the next 7 days gives an abbreviated date")
func spokenResetAbbreviatedDate() {
    let farOut = window("30d", percent: 1, resetIn: 8 * 86_400)
    var dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted).locale(clusterLocale)
    dateStyle.timeZone = clusterCalendar.timeZone
    let expectedDate = farOut.resetsAt!.formatted(dateStyle)
    #expect(
        UsageWindowPresentation.spokenReset(
            for: farOut, now: clusterNow, calendar: clusterCalendar, locale: clusterLocale)
            == "resets " + expectedDate)
}

// MARK: - RafuProgressRing geometry

@Test(
    "RafuProgressRing's ring diameters shrink inward and skip once a ring is too small for its cap")
func progressRingDiameterSkipRule() {
    // Full-size config (76/7/3): three rings all comfortably fit.
    let full = RafuProgressRing.diameters(count: 3, size: 76, lineWidth: 7, gap: 3)
    #expect(full == [76, 56, 36])

    // Compact-size config (38/3/1.5): three rings all fit too.
    let compact = RafuProgressRing.diameters(count: 3, size: 38, lineWidth: 3, gap: 1.5)
    #expect(compact == [38, 29, 20])

    // A deliberately crowded configuration: ring 0 (20) fits; ring 1
    // (20 - 2*6 = 8) is under `lineWidth * 2` (12) and skipped; ring 2
    // (20 - 2*2*6 = -4) is negative and skipped too.
    let crowded = RafuProgressRing.diameters(count: 3, size: 20, lineWidth: 6, gap: 0)
    #expect(crowded == [20, nil, nil])

    #expect(RafuProgressRing.diameters(count: 0, size: 76, lineWidth: 7, gap: 3).isEmpty)
}
