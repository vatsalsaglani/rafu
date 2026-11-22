import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("Meetings workspace presentation")
struct MeetingsWorkspacePresentationTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private static let locale = Locale(identifier: "en_GB")
    /// 2026-11-23 12:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_795_262_400)

    private static func date(hour: Int, minute: Int, daysAgo: Int = 0) -> Date {
        let base = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -daysAgo, to: base)!
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
    }

    private static func summary(
        _ title: String = "Weekly", start: Date, duration: TimeInterval = 1_860,
        state: MeetingState = .ready
    ) -> MeetingSummaryRecord {
        MeetingSummaryRecord(
            id: MeetingID(), title: title, startDate: start, duration: duration, state: state)
    }

    // MARK: Rows

    @Test("A row subtitle has the day, the time and the length")
    func rowSubtitle() throws {
        let rows = MeetingsWorkspacePresentation.rows(
            from: [Self.summary(start: Self.date(hour: 10, minute: 30))],
            now: Self.now, calendar: Self.calendar, locale: Self.locale)
        let row = try #require(rows.first)
        #expect(row.dateText == "Today 10:30")
        #expect(row.durationText == "31 min")
        #expect(
            MeetingsWorkspacePresentation.subtitle(row: row, badge: nil) == "Today 10:30 · 31 min")
    }

    @Test("Yesterday and an older day read plainly")
    func olderDays() {
        let yesterday = MeetingsWorkspacePresentation.dateText(
            for: Self.date(hour: 16, minute: 5, daysAgo: 1), now: Self.now,
            calendar: Self.calendar, locale: Self.locale)
        #expect(yesterday == "Yesterday 16:05")
        let older = MeetingsWorkspacePresentation.dateText(
            for: Self.date(hour: 9, minute: 0, daysAgo: 5), now: Self.now,
            calendar: Self.calendar, locale: Self.locale)
        #expect(older.hasSuffix("9:00"))
        #expect(!older.hasPrefix("Today"))
        #expect(!older.hasPrefix("Yesterday"))
    }

    @Test("Length text")
    func durationText() {
        #expect(MeetingsWorkspacePresentation.durationText(0) == "Under 1 min")
        #expect(MeetingsWorkspacePresentation.durationText(59) == "Under 1 min")
        #expect(MeetingsWorkspacePresentation.durationText(60) == "1 min")
        #expect(MeetingsWorkspacePresentation.durationText(3_900) == "1 h 05 min")
        #expect(MeetingsWorkspacePresentation.durationText(.nan) == "Under 1 min")
    }

    @Test("Rows are newest first and an empty title gets a name")
    func rowOrderAndTitle() {
        let old = Self.summary("Old", start: Self.date(hour: 9, minute: 0, daysAgo: 3))
        let new = Self.summary("   ", start: Self.date(hour: 11, minute: 0))
        let rows = MeetingsWorkspacePresentation.rows(
            from: [old, new], now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(rows.map(\.id) == [new.id, old.id])
        #expect(rows.first?.title == "Untitled meeting")
    }

    @Test("The Welcome card shows the newest three")
    func newestThree() {
        let summaries = (0..<5).map {
            Self.summary("M\($0)", start: Self.date(hour: 8 + $0, minute: 0))
        }
        let rows = MeetingsWorkspacePresentation.rows(
            from: summaries, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        let newest = MeetingsWorkspacePresentation.newest(rows)
        #expect(newest.map(\.title) == ["M4", "M3", "M2"])
        #expect(MeetingsWorkspacePresentation.newest(Array(rows.prefix(2))).count == 2)
        #expect(MeetingsWorkspacePresentation.newest([]).isEmpty)
    }

    // MARK: State

    @Test("Each meeting state has a word and a shape, or none when ready")
    func badges() throws {
        let id = MeetingID()
        func badge(_ state: MeetingState, step: MeetingsProcessingStep? = nil)
            -> MeetingsStatusBadge?
        {
            MeetingsWorkspacePresentation.badge(
                state: state, meeting: id, recorder: .idle, processing: step)
        }
        #expect(badge(.ready) == nil)
        #expect(badge(.recording)?.word == "Recording")
        #expect(badge(.paused)?.word == "Paused")
        #expect(badge(.processing)?.word == "Processing")
        #expect(badge(.processing, step: .failed(reasonCode: "interrupted"))?.word == "Failed")
        #expect(badge(.failed(reasonCode: "x"))?.word == "Failed")
        let symbols = Set(
            [
                badge(.recording), badge(.paused), badge(.processing),
                badge(.failed(reasonCode: "x")),
            ].compactMap { $0?.symbol })
        #expect(symbols.count == 4)
    }

    @Test("The live recorder state wins for the meeting that records")
    func liveBadge() {
        let id = MeetingID()
        let other = MeetingID()
        func word(_ recorder: MeetingRecorderState, _ meeting: MeetingID) -> String? {
            MeetingsWorkspacePresentation.badge(
                state: .ready, meeting: meeting, recorder: recorder, processing: nil)?.word
        }
        #expect(word(.recording(id), id) == "Recording")
        #expect(word(.paused(id), id) == "Paused")
        #expect(word(.stopping(id), id) == "Stopping")
        #expect(word(.recording(id), other) == nil)
    }

    @Test("A live meeting cannot be deleted")
    func deleteGuard() {
        let id = MeetingID()
        #expect(!MeetingsWorkspacePresentation.canDelete(meeting: id, recorder: .recording(id)))
        #expect(MeetingsWorkspacePresentation.canDelete(meeting: id, recorder: .idle))
        #expect(
            MeetingsWorkspacePresentation.canDelete(meeting: id, recorder: .recording(MeetingID())))
    }

    // MARK: Title bar

    @Test("Title-bar text for each recorder state")
    func titleBarText() {
        let id = MeetingID()
        func content(_ state: MeetingRecorderState, _ elapsed: TimeInterval = 767)
            -> MeetingsTitleBarContent
        {
            MeetingsWorkspacePresentation.titleBar(recorder: state, elapsed: elapsed)
        }
        #expect(content(.idle) == .record)
        #expect(content(.problem(.noBuffers)) == .record)
        #expect(
            content(.starting) == .active(text: "Starting…", isPaused: false, canControl: false))
        #expect(
            content(.recording(id)) == .active(text: "● 12:47", isPaused: false, canControl: true))
        #expect(content(.paused(id)) == .active(text: "❚❚ 12:47", isPaused: true, canControl: true))
        #expect(
            content(.stopping(id)) == .active(text: "Stopping…", isPaused: false, canControl: false)
        )
        #expect(
            content(.recording(id), 3_725)
                == .active(text: "● 1:02:05", isPaused: false, canControl: true))
    }

    @Test("Title-bar accessibility text")
    func titleBarAccessibility() {
        let id = MeetingID()
        func text(_ state: MeetingRecorderState, _ elapsed: TimeInterval = 767) -> String {
            MeetingsWorkspacePresentation.titleBarAccessibility(recorder: state, elapsed: elapsed)
        }
        #expect(text(.recording(id)) == "Recording, 12 minutes 47 seconds")
        #expect(text(.paused(id)) == "Paused, 12 minutes 47 seconds")
        #expect(text(.idle) == "Record a meeting")
        #expect(text(.starting) == "Starting the recording")
        #expect(text(.stopping(id)) == "Stopping the recording")
        #expect(MeetingsWorkspacePresentation.spokenDuration(5) == "5 seconds")
        #expect(MeetingsWorkspacePresentation.spokenDuration(61) == "1 minute 1 second")
        #expect(MeetingsWorkspacePresentation.spokenDuration(3_605) == "1 hour 0 minutes 5 seconds")
    }

    // MARK: Tab content

    private func tab(
        _ summary: MeetingSummaryRecord?, id: MeetingID, loaded: Bool = true,
        recorder: MeetingRecorderState = .idle, step: MeetingsProcessingStep? = nil
    ) -> MeetingsTabContent {
        MeetingsWorkspacePresentation.tabContent(
            summary: summary, isLoaded: loaded, meeting: id, recorder: recorder, elapsed: 65,
            processing: step)
    }

    @Test("A ready meeting shows the detail, a processing one its step")
    func tabForStates() {
        let ready = Self.summary(start: Self.now, state: .ready)
        #expect(tab(ready, id: ready.id) == .detail)

        let processing = Self.summary(start: Self.now, state: .processing)
        guard
            case .status(let badge, let line, let canRetry) = tab(
                processing, id: processing.id, step: .speakers)
        else {
            Issue.record("expected a status")
            return
        }
        #expect(badge.word == "Processing")
        #expect(line == "Finding speakers")
        #expect(!canRetry)

        guard
            case .status(let failedBadge, _, let failedRetry) = tab(
                processing, id: processing.id, step: .failed(reasonCode: "interrupted"))
        else {
            Issue.record("expected a status")
            return
        }
        #expect(failedBadge.word == "Failed")
        #expect(failedRetry)

        let failed = Self.summary(start: Self.now, state: .failed(reasonCode: "x"))
        guard case .status(let word, _, let retry) = tab(failed, id: failed.id) else {
            Issue.record("expected a status")
            return
        }
        #expect(word.word == "Failed")
        #expect(retry)
    }

    @Test("The live meeting shows the timer, an unknown id shows deleted")
    func tabForLiveAndUnknown() {
        let live = Self.summary(start: Self.now, state: .recording)
        #expect(
            tab(live, id: live.id, recorder: .recording(live.id))
                == .status(
                    badge: MeetingsStatusBadge(word: "Recording", symbol: "record.circle"),
                    line: "01:05", canRetry: false))
        #expect(tab(nil, id: MeetingID()) == .deleted)
        #expect(tab(nil, id: MeetingID(), loaded: false) == .loading)
        // A meeting that the store has not written yet, but records now.
        let id = MeetingID()
        if case .status(let badge, _, _) = tab(nil, id: id, recorder: .recording(id)) {
            #expect(badge.word == "Recording")
        } else {
            Issue.record("expected a status")
        }
    }
}
