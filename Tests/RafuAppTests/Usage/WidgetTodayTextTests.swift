import Foundation
import RafuCore
import RafuWidgetShared
import Testing

@testable import RafuApp

// "N% today" counts from the user's local midnight, not from the 24-hour
// slice of the limit window. Synthetic data only: nothing here reads `~`,
// the network, or a Keychain.

// 2026-07-23T10:00:00Z, a Thursday.
private let todayNow = Date(timeIntervalSince1970: 1_784_800_800)
private let todayHour: TimeInterval = 3_600
private let todayDay: TimeInterval = 86_400

private func calendar(_ zone: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: zone)!
    return calendar
}

private let utc = calendar("UTC")
private let kolkata = calendar("Asia/Kolkata")
private let todayLocale = Locale(identifier: "en_US")
/// 2026-07-23T00:00:00Z.
private let utcMidnight = utc.startOfDay(for: todayNow)

/// A weekly window 136 hours into its 7 days (day 6, slice value 6 of 41).
private func window(todayUsed: Double?, todayStart: Date? = utcMidnight)
    -> WidgetUsageSnapshot.Window
{
    let reset = todayNow.addingTimeInterval(32 * todayHour)
    return WidgetUsageSnapshot.Window(
        label: "7d", usedPercent: 41, resetsAt: reset, windowMinutes: 10_080,
        windowStart: reset.addingTimeInterval(-7 * todayDay), daily: [7, 9, 5, 8, 6, 6, nil],
        todayStart: todayUsed == nil ? nil : todayStart, todayUsed: todayUsed)
}

/// The snapshot the app wrote at `observed`; the widget reads it at `now`.
private func snapshot(_ window: WidgetUsageSnapshot.Window, observed: Date = todayNow)
    -> WidgetUsageSnapshot
{
    WidgetUsageSnapshot(
        writtenAt: observed, displayMode: "used", palette: "color", isSample: false,
        providers: [
            WidgetUsageSnapshot.Provider(
                id: "claude", displayName: "Claude", observedAt: observed, isStale: false,
                windows: [window], source: "providerAPI")
        ])
}

private func hundredCard(
    _ window: WidgetUsageSnapshot.Window, at now: Date = todayNow, observed: Date? = nil
) throws -> WidgetHundredCard {
    let presentation = WidgetHundredPresentation.make(
        snapshot: snapshot(window, observed: observed ?? now), now: now, maxProviders: 2,
        calendar: utc, locale: todayLocale)
    guard case .providers(let cards) = presentation.content, let card = cards.first else {
        Issue.record("expected a provider card")
        throw CancellationError()
    }
    return card
}

private func sevenCard(
    _ window: WidgetUsageSnapshot.Window, at now: Date = todayNow, observed: Date? = nil
) throws -> WidgetSevenCard {
    let presentation = WidgetSevenPresentation.make(
        snapshot: snapshot(window, observed: observed ?? now), now: now, maxProviders: 2,
        calendar: utc, locale: todayLocale)
    guard case .providers(let cards) = presentation.content, let card = cards.first else {
        Issue.record("expected a provider card")
        throw CancellationError()
    }
    return card
}

@Suite struct WidgetTodayTextTests {
    @Test func theSameCalendarDayShowsTheUsedSinceMidnight() throws {
        let hundred = try hundredCard(window(todayUsed: 5.2))
        #expect(hundred.todayText == "5% today")
        // The slice, and so the dots, keep the window-aligned count.
        #expect(hundred.counts?.today == 6)
        let seven = try sevenCard(window(todayUsed: 5.2))
        #expect(seven.todayText == "5% today")
        #expect(seven.columns?[5].kind == .today)
        #expect(seven.columns?[5].percent == 6)
    }

    @Test func aNewCalendarDayShowsZero() throws {
        // The app wrote the snapshot at 23:50 UTC on the 22nd, with the
        // 22nd as its day. The widget reads it at 00:10 UTC on the 23rd.
        let midnight = utcMidnight
        let observed = midnight.addingTimeInterval(-10 * 60)
        let later = midnight.addingTimeInterval(10 * 60)
        let old = window(todayUsed: 5.2, todayStart: midnight.addingTimeInterval(-todayDay))
        #expect(try hundredCard(old, at: later, observed: observed).todayText == "0% today")
        #expect(try sevenCard(old, at: later, observed: observed).todayText == "0% today")
        // Before midnight the same snapshot still shows the value.
        #expect(try hundredCard(old, at: observed, observed: observed).todayText == "5% today")
    }

    @Test func aUseUnderHalfAPercentShowsLessThanOne() throws {
        #expect(try hundredCard(window(todayUsed: 0.45)).todayText == "<1% today")
        #expect(try sevenCard(window(todayUsed: 0.45)).todayText == "<1% today")
        #expect(try hundredCard(window(todayUsed: 0)).todayText == "0% today")
        #expect(try hundredCard(window(todayUsed: 0.5)).todayText == "1% today")
    }

    @Test func withoutTheFieldsTheSliceCountShows() throws {
        let hundred = try hundredCard(window(todayUsed: nil))
        #expect(hundred.todayText == "6% today")
        #expect(try sevenCard(window(todayUsed: nil)).todayText == "6% today")
    }

    @Test func aPassedResetShowsNothing() throws {
        let afterReset = todayNow.addingTimeInterval(33 * todayHour)
        #expect(try hundredCard(window(todayUsed: 5.2), at: afterReset).todayText == nil)
        #expect(try sevenCard(window(todayUsed: 5.2), at: afterReset).todayText == nil)
    }

    @Test func theDayIsTheCalendarsDay() {
        // 2026-07-23T10:00Z is 15:30 on the 23rd in Kolkata; local midnight
        // was 2026-07-22T18:30Z.
        let midnight = kolkata.startOfDay(for: todayNow)
        let used = window(todayUsed: 3, todayStart: midnight)
        #expect(WidgetTodayText.text(window: used, now: todayNow, calendar: kolkata) == "3% today")
        // 19:00 UTC is the next local day in Kolkata, still the same day in UTC.
        let evening = todayNow.addingTimeInterval(9 * todayHour)
        #expect(WidgetTodayText.text(window: used, now: evening, calendar: kolkata) == "0% today")
        #expect(
            WidgetTodayText.percent(window: window(todayUsed: 3), now: evening, calendar: utc)
                == 3)
    }

    @Test func spokenTextFollowsTheCalendarDayValue() throws {
        let hundred = try hundredCard(window(todayUsed: 5.2))
        #expect(hundred.accessibilityLabel.contains("5 percent today"))
        #expect(!hundred.accessibilityLabel.contains("6 percent today"))
        let small = try hundredCard(window(todayUsed: 0.45))
        #expect(small.accessibilityLabel.contains("less than 1 percent today"))
        let seven = try sevenCard(window(todayUsed: 5.2))
        #expect(seven.accessibilityLabel.contains("today 5 percent so far"))
        let tiny = try sevenCard(window(todayUsed: 0.45))
        #expect(tiny.accessibilityLabel.contains("today less than 1 percent so far"))
        // An older snapshot keeps the slice wording.
        let old = try hundredCard(window(todayUsed: nil))
        #expect(old.accessibilityLabel.contains("6 percent today"))
        let oldSeven = try sevenCard(window(todayUsed: nil))
        #expect(oldSeven.accessibilityLabel.contains("today 6 percent so far"))
    }

    @Test func theRemainingPaceLineKeepsTheSliceCount() throws {
        let reset = todayNow.addingTimeInterval(32 * todayHour)
        var remaining = window(todayUsed: 5.2)
        remaining.resetsAt = reset
        let presentation = WidgetSevenPresentation.make(
            snapshot: WidgetUsageSnapshot(
                writtenAt: todayNow, displayMode: "remaining", palette: "color",
                isSample: false,
                providers: [
                    WidgetUsageSnapshot.Provider(
                        id: "claude", displayName: "Claude", observedAt: todayNow,
                        isStale: false, windows: [remaining], source: "providerAPI")
                ]),
            now: todayNow, maxProviders: 2, calendar: utc, locale: todayLocale)
        guard case .providers(let cards) = presentation.content, let card = cards.first else {
            Issue.record("expected a provider card")
            return
        }
        // (59 left + 6 slice) over 2 days left, not 5.2.
        #expect(card.paceLineText == "Each day left · ~33%")
    }
}

@Suite struct WidgetTodaySnapshotTests {
    @Test func decodesAVersionThreeFileWithoutTheTodayFields() throws {
        let v3 = """
            {"displayMode":"used","isSample":false,"palette":"color","providers":[\
            {"displayName":"Claude","id":"claude","isStale":false,\
            "observedAt":"2026-07-23T10:00:00Z","source":"providerAPI","windows":[{"label":"7d",\
            "resetsAt":"2026-07-24T18:00:00Z","usedPercent":41,"windowMinutes":10080,\
            "windowStart":"2026-07-17T18:00:00Z","daily":[7,9,5,8,6,6,null]}]}],\
            "version":3,"writtenAt":"2026-07-23T10:00:00Z"}
            """
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(Data(v3.utf8)))
        let weekly = decoded.providers[0].windows[0]
        #expect(weekly.daily?.count == 7)
        #expect(weekly.todayStart == nil)
        #expect(weekly.todayUsed == nil)
    }

    @Test func roundTripsTheTodayFields() throws {
        let original = snapshot(window(todayUsed: 5.2))
        let data = try WidgetSnapshotStore.encode(original)
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(data))
        #expect(decoded == original)
        #expect(decoded.providers[0].windows[0].todayUsed == 5.2)
        #expect(decoded.providers[0].windows[0].todayStart == utcMidnight)
    }

    @Test func thePublisherWritesTheLocalDayFields() throws {
        let reset = todayNow.addingTimeInterval(4 * todayDay)
        let start = reset.addingTimeInterval(-7 * todayDay)
        let log = UsageSampleLog(records: [
            UsageSampleRecord(
                providerID: "claude", window: "7d", usedPercent: 10, resetsAt: reset,
                observedAt: start.addingTimeInterval(todayDay)),
            UsageSampleRecord(
                providerID: "claude", window: "7d", usedPercent: 25, resetsAt: reset,
                observedAt: start.addingTimeInterval(2 * todayDay)),
        ])
        let widget = snapshot(
            WidgetUsageSnapshot.Window(
                label: "7d", usedPercent: 30, resetsAt: reset, windowMinutes: 10_080))
        let attached = WidgetSnapshotPublisher.attachDaily(widget, log: log, calendar: kolkata)
        let weekly = attached.providers[0].windows[0]
        // Kolkata midnight before 10:00 UTC on the 23rd is 18:30 UTC on the 22nd.
        let midnight = try #require(ISO8601DateFormatter().date(from: "2026-07-22T18:30:00Z"))
        #expect(weekly.todayStart == midnight)
        // 25% at 10:00 UTC on the 22nd, 30% at 10:00 UTC on the 23rd: the
        // level at 18:30 UTC is 25 + 5 × 8.5 / 24.
        let today = try #require(weekly.todayUsed)
        #expect(abs(today - (5 - 5 * 8.5 / 24)) < 0.001)
        // The day slices are unchanged and window-aligned.
        #expect(weekly.windowStart == start)
        #expect(weekly.daily?[2] == 5)

        // The UTC calendar gives the UTC midnight and a different value:
        // the level at 00:00 UTC on the 23rd is 25 + 5 × 14 / 24.
        let utcAttached = WidgetSnapshotPublisher.attachDaily(widget, log: log, calendar: utc)
        let utcWindow = utcAttached.providers[0].windows[0]
        #expect(utcWindow.todayStart == utcMidnight)
        #expect(abs((utcWindow.todayUsed ?? 0) - (5 - 5 * 14 / 24)) < 0.001)
    }
}
