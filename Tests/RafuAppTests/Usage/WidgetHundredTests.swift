import Foundation
import RafuCore
import RafuWidgetShared
import Testing

@testable import RafuApp

// Widget W2: snapshot v3, the Hundred presentation, the publisher's log
// records and day split, and the timeline's day boundaries. Synthetic data
// only: nothing here reads `~`, the network, or a Keychain.

// 2026-07-23T10:00:00Z, a Thursday.
private let hundredNow = Date(timeIntervalSince1970: 1_784_800_800)
private let hundredCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let hundredLocale = Locale(identifier: "en_US")
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

/// A weekly window `elapsedHours` into its 7 days.
private func week(
    used: Double, elapsedHours: Double, daily: [Double?]? = nil, label: String = "7d"
) -> WidgetUsageSnapshot.Window {
    let reset = hundredNow.addingTimeInterval((168 - elapsedHours) * hour)
    return WidgetUsageSnapshot.Window(
        label: label, usedPercent: used, resetsAt: reset, windowMinutes: 10_080,
        windowStart: daily == nil ? nil : reset.addingTimeInterval(-7 * day), daily: daily)
}

private func provider(
    _ id: String, _ windows: [WidgetUsageSnapshot.Window], observedAt: Date = hundredNow,
    isStale: Bool = false
) -> WidgetUsageSnapshot.Provider {
    WidgetUsageSnapshot.Provider(
        id: id, displayName: id.prefix(1).uppercased() + id.dropFirst(), observedAt: observedAt,
        isStale: isStale, windows: windows, source: "providerAPI")
}

private func snapshot(
    _ providers: [WidgetUsageSnapshot.Provider], writtenAt: Date = hundredNow,
    mode: String = "used"
) -> WidgetUsageSnapshot {
    WidgetUsageSnapshot(
        writtenAt: writtenAt, displayMode: mode, palette: "color", isSample: false,
        providers: providers)
}

private func present(_ snapshot: WidgetUsageSnapshot?, at now: Date = hundredNow, max: Int = 2)
    -> WidgetHundredPresentation
{
    WidgetHundredPresentation.make(
        snapshot: snapshot, now: now, maxProviders: max, calendar: hundredCalendar,
        locale: hundredLocale)
}

private func cards(_ presentation: WidgetHundredPresentation) throws -> [WidgetHundredCard] {
    guard case .providers(let cards) = presentation.content else {
        Issue.record("expected providers, got \(presentation.content)")
        throw CancellationError()
    }
    return cards
}

private func count(_ dots: [WidgetHundredDot]?, _ kind: WidgetHundredDot) -> Int {
    dots?.filter { $0 == kind }.count ?? 0
}

/// Claude on day 6 of 7 at 41%, with the sample day split.
private let claudeDay6 = provider(
    "claude", [week(used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil])])

@Suite struct WidgetSnapshotV3Tests {
    @Test func roundTripsTheDaySplit() throws {
        let original = snapshot([claudeDay6])
        let data = try WidgetSnapshotStore.encode(original)
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(data))
        #expect(decoded == original)
        #expect(decoded.version == 3)
        #expect(decoded.providers[0].windows[0].daily == [7, 9, 5, 8, 6, 6, nil])
        #expect(decoded.providers[0].windows[0].windowStart != nil)
    }

    @Test func decodesAVersionTwoFileWithoutTheDaySplit() throws {
        let v2 = """
            {"displayMode":"used","isSample":false,"palette":"color","providers":[\
            {"displayName":"Claude","id":"claude","isStale":false,\
            "observedAt":"2026-07-23T10:00:00Z","source":"providerAPI","windows":[{"label":"7d",\
            "resetsAt":"2026-07-24T18:00:00Z","usedPercent":41,"windowMinutes":10080}]}],\
            "version":2,"writtenAt":"2026-07-23T10:00:00Z"}
            """
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(Data(v2.utf8)))
        #expect(decoded.version == 2)
        #expect(decoded.providers[0].windows[0].daily == nil)
        #expect(decoded.providers[0].windows[0].windowStart == nil)
        // A v2 file still draws a grid, without a today group.
        let card = try #require(try cards(present(decoded)).first)
        #expect(card.counts?.used == 41)
        #expect(card.counts?.today == nil)
        #expect(card.todayText == nil)
        #expect(count(card.dots, .used(band: 0)) == 41)
    }

    @Test func decodesAVersionOneFile() throws {
        let v1 = """
            {"displayMode":"used","isSample":false,"palette":"color","providers":[\
            {"displayName":"Claude","id":"claude","isStale":false,\
            "observedAt":"2026-07-23T10:00:00Z","windows":[{"label":"7d",\
            "resetsAt":"2026-07-24T18:00:00Z","usedPercent":41,"windowMinutes":10080}]}],\
            "version":1,"writtenAt":"2026-07-23T10:00:00Z"}
            """
        let decoded = try #require(WidgetSnapshotStore.decodeSupported(Data(v1.utf8)))
        #expect(decoded.version == 1)
        #expect(decoded.providers[0].windows[0].daily == nil)
    }

    @Test func sampleDaySplitsAddUpToTheirPercent() {
        let sample = WidgetUsageSnapshot.sample(now: hundredNow)
        for provider in sample.providers {
            let weekly = provider.windows[0]
            let total = (weekly.daily ?? []).compactMap { $0 }.reduce(0, +)
            #expect(total == weekly.usedPercent)
        }
    }
}

@Suite struct WidgetHundredPresentationTests {
    @Test func mapsUsedTodayProjectedAndSpareDots() throws {
        let card = try #require(try cards(present(snapshot([claudeDay6]))).first)
        // Pace: 41% in 136 h projects 41 × 168 / 136 ≈ 51% at reset.
        #expect(card.counts?.used == 41)
        #expect(card.counts?.today == 6)
        #expect(card.counts?.projected == 10)
        #expect(card.counts?.spare == 49)
        let dots = try #require(card.dots)
        #expect(dots.count == 100)
        // Earlier days alternate bands: days 1, 3, 5 (7 + 5 + 6) and 2, 4 (9 + 8).
        #expect(count(dots, .used(band: 0)) == 18)
        #expect(count(dots, .used(band: 1)) == 17)
        #expect(count(dots, .today) == 6)
        // Time order: used, then today, then projected, then spare.
        #expect(dots[0] == .used(band: 0))
        #expect(dots[7] == .used(band: 1))
        #expect(dots[35] == .today)
        #expect(dots[41] == .projected)
        #expect(dots[51] == .spare)
        // 136 of 168 hours ≈ 81% of the week: the 81st dot.
        #expect(card.elapsedMarkerIndex == 80)
        #expect(card.headline == "41%")
        #expect(card.headlineCaption == "used")
        #expect(card.todayText == "6% today")
        #expect(card.dayText == "Day 6 of 7")
        #expect(card.shape == .circle)
    }

    @Test func remainingModeFillsFromTheEnd() throws {
        let card = try #require(try cards(present(snapshot([claudeDay6], mode: "remaining"))).first)
        let dots = try #require(card.dots)
        #expect(card.headline == "59%")
        #expect(card.headlineCaption == "left")
        #expect(dots.prefix(49).allSatisfy { $0 == .spare })
        #expect(dots[49] == .projected)
        #expect(dots[99] == .used(band: 0))
        #expect(card.elapsedMarkerIndex == 19)
        #expect(card.accessibilityLabel.contains("59 percent left"))
    }

    @Test func atTheLimitEveryDotIsUsed() throws {
        let full = provider("claude", [week(used: 100, elapsedHours: 120)])
        let card = try #require(try cards(present(snapshot([full]))).first)
        #expect(card.counts?.used == 100)
        #expect(card.counts?.projected == 0)
        #expect(card.counts?.spare == 0)
        #expect(card.status.shortText(now: hundredNow) == "■ At limit")
    }

    @Test func runningOutProjectsEveryRemainingDot() throws {
        let fast = provider("claude", [week(used: 60, elapsedHours: 48)])
        let card = try #require(try cards(present(snapshot([fast]))).first)
        #expect(card.counts?.used == 60)
        #expect(card.counts?.projected == 40)
        #expect(card.counts?.spare == 0)
    }

    @Test func staleDataHasNoProjection() throws {
        let old = hundredNow.addingTimeInterval(-hour)
        let stale = provider("claude", [week(used: 41, elapsedHours: 135)], observedAt: old)
        let card = try #require(try cards(present(snapshot([stale], writtenAt: old))).first)
        #expect(card.isDimmed)
        #expect(card.counts?.projected == 0)
        #expect(card.counts?.spare == 59)
    }

    @Test func aPassedResetEmptiesTheGrid() throws {
        let passed = provider("claude", [week(used: 41, elapsedHours: 170)])
        let card = try #require(try cards(present(snapshot([passed]))).first)
        #expect(card.status == .resetPassed)
        #expect(card.counts?.used == 0)
        #expect(card.counts?.spare == 100)
        #expect(card.headline == "—")
        #expect(card.elapsedMarkerIndex == nil)
    }

    @Test func aNewDayStartsWithNoDotsToday() throws {
        // The snapshot's day split ends on day 6; the entry is a day later.
        let later = hundredNow.addingTimeInterval(day)
        let written = later.addingTimeInterval(-5 * 60)
        var claude = claudeDay6
        claude.observedAt = written
        let card = try #require(
            try cards(present(snapshot([claude], writtenAt: written), at: later)).first)
        #expect(card.counts?.today == 0)
        #expect(card.dayText == "Day 7 of 7")
        #expect(count(card.dots, .today) == 0)
    }

    @Test func twoProvidersDifferByShape() throws {
        let codex = provider("codex", [week(used: 34, elapsedHours: 86)])
        let pair = try cards(present(snapshot([claudeDay6, codex])))
        #expect(pair.map(\.shape) == [.circle, .roundedSquare])
        let others = try cards(
            present(
                snapshot([
                    provider("gemini", [week(used: 10, elapsedHours: 50)]),
                    provider("cursor", [week(used: 20, elapsedHours: 50)]),
                ])))
        #expect(others.map(\.shape) == [.circle, .roundedSquare])
        #expect(try cards(present(snapshot([claudeDay6, codex]), max: 1)).count == 1)
    }

    @Test func picksTheWeeklyWindowOverASession() throws {
        let session = WidgetUsageSnapshot.Window(
            label: "5h", usedPercent: 80, resetsAt: hundredNow.addingTimeInterval(hour),
            windowMinutes: 300)
        let mixed = provider("claude", [session, week(used: 30, elapsedHours: 100)])
        let card = try #require(try cards(present(snapshot([mixed]))).first)
        #expect(card.counts?.used == 30)
    }

    @Test func notConnectedAndAbandonedStates() throws {
        #expect(present(nil).content == .notConnected(.noData))
        #expect(present(snapshot([])).content == .notConnected(.noData))
        let old = hundredNow.addingTimeInterval(-7 * hour)
        #expect(
            present(snapshot([claudeDay6], writtenAt: old)).content
                == .notConnected(.rafuNotRunning))
        let estimate = WidgetUsageSnapshot.Provider(
            id: "claude", displayName: "Claude", observedAt: hundredNow, isStale: false,
            windows: [], source: "localEstimate", tokenSummary: "7d 1.4M tok")
        let card = try #require(try cards(present(snapshot([estimate]))).first)
        #expect(card.dots == nil)
        #expect(card.status == .localEstimate)
    }

    @Test func voiceOverSentence() throws {
        let presentation = present(snapshot([claudeDay6]))
        #expect(
            presentation.accessibilityLabel
                == "Claude, weekly limit 41 percent used, day 6 of 7, 6 percent today, on pace, about 49 percent spare at reset, resets Friday"
        )
        let codex = provider("codex", [week(used: 34, elapsedHours: 86)])
        let pair = present(snapshot([claudeDay6, codex]))
        #expect(pair.accessibilityLabel.hasPrefix("Claude, weekly limit 41"))
        #expect(
            pair.accessibilityLabel.contains(". Codex, weekly limit 34 percent used, day 4 of 7"))
        #expect(!pair.accessibilityLabel.contains("~"))
    }
}

@Suite struct WidgetHundredPublisherTests {
    @Test func logRecordsSkipStaleAndPercentlessWindows() {
        let claude = UsageSnapshot(
            providerID: .claude,
            windows: [
                UsageWindow(
                    label: "7d", percent: 41, tokens: nil,
                    resetsAt: hundredNow.addingTimeInterval(day), windowMinutes: 10_080),
                UsageWindow(label: "5h", percent: nil, tokens: 1_200, resetsAt: nil),
            ],
            costLine: nil, identity: "someone@example.com")
        let codex = UsageSnapshot(
            providerID: .codex,
            windows: [UsageWindow(label: "7d", percent: 20, tokens: nil, resetsAt: nil)],
            costLine: nil, identity: nil)
        let records = WidgetSnapshotPublisher.sampleRecords(
            snapshots: [claude, codex], observedAt: [.claude: hundredNow], stale: [.codex],
            now: hundredNow.addingTimeInterval(60))
        #expect(records.count == 1)
        #expect(records[0].providerID == "claude")
        #expect(records[0].window == "7d")
        #expect(records[0].usedPercent == 41)
        #expect(records[0].observedAt == hundredNow)
    }

    @Test func attachesTheDaySplitToTheWeeklyWindowOnly() throws {
        let reset = hundredNow.addingTimeInterval(4 * day)
        let start = reset.addingTimeInterval(-7 * day)
        let log = UsageSampleLog(records: [
            UsageSampleRecord(
                providerID: "claude", window: "7d", usedPercent: 10,
                resetsAt: reset, observedAt: start.addingTimeInterval(day)),
            UsageSampleRecord(
                providerID: "claude", window: "7d", usedPercent: 25,
                resetsAt: reset, observedAt: start.addingTimeInterval(2 * day)),
        ])
        let widget = snapshot([
            provider(
                "claude",
                [
                    WidgetUsageSnapshot.Window(
                        label: "5h", usedPercent: 5, resetsAt: hundredNow.addingTimeInterval(hour),
                        windowMinutes: 300),
                    WidgetUsageSnapshot.Window(
                        label: "7d", usedPercent: 30, resetsAt: reset, windowMinutes: 10_080),
                ])
        ])
        let attached = WidgetSnapshotPublisher.attachDaily(widget, log: log)
        let windows = attached.providers[0].windows
        #expect(windows[0].daily == nil)
        #expect(windows[1].windowStart == start)
        // Now is 3 days into the window: days 1 to 3 have values, today is day 4.
        #expect(windows[1].daily?.count == 7)
        #expect(windows[1].daily?[0] == 10)
        #expect(windows[1].daily?[1] == 15)
        #expect(windows[1].daily?[2] == 5)
        #expect(windows[1].daily?[3] == 0)
        #expect(windows[1].daily?[4] == nil)
    }

    @Test func timelineAddsDayBoundaries() {
        // 140.5 h into the window, day 7 starts in 3.5 h (at 144 h).
        let claude = provider(
            "claude", [week(used: 41, elapsedHours: 140.5, daily: [7, 9, 5, 8, 6, 6, nil])])
        let dates = WidgetTimelinePlan.entryDates(snapshot: snapshot([claude]), now: hundredNow)
        #expect(dates.contains(hundredNow.addingTimeInterval(3.5 * hour)))
        let withoutSplit = provider("claude", [week(used: 41, elapsedHours: 140.5)])
        let plain = WidgetTimelinePlan.entryDates(
            snapshot: snapshot([withoutSplit]), now: hundredNow)
        #expect(!plain.contains(hundredNow.addingTimeInterval(3.5 * hour)))
        #expect(plain.count + 1 == dates.count)
    }
}
