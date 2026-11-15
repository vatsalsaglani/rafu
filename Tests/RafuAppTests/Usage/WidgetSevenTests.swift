import Foundation
import RafuCore
import RafuWidgetShared
import Testing

@testable import RafuApp

// Widget W3: the Seven presentation, the snapshot's `dailyEstimated`
// field, and the publisher's estimate and widget kind. Synthetic data
// only: nothing here reads `~`, the network, or a Keychain.

// 2026-07-23T10:00:00Z, a Thursday.
private let sevenNow = Date(timeIntervalSince1970: 1_784_800_800)
private let sevenCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let sevenLocale = Locale(identifier: "en_US")
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

/// A weekly window `elapsedHours` into its 7 days.
private func week(
    used: Double, elapsedHours: Double, daily: [Double?]? = nil, estimated: Bool? = nil
) -> WidgetUsageSnapshot.Window {
    let reset = sevenNow.addingTimeInterval((168 - elapsedHours) * hour)
    return WidgetUsageSnapshot.Window(
        label: "7d", usedPercent: used, resetsAt: reset, windowMinutes: 10_080,
        windowStart: daily == nil ? nil : reset.addingTimeInterval(-7 * day), daily: daily,
        dailyEstimated: estimated)
}

private func provider(
    _ id: String, _ windows: [WidgetUsageSnapshot.Window], observedAt: Date = sevenNow,
    isStale: Bool = false, tokenSummary: String? = nil
) -> WidgetUsageSnapshot.Provider {
    WidgetUsageSnapshot.Provider(
        id: id, displayName: id.prefix(1).uppercased() + id.dropFirst(), observedAt: observedAt,
        isStale: isStale, windows: windows, source: "providerAPI", tokenSummary: tokenSummary)
}

private func snapshot(
    _ providers: [WidgetUsageSnapshot.Provider], writtenAt: Date = sevenNow,
    mode: String = "used"
) -> WidgetUsageSnapshot {
    WidgetUsageSnapshot(
        writtenAt: writtenAt, displayMode: mode, palette: "color", isSample: false,
        providers: providers)
}

private func present(_ snapshot: WidgetUsageSnapshot?, at now: Date = sevenNow, max: Int = 2)
    -> WidgetSevenPresentation
{
    WidgetSevenPresentation.make(
        snapshot: snapshot, now: now, maxProviders: max, calendar: sevenCalendar,
        locale: sevenLocale)
}

private func cards(_ presentation: WidgetSevenPresentation) throws -> [WidgetSevenCard] {
    guard case .providers(let cards) = presentation.content else {
        Issue.record("expected providers, got \(presentation.content)")
        throw CancellationError()
    }
    return cards
}

private func firstCard(_ presentation: WidgetSevenPresentation) throws -> WidgetSevenCard {
    try #require(try cards(presentation).first)
}

/// Claude on day 6 of 7 at 41%. The window started Friday 18:00 UTC, so
/// the slice midpoints fall on Saturday … Friday.
private let claudeDay6 = provider(
    "claude", [week(used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil])])

@Suite struct WidgetSevenPresentationTests {
    @Test func columnsHoldOneDotPerPercentOfEachDay() throws {
        let card = try firstCard(present(snapshot([claudeDay6])))
        let columns = try #require(card.columns)
        #expect(columns.count == 7)
        #expect(columns.map(\.percent) == [7, 9, 5, 8, 6, 6, nil])
        #expect(columns.map(\.filled) == [7, 9, 5, 8, 6, 6, 0])
        #expect(columns.map(\.kind) == [.past, .past, .past, .past, .past, .today, .future])
        #expect(columns.map(\.label) == ["S", "S", "M", "T", "W", "T", "F"])
        #expect(columns.map(\.overflow).allSatisfy { $0 == 0 })
        #expect(card.hasDailySplit)
        #expect(card.headline == "41%")
        #expect(card.headlineCaption == "used")
        #expect(card.dayText == "Day 6 of 7")
        #expect(card.todayText == "6% today")
        #expect(card.resetsAt == sevenNow.addingTimeInterval(32 * hour))
        #expect(card.status.longText(now: sevenNow) == "On pace · ~49% spare at reset")
    }

    @Test func columnsAddUpToTheHeadlineAfterRounding() throws {
        let fractional = provider(
            "claude",
            [week(used: 20, elapsedHours: 60, daily: [6.4, 6.4, 7.2, nil, nil, nil, nil])])
        let columns = try #require(try firstCard(present(snapshot([fractional]))).columns)
        #expect(columns.compactMap(\.percent).reduce(0, +) == 20)
        #expect(columns.map(\.percent) == [6, 7, 7, nil, nil, nil, nil])
    }

    @Test func todayAndFutureShowHollowDotsUpToThePaceLine() throws {
        let card = try firstCard(present(snapshot([claudeDay6])))
        let columns = try #require(card.columns)
        #expect(columns[5].hollow == 14 - 6)
        #expect(columns[6].hollow == 14)
        #expect(columns[0...4].allSatisfy { $0.hollow == 0 })
        // A day already above the line has no hollow dots.
        let heavy = provider(
            "claude", [week(used: 20, elapsedHours: 30, daily: [2, 18, nil, nil, nil, nil, nil])])
        let today = try #require(try firstCard(present(snapshot([heavy]))).columns?[1])
        #expect(today.kind == .today)
        #expect(today.filled == 16)
        #expect(today.hollow == 0)
    }

    @Test func aDayTallerThanItsColumnIsCappedWithOverflow() throws {
        let heavy = provider(
            "claude", [week(used: 35, elapsedHours: 30, daily: [30, 5, nil, nil, nil, nil, nil])])
        let columns = try #require(try firstCard(present(snapshot([heavy]))).columns)
        #expect(WidgetSevenPresentation.maxDotsPerColumn == 16)
        #expect(columns[0].percent == 30)
        #expect(columns[0].filled == 16)
        #expect(columns[0].overflow == 14)
        #expect(columns[1].overflow == 0)
    }

    @Test func futureDaysHaveNoUse() throws {
        let codex = provider(
            "codex", [week(used: 34, elapsedHours: 86, daily: [10, 9, 8, 7, nil, nil, nil])])
        let columns = try #require(try firstCard(present(snapshot([codex]))).columns)
        #expect(columns.map(\.kind) == [.past, .past, .past, .today, .future, .future, .future])
        #expect(columns[4...].allSatisfy { $0.percent == nil && $0.filled == 0 })
        #expect(columns[4...].allSatisfy { $0.hollow == 14 })
    }

    @Test func todayMovesAtTheDayBoundary() throws {
        // 143 hours in; two hours later the window enters day 7: Thursday
        // is past and the new day has nothing yet.
        let lateDay6 = provider(
            "claude", [week(used: 41, elapsedHours: 143, daily: [7, 9, 5, 8, 6, 6, nil])])
        let later = sevenNow.addingTimeInterval(2 * hour)
        let card = try firstCard(present(snapshot([lateDay6]), at: later))
        let columns = try #require(card.columns)
        #expect(columns[5].kind == .past)
        #expect(columns[6].kind == .today)
        #expect(columns[6].percent == 0)
        #expect(card.todayText == "0% today")
        #expect(card.dayText == "Day 7 of 7")
    }

    @Test func usedModePaceLineIsAnEvenDay() throws {
        let card = try firstCard(present(snapshot([claudeDay6])))
        #expect(abs(card.paceLinePercent - 100.0 / 7) < 0.0001)
        #expect(abs(card.paceLineRow - 100.0 / 14) < 0.0001)
        #expect(card.paceLineText == "Even pace · 14% a day")
    }

    @Test func remainingModeShowsLeftAndTheDailyShareOfIt() throws {
        let early = provider(
            "claude", [week(used: 10, elapsedHours: 30, daily: [6, 4, nil, nil, nil, nil, nil])])
        let presentation = present(snapshot([early], mode: "remaining"))
        #expect(presentation.mode == .remaining)
        let card = try firstCard(presentation)
        #expect(card.headline == "90%")
        #expect(card.headlineCaption == "left")
        // (90 left + 4 used today) over 6 days left including today.
        #expect(abs(card.paceLinePercent - 94.0 / 6) < 0.0001)
        #expect(card.paceLineText == "Each day left · ~16%")
        let columns = try #require(card.columns)
        // Columns still count use, so a day reads the same in both modes.
        #expect(columns.map(\.filled)[0...1] == [6, 4])
        #expect(columns[1].hollow == 16 - 4)
        #expect(columns[2].hollow == 16)
        #expect(presentation.accessibilityLabel.contains("weekly limit 90 percent left"))
        #expect(presentation.accessibilityLabel.contains("about 16 percent for each day left"))
    }

    @Test func remainingModePaceLineCapsAtTheTopRow() throws {
        let card = try firstCard(present(snapshot([claudeDay6], mode: "remaining")))
        // (59 + 6) / 2 days left.
        #expect(abs(card.paceLinePercent - 32.5) < 0.0001)
        #expect(card.paceLineRow == Double(WidgetSevenPresentation.rows))
        #expect(card.columns?[6].hollow == 16)
    }

    @Test func estimatedSplitIsFlagged() throws {
        let estimated = provider(
            "claude",
            [week(used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil], estimated: true)])
        let presentation = present(snapshot([estimated]))
        let card = try firstCard(presentation)
        #expect(card.isEstimated)
        #expect(presentation.accessibilityLabel.contains("daily values estimated"))
        #expect(try !firstCard(present(snapshot([claudeDay6]))).isEstimated)
    }

    @Test func withoutADaySplitTheColumnsShowOnlyThePace() throws {
        let plain = provider("claude", [week(used: 41, elapsedHours: 136, estimated: true)])
        let presentation = present(snapshot([plain]))
        let card = try firstCard(presentation)
        #expect(!card.hasDailySplit)
        #expect(!card.isEstimated)
        #expect(card.todayText == nil)
        #expect(card.dayText == "Day 6 of 7")
        let columns = try #require(card.columns)
        #expect(columns.allSatisfy { $0.percent == nil && $0.filled == 0 })
        #expect(columns[5].hollow == 14)
        #expect(!presentation.accessibilityLabel.contains("so far"))
    }

    @Test func staleDataIsDimmed() throws {
        let stale = provider(
            "claude", [week(used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil])],
            observedAt: sevenNow.addingTimeInterval(-25 * 60))
        let card = try firstCard(present(snapshot([stale])))
        #expect(card.isDimmed)
        #expect(card.status == .stale(age: 25 * 60))
        #expect(card.columns?[5].percent == 6)
    }

    @Test func aPassedResetHasNoColumns() throws {
        // The reset is one hour after the observation; read two hours on.
        let lastHour = provider(
            "claude", [week(used: 70, elapsedHours: 167, daily: [10, 10, 10, 10, 10, 10, 10])])
        let card = try firstCard(
            present(snapshot([lastHour]), at: sevenNow.addingTimeInterval(2 * hour)))
        #expect(card.status == .resetPassed)
        #expect(card.columns == nil)
        #expect(card.headline == "—")
        #expect(card.isDimmed)
    }

    @Test func notConnectedAbandonedAndLocalEstimateStates() throws {
        #expect(present(nil).content == .notConnected(.noData))
        #expect(present(snapshot([])).content == .notConnected(.noData))
        let old = snapshot([claudeDay6], writtenAt: sevenNow.addingTimeInterval(-7 * hour))
        let abandoned = present(old)
        #expect(abandoned.content == .notConnected(.rafuNotRunning))
        #expect(abandoned.accessibilityLabel.contains("Rafu is not running"))
        let local = provider("claude", [], tokenSummary: "7d 1.4M tok")
        let card = try firstCard(present(snapshot([local])))
        #expect(card.status == .localEstimate)
        #expect(card.columns == nil)
        #expect(card.tokenSummary == "7d 1.4M tok")
    }

    @Test func twoProvidersDifferByShape() throws {
        let codex = provider(
            "codex", [week(used: 34, elapsedHours: 86, daily: [10, 9, 8, 7, nil, nil, nil])])
        let pair = try cards(present(snapshot([claudeDay6, codex])))
        #expect(pair.map(\.shape) == [.circle, .roundedSquare])
        // Two providers that both default to circles still differ.
        let other = provider("gemini", [week(used: 5, elapsedHours: 10)])
        let alternate = try cards(present(snapshot([other, claudeDay6])))
        #expect(alternate.map(\.shape) == [.circle, .roundedSquare])
        // Medium shows one provider.
        #expect(try cards(present(snapshot([claudeDay6, codex]), max: 1)).count == 1)
    }

    @Test func voiceOverSentenceListsEachDay() throws {
        let presentation = present(snapshot([claudeDay6]))
        #expect(
            presentation.accessibilityLabel
                == "Claude, weekly limit 41 percent used, day 6 of 7, Saturday 7 percent, Sunday 9 percent, Monday 5 percent, Tuesday 8 percent, Wednesday 6 percent, today 6 percent so far, on pace, about 49 percent spare at reset, resets Friday"
        )
        #expect(!presentation.accessibilityLabel.contains("~"))
        #expect(!presentation.accessibilityLabel.contains("·"))
    }
}

@Suite struct WidgetSevenSnapshotTests {
    @Test func aVersionThreeFileWithoutTheEstimateDecodesAsExact() throws {
        let v3 = """
            {"displayMode":"used","isSample":false,"palette":"color","providers":[\
            {"displayName":"Claude","id":"claude","isStale":false,\
            "observedAt":"2026-07-23T10:00:00Z","source":"providerAPI","windows":[{"label":"7d",\
            "resetsAt":"2026-07-24T18:00:00Z","usedPercent":41,"windowMinutes":10080,\
            "windowStart":"2026-07-17T18:00:00Z","daily":[7,9,5,8,6,6,null]}]}],\
            "version":3,"writtenAt":"2026-07-23T10:00:00Z"}
            """
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(Data(v3.utf8)))
        let window = decoded.providers[0].windows[0]
        #expect(window.dailyEstimated == nil)
        #expect(!window.isDailyEstimated)
        #expect(window.daily == [7, 9, 5, 8, 6, 6, nil])
    }

    @Test func roundTripsTheEstimate() throws {
        let original = snapshot([
            provider(
                "claude",
                [
                    week(
                        used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil], estimated: true
                    )
                ])
        ])
        let decoded = try WidgetSnapshotStore.decode(WidgetSnapshotStore.encode(original))
        #expect(decoded == original)
        #expect(decoded.providers[0].windows[0].isDailyEstimated)
    }

    @Test func publisherWritesTheEstimate() {
        let reset = sevenNow.addingTimeInterval(4 * day)
        let start = reset.addingTimeInterval(-7 * day)
        let weekly = WidgetUsageSnapshot.Window(
            label: "7d", usedPercent: 30, resetsAt: reset, windowMinutes: 10_080)
        let widget = snapshot([provider("claude", [weekly])])
        // One record two days in: the first two days are interpolated.
        let sparse = UsageSampleLog(records: [
            UsageSampleRecord(
                providerID: "claude", window: "7d", usedPercent: 25, resetsAt: reset,
                observedAt: start.addingTimeInterval(2 * day))
        ])
        let estimated = WidgetSnapshotPublisher.attachDaily(widget, log: sparse)
        #expect(estimated.providers[0].windows[0].dailyEstimated == true)
        // Records every 15 minutes up to now: exact.
        let dense = UsageSampleLog(
            records: stride(from: 900.0, to: 3 * day, by: 900).map { offset in
                UsageSampleRecord(
                    providerID: "claude", window: "7d", usedPercent: 30 * offset / (3 * day),
                    resetsAt: reset, observedAt: start.addingTimeInterval(offset))
            })
        let exact = WidgetSnapshotPublisher.attachDaily(widget, log: dense)
        #expect(exact.providers[0].windows[0].dailyEstimated == false)
    }

    @Test func publisherReloadsTheSevenWidget() {
        #expect(
            WidgetSnapshotPublisher.widgetKinds.contains("dev.vatsalsaglani.rafu.widgets.seven"))
        #expect(WidgetSnapshotPublisher.widgetKinds.count == 3)
    }
}
