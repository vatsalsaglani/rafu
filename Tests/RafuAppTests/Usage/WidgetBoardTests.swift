import Foundation
import RafuCore
import RafuWidgetShared
import Testing

@testable import RafuApp

// Widget W4: the Board presentation (row order, row cap, shapes, states,
// the VoiceOver summary) and the publisher's widget kinds. Synthetic data
// only: nothing here reads `~`, the network, or a Keychain.

// 2026-07-23T10:00:00Z, a Thursday.
private let boardNow = Date(timeIntervalSince1970: 1_784_800_800)
private let boardCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()
private let boardLocale = Locale(identifier: "en_US")
private let hour: TimeInterval = 3_600
private let day: TimeInterval = 86_400

/// A weekly window `elapsedHours` into its 7 days.
private func week(
    used: Double, elapsedHours: Double, daily: [Double?]? = nil, estimated: Bool? = nil
) -> WidgetUsageSnapshot.Window {
    let reset = boardNow.addingTimeInterval((168 - elapsedHours) * hour)
    return WidgetUsageSnapshot.Window(
        label: "7d", usedPercent: used, resetsAt: reset, windowMinutes: 10_080,
        windowStart: daily == nil ? nil : reset.addingTimeInterval(-7 * day), daily: daily,
        dailyEstimated: estimated)
}

private func provider(
    _ id: String, _ windows: [WidgetUsageSnapshot.Window], observedAt: Date = boardNow,
    isStale: Bool = false, tokenSummary: String? = nil
) -> WidgetUsageSnapshot.Provider {
    WidgetUsageSnapshot.Provider(
        id: id, displayName: id.prefix(1).uppercased() + id.dropFirst(), observedAt: observedAt,
        isStale: isStale, windows: windows, source: "providerAPI", tokenSummary: tokenSummary)
}

private func snapshot(
    _ providers: [WidgetUsageSnapshot.Provider], writtenAt: Date = boardNow,
    mode: String = "used"
) -> WidgetUsageSnapshot {
    WidgetUsageSnapshot(
        writtenAt: writtenAt, displayMode: mode, palette: "color", isSample: false,
        providers: providers)
}

private func present(_ snapshot: WidgetUsageSnapshot?, at now: Date = boardNow, rows: Int = 3)
    -> WidgetBoardPresentation
{
    WidgetBoardPresentation.make(
        snapshot: snapshot, now: now, maxRows: rows, calendar: boardCalendar,
        locale: boardLocale)
}

private func rows(_ presentation: WidgetBoardPresentation) throws -> [WidgetBoardRow] {
    guard case .providers(let rows, _) = presentation.content else {
        Issue.record("expected providers, got \(presentation.content)")
        throw CancellationError()
    }
    return rows
}

private let claude = provider(
    "claude", [week(used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil])])
private let codex = provider(
    "codex", [week(used: 34, elapsedHours: 86, daily: [10, 9, 8, 7, nil, nil, nil])])
/// At its limit: the most urgent.
private let gemini = provider("gemini", [week(used: 100, elapsedHours: 100)])
/// A fresh, low percent: the least urgent percent.
private let qwen = provider("qwen", [week(used: 5, elapsedHours: 100)])

@Suite struct WidgetBoardPresentationTests {
    @Test func rowsKeepTheSnapshotOrderWhenAllFit() throws {
        let board = present(snapshot([codex, claude, gemini]))
        #expect(try rows(board).map(\.id) == ["codex", "claude", "gemini"])
        #expect(board.moreText == nil)
        guard case .providers(_, let hidden) = board.content else { return }
        #expect(hidden == 0)
    }

    @Test func capsTheRowsAndKeepsTheMostUrgent() throws {
        // qwen is the least urgent (on pace, 5%) and is dropped; the kept
        // rows stay in snapshot order.
        let board = present(snapshot([claude, qwen, codex, gemini]))
        #expect(try rows(board).map(\.id) == ["claude", "codex", "gemini"])
        #expect(board.moreText == "+1 more")
        guard case .providers(_, let hidden) = board.content else { return }
        #expect(hidden == 1)

        let two = present(snapshot([claude, qwen, codex, gemini]), rows: 2)
        // gemini (at the limit) first by urgency, then claude (41%) over
        // codex (34%); shown in snapshot order.
        #expect(try rows(two).map(\.id) == ["claude", "gemini"])
        #expect(two.moreText == "+2 more")
        #expect(two.accessibilityLabel.hasSuffix("2 more agents not shown"))
    }

    @Test func urgencyRanksTheStatus() throws {
        let board = present(
            snapshot([
                gemini, claude,
                provider(
                    "local", [], tokenSummary: "7d 1.4M tok"),
            ]))
        let ranks = try rows(board).map(\.urgencyRank)
        #expect(ranks == [4, 1, 0])
    }

    @Test func shapesFollowTheProviderAndAlternateOnCollision() throws {
        let pair = try rows(present(snapshot([claude, codex])))
        #expect(pair.map(\.shape) == [.circle, .roundedSquare])

        // gemini starts as a circle under Claude, so it takes the square;
        // qwen then takes the circle.
        let three = try rows(present(snapshot([claude, gemini, qwen])))
        #expect(three.map(\.shape) == [.circle, .roundedSquare, .circle])
        // The grid and the columns of one row draw the same mark.
        for row in three { #expect(row.hundred.shape == row.seven.shape) }

        let codexFirst = try rows(present(snapshot([codex, claude])))
        #expect(codexFirst.map(\.shape) == [.roundedSquare, .circle])
    }

    @Test func rowsReuseTheHundredAndSevenCards() throws {
        // The board holds exactly what the Hundred and Seven widgets show
        // for the same snapshot and date.
        let shot = snapshot([claude, codex])
        let board = try rows(present(shot))
        let hundred = WidgetHundredPresentation.make(
            snapshot: shot, now: boardNow, maxProviders: 2, calendar: boardCalendar,
            locale: boardLocale)
        let seven = WidgetSevenPresentation.make(
            snapshot: shot, now: boardNow, maxProviders: 2, calendar: boardCalendar,
            locale: boardLocale)
        guard case .providers(let hundredCards) = hundred.content,
            case .providers(let sevenCards) = seven.content
        else {
            Issue.record("expected providers")
            return
        }
        #expect(board.map(\.hundred) == hundredCards)
        #expect(board.map(\.seven) == sevenCards)
        let first = try #require(board.first)
        #expect(first.hundred.headline == "41%")
        #expect(first.hundred.dayText == "Day 6 of 7")
        #expect(first.hundred.todayText == "6% today")
        #expect(first.seven.columns?.count == 7)
    }

    @Test func notConnectedAndRafuNotRunning() {
        #expect(present(nil).content == .notConnected(.noData))
        #expect(present(snapshot([])).content == .notConnected(.noData))
        #expect(present(nil).updatedAt == nil)
        let abandoned = present(snapshot([claude], writtenAt: boardNow - 7 * hour))
        #expect(abandoned.content == .notConnected(.rafuNotRunning))
        #expect(abandoned.accessibilityLabel.contains("Rafu is not running"))
    }

    @Test func staleResetPassedAndLocalEstimateRows() throws {
        let stale = provider(
            "claude", [week(used: 41, elapsedHours: 136)], observedAt: boardNow - hour)
        let passed = provider(
            "codex", [week(used: 34, elapsedHours: 170)])
        let local = provider("other", [], tokenSummary: "7d 1.4M tok")
        let board = try rows(present(snapshot([stale, passed, local])))
        #expect(board[0].status == .stale(age: hour))
        #expect(board[0].isDimmed)
        #expect(board[1].status == .resetPassed)
        #expect(board[1].hundred.headline == "—")
        #expect(board[1].seven.columns == nil)
        #expect(board[2].status == .localEstimate)
        #expect(board[2].hundred.dots == nil)
        #expect(board[2].seven.tokenSummary == "7d 1.4M tok")
    }

    @Test func staleSnapshotDimsEveryRow() throws {
        let board = present(snapshot([claude, codex], writtenAt: boardNow - 30 * 60))
        #expect(try rows(board).allSatisfy(\.isDimmed))
        #expect(board.updatedAt == boardNow - 30 * 60)
    }

    @Test func remainingModeAndEstimatedCaption() throws {
        let estimated = provider(
            "claude",
            [week(used: 41, elapsedHours: 136, daily: [7, 9, 5, 8, 6, 6, nil], estimated: true)])
        let row = try #require(
            try rows(present(snapshot([estimated], mode: "remaining"))).first)
        #expect(row.hundred.headline == "59%")
        #expect(row.hundred.headlineCaption == "left")
        #expect(row.seven.isEstimated)
        #expect(row.accessibilityLabel.hasSuffix("daily values estimated"))
    }

    @Test func voiceOverSummaryCombinesProviders() throws {
        let board = present(snapshot([claude, codex]))
        let label = board.accessibilityLabel
        #expect(label.hasPrefix("Agent usage, updated 10:00"))
        let parts = try rows(board).map(\.hundred.accessibilityLabel)
        for part in parts { #expect(label.contains(part)) }
        #expect(label.contains("Claude, weekly limit 41 percent used, day 6 of 7"))
        #expect(label.contains("Codex, weekly limit 34 percent used, day 4 of 7"))
        #expect(!label.contains("Saturday"))
        #expect(!label.contains("~"))
    }

    @Test func publisherReloadsEveryWidgetKind() {
        #expect(
            WidgetSnapshotPublisher.widgetKinds == [
                "dev.vatsalsaglani.rafu.widgets.rings",
                "dev.vatsalsaglani.rafu.widgets.hundred",
                "dev.vatsalsaglani.rafu.widgets.seven",
                "dev.vatsalsaglani.rafu.widgets.board",
            ])
    }
}
