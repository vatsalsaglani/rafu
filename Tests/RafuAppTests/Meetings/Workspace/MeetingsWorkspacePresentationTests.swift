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

    @Test("A row second line has the day, the time and the length")
    func rowSubtitle() throws {
        let rows = MeetingsWorkspacePresentation.rows(
            from: [Self.summary(start: Self.date(hour: 10, minute: 30))],
            now: Self.now, calendar: Self.calendar, locale: Self.locale)
        let row = try #require(rows.first)
        #expect(row.readyLine == "Today 10:30 · 31 min")
        let short = MeetingsWorkspacePresentation.rows(
            from: [Self.summary(start: Self.date(hour: 10, minute: 30), duration: 0)],
            now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(short.first?.readyLine == "Today 10:30")
    }

    @Test("Yesterday and an older day read plainly")
    func olderDays() {
        let yesterday = MeetingsFormat.dayAndTime(
            Self.date(hour: 16, minute: 5, daysAgo: 1), now: Self.now,
            calendar: Self.calendar, locale: Self.locale)
        #expect(yesterday == "Yesterday 16:05")
        let older = MeetingsFormat.dayAndTime(
            Self.date(hour: 9, minute: 0, daysAgo: 5), now: Self.now,
            calendar: Self.calendar, locale: Self.locale)
        // The time follows the user's clock setting ("9:00" or "09:00").
        #expect(older.hasPrefix("16 Nov "))
        #expect(older.hasSuffix("9:00"))
        let lastYear = MeetingsFormat.day(
            Self.date(hour: 9, minute: 0, daysAgo: 400), now: Self.now,
            calendar: Self.calendar, locale: Self.locale)
        #expect(lastYear.hasSuffix("2025"))
    }

    @Test("One duration format: seconds, minutes, hours; no zero")
    func durationText() {
        #expect(MeetingsFormat.duration(0) == nil)
        #expect(MeetingsFormat.duration(0.4) == nil)
        #expect(MeetingsFormat.duration(.nan) == nil)
        #expect(MeetingsFormat.duration(32) == "32 s")
        #expect(MeetingsFormat.duration(59.9) == "59 s")
        #expect(MeetingsFormat.duration(60) == "1 min")
        #expect(MeetingsFormat.duration(6 * 60 + 10) == "6 min")
        #expect(MeetingsFormat.duration(72 * 60) == "1 h 12 min")
        #expect(MeetingsFormat.duration(120 * 60) == "2 h")
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

    private func display(
        _ state: MeetingState, id: MeetingID = MeetingID(),
        recorder: MeetingRecorderState = .idle, step: MeetingsProcessingStep? = nil
    ) -> MeetingsRowDisplay {
        MeetingsStatePresentation.rowDisplay(
            meeting: id, state: state, readyLine: "Today 12:06 · 6 min", recorder: recorder,
            elapsed: 133, step: step)
    }

    @Test("Each row state has its icon and its second line")
    func rowDisplays() {
        let ready = display(.ready)
        #expect(ready.symbol == "waveform")
        #expect(ready.subtitle == "Today 12:06 · 6 min")
        #expect(!ready.showsProgress)
        #expect(ready.spokenState == nil)

        let processing = display(.processing, step: .text(track: .me, fraction: 0.5))
        #expect(processing.symbol == "circle.dashed")
        #expect(processing.subtitle == "Writing the text · 25%")
        #expect(processing.showsProgress)
        #expect(processing.progress == 0.25)

        // No gear: processing is a dashed ring.
        let finishing = display(.processing)
        #expect(finishing.symbol == "circle.dashed")
        #expect(finishing.subtitle == "Finishing")
        #expect(finishing.progress == nil)
        #expect(!finishing.canRetry)

        let failed = display(.failed(reasonCode: MeetingProcessingFailure.noAudio))
        #expect(failed.symbol == "exclamationmark.triangle")
        #expect(failed.subtitle == "No sound in the recording")
        #expect(failed.spokenState == "Failed. No sound in the recording")
        #expect(failed.canRetry)

        let stepFailed = display(.processing, step: .failed(reasonCode: "interrupted"))
        #expect(stepFailed.tone == .failed)
        #expect(stepFailed.canRetry)

        let symbols = Set([ready, processing, failed].map(\.symbol))
        #expect(symbols.count == 3)
    }

    @Test("The live recorder state wins for the meeting that records")
    func liveRow() {
        let id = MeetingID()
        let recording = display(.recording, id: id, recorder: .recording(id))
        #expect(recording.symbol == "circle.fill")
        #expect(recording.subtitle == "Recording · 02:13")
        #expect(recording.spokenState == "Recording, 2 minutes 13 seconds")
        #expect(
            MeetingsStatePresentation.rowAccessibilityLabel(title: "Weekly", display: recording)
                == "Weekly, Recording, 2 minutes 13 seconds")
        #expect(display(.ready, id: id, recorder: .paused(id)).subtitle == "Paused · 02:13")
        #expect(display(.ready, id: id, recorder: .stopping(id)).subtitle == "Stopping…")
        #expect(display(.ready, id: id, recorder: .recording(MeetingID())).tone == .ready)
    }

    @Test("Try Again is offered only for a failed meeting that is not live")
    func retryRule() {
        let id = MeetingID()
        let failed = MeetingState.failed(reasonCode: "x")
        #expect(
            MeetingsWorkspacePresentation.canRetry(
                state: failed, meeting: id, recorder: .idle, step: nil))
        #expect(
            !MeetingsWorkspacePresentation.canRetry(
                state: .processing, meeting: id, recorder: .idle, step: nil))
        #expect(
            MeetingsWorkspacePresentation.canRetry(
                state: .processing, meeting: id, recorder: .idle,
                step: .failed(reasonCode: "x")))
        #expect(
            !MeetingsWorkspacePresentation.canRetry(
                state: .ready, meeting: id, recorder: .idle, step: nil))
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
        #expect(MeetingsFormat.spokenDuration(5) == "5 seconds")
        #expect(MeetingsFormat.spokenDuration(61) == "1 minute 1 second")
        #expect(MeetingsFormat.spokenDuration(3_605) == "1 hour 0 minutes 5 seconds")
    }

    // MARK: Tab content

    private func tab(
        _ summary: MeetingSummaryRecord?, id: MeetingID, loaded: Bool = true,
        recorder: MeetingRecorderState = .idle, step: MeetingsProcessingStep? = nil
    ) -> MeetingsTabContent {
        MeetingsWorkspacePresentation.tabContent(
            summary: summary, isLoaded: loaded, meeting: id, recorder: recorder,
            processing: step)
    }

    @Test("The tab shows the processing and failed cards in the tab")
    func tabForStates() {
        let ready = Self.summary(start: Self.now, state: .ready)
        #expect(tab(ready, id: ready.id) == .detail)

        let processing = Self.summary(start: Self.now, state: .processing)
        guard case .processing(let progress) = tab(processing, id: processing.id, step: .speakers)
        else {
            Issue.record("expected the processing card")
            return
        }
        #expect(progress.label == "Finding the speakers")

        // No step yet: "Finishing", not a failure.
        guard case .processing(let finishing) = tab(processing, id: processing.id) else {
            Issue.record("expected the processing card")
            return
        }
        #expect(finishing.label == "Finishing")

        guard
            case .failed(let reason) = tab(
                processing, id: processing.id, step: .failed(reasonCode: "interrupted"))
        else {
            Issue.record("expected the failed card")
            return
        }
        #expect(reason.short == "Rafu stopped before the end")

        let failed = Self.summary(
            start: Self.now, state: .failed(reasonCode: MeetingProcessingFailure.cancelled))
        #expect(
            tab(failed, id: failed.id)
                == .failed(
                    MeetingsFailureReason(
                        sentence: "Processing was cancelled.", short: "Processing was cancelled"))
        )
    }

    @Test("The live meeting shows the live body, an unknown id shows deleted")
    func tabForLiveAndUnknown() {
        let live = Self.summary(start: Self.now, state: .recording)
        #expect(tab(live, id: live.id, recorder: .recording(live.id)) == .live)
        #expect(tab(live, id: live.id, recorder: .paused(live.id)) == .live)
        #expect(tab(nil, id: MeetingID()) == .deleted)
        #expect(tab(nil, id: MeetingID(), loaded: false) == .loading)
        // A meeting that the store has not written yet, but records now.
        let id = MeetingID()
        #expect(tab(nil, id: id, recorder: .recording(id)) == .live)
    }
}
