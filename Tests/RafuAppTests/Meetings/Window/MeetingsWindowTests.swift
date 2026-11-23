import Foundation
import Observation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

@Suite("Meetings window presentation")
struct MeetingsWindowPresentationTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static let locale = Locale(identifier: "en_GB")
    /// 2026-11-23 15:00 UTC.
    private static let now = Date(timeIntervalSince1970: 1_795_446_000)

    private static func summary(
        _ title: String, hoursAgo: Double, duration: TimeInterval = 0,
        state: MeetingState = .ready, bytes: Int64 = 0
    ) -> MeetingSummaryRecord {
        MeetingSummaryRecord(
            id: MeetingID(), title: title, startDate: now.addingTimeInterval(-hoursAgo * 3600),
            duration: duration, state: state, sizes: MeetingSizes(audioBytes: bytes))
    }

    // MARK: 1. Groups, order, subtitle, state words

    @Test("List groups are Today, Yesterday, Earlier, each newest first")
    func groupsAndOrder() {
        let todayOld = Self.summary("a", hoursAgo: 5)
        let todayNew = Self.summary("b", hoursAgo: 1)
        let yesterday = Self.summary("c", hoursAgo: 20)
        let earlier = Self.summary("d", hoursAgo: 24 * 5)
        let sections = MeetingsWindowPresentation.sections(
            [earlier, todayOld, yesterday, todayNew], now: Self.now, calendar: Self.calendar,
            locale: Self.locale)
        #expect(sections.map(\.group) == [.today, .yesterday, .earlier])
        #expect(sections[0].rows.map(\.id) == [todayNew.id, todayOld.id])
        #expect(sections[1].rows.map(\.id) == [yesterday.id])
        #expect(sections[2].rows.map(\.id) == [earlier.id])
    }

    @Test("An empty group is left out")
    func emptyGroupLeftOut() {
        let sections = MeetingsWindowPresentation.sections(
            [Self.summary("a", hoursAgo: 24 * 4)], now: Self.now, calendar: Self.calendar,
            locale: Self.locale)
        #expect(sections.map(\.group) == [.earlier])
        #expect(
            MeetingsWindowPresentation.sections(
                [], now: Self.now, calendar: Self.calendar, locale: Self.locale
            ).isEmpty)
    }

    @Test("Subtitle: day, time and duration; no size")
    func subtitle() {
        // 10:30 UTC on the same day.
        let row = Self.summary("a", hoursAgo: 4.5, duration: 31 * 60, bytes: 14_200_000)
        #expect(
            MeetingsWindowPresentation.subtitle(
                for: row, now: Self.now, calendar: Self.calendar, locale: Self.locale)
                == "Today 10:30 · 31 min")
        let live = Self.summary("b", hoursAgo: 20)
        #expect(
            MeetingsWindowPresentation.subtitle(
                for: live, now: Self.now, calendar: Self.calendar, locale: Self.locale)
                == "Yesterday 19:00")
    }

    @Test("State word for each stored state, with no live recording and no step")
    func storedStateWords() {
        // No step and not failed: the moment before the library change
        // ("Finishing"), never a failure.
        let cases: [(MeetingState, String?)] = [
            (.ready, nil),
            (.processing, "Processing"),
            (.failed(reasonCode: "x"), "Stopped — try again"),
            (.recording, "Processing"),
            (.paused, "Processing"),
        ]
        for (state, word) in cases {
            let row = Self.summary("a", hoursAgo: 1, state: state)
            let status = MeetingsWindowPresentation.status(
                for: row, recorderState: .idle, step: nil)
            #expect(status?.word == word)
        }
    }

    @Test("State word for a live meeting and for a processing step")
    func liveAndStepWords() {
        let row = Self.summary("a", hoursAgo: 0, state: .recording)
        func word(_ state: MeetingRecorderState, _ step: MeetingsProcessingStep? = nil) -> String? {
            MeetingsWindowPresentation.status(for: row, recorderState: state, step: step)?.word
        }
        #expect(word(.recording(row.id)) == "Recording")
        #expect(word(.paused(row.id)) == "Paused")
        #expect(word(.stopping(row.id)) == "Stopping")
        #expect(word(.idle, .text(track: .me, fraction: 0.4)) == "Processing")
        #expect(word(.idle, .preparingModel) == "Processing")
        #expect(word(.idle, .failed(reasonCode: "interrupted")) == "Stopped — try again")
        // Another meeting records: this row is not live.
        #expect(word(.recording(MeetingID()), .speakers) == "Processing")
    }

    @Test("Each status has a shape as well as a word")
    func statusShapes() {
        let all: [MeetingsRowStatus] = [.recording, .paused, .stopping, .processing, .failed]
        #expect(Set(all.map(\.symbol)).count == all.count)
        let allHaveWords = all.allSatisfy { !$0.word.isEmpty }
        #expect(allHaveWords)
    }

    // MARK: 2. Content choice

    @Test("Content for each selection")
    func contentChoice() {
        let live = MeetingID()
        let processing = Self.summary("p", hoursAgo: 1, state: .processing)
        let failed = Self.summary("f", hoursAgo: 1, state: .failed(reasonCode: "x"))
        let ready = Self.summary("r", hoursAgo: 1, state: .ready)
        func content(
            _ selection: MeetingID?, _ summary: MeetingSummaryRecord? = nil,
            state: MeetingRecorderState = .idle, step: MeetingsProcessingStep? = nil
        ) -> MeetingsWindowContent {
            MeetingsWindowPresentation.content(
                selection: selection, recorderState: state, summary: summary, step: step)
        }
        #expect(content(nil) == .start)
        #expect(content(nil, state: .starting) == .live)
        #expect(content(live, state: .recording(live)) == .live)
        #expect(content(live, state: .paused(live)) == .live)
        #expect(content(live, state: .stopping(live)) == .live)
        #expect(content(processing.id, processing) == .processing(processing.id))
        #expect(content(failed.id, failed) == .processing(failed.id))
        #expect(content(ready.id, ready) == .detail(ready.id))
        #expect(content(ready.id, ready, state: .recording(live)) == .detail(ready.id))
        // A step, before the list knows the meeting.
        let unknown = MeetingID()
        #expect(content(unknown, step: .speakers) == .processing(unknown))
        #expect(content(unknown) == .start)
    }

    @Test("Selection after a reload: a deleted meeting is cleared")
    func validSelection() {
        let kept = MeetingID()
        let gone = MeetingID()
        let live = MeetingID()
        #expect(
            MeetingsWindowPresentation.validSelection(
                kept, listed: [kept], liveMeeting: nil, processing: []) == kept)
        #expect(
            MeetingsWindowPresentation.validSelection(
                gone, listed: [kept], liveMeeting: nil, processing: []) == nil)
        #expect(
            MeetingsWindowPresentation.validSelection(
                live, listed: [kept], liveMeeting: live, processing: []) == live)
        #expect(
            MeetingsWindowPresentation.validSelection(
                nil, listed: [kept], liveMeeting: nil, processing: []) == nil)
    }

    // MARK: Record, banner, live texts

    @Test("Record reasons")
    func recordReasons() {
        #expect(
            MeetingsWindowPresentation.recordDisabledReason(
                availability: .needsMacOS26, recorderState: .idle, isDriverInstalled: true)
                == "Meetings needs macOS 26")
        #expect(
            MeetingsWindowPresentation.recordDisabledReason(
                availability: .available, recorderState: .recording(MeetingID()),
                isDriverInstalled: true) == "A recording is in progress")
        #expect(
            MeetingsWindowPresentation.recordDisabledReason(
                availability: .available, recorderState: .idle, isDriverInstalled: true) == nil)
        #expect(
            MeetingsWindowPresentation.recordDisabledReason(
                availability: .available, recorderState: .idle, isDriverInstalled: false) != nil)
    }

    @Test("Start failures: the two permission problems link to System Settings")
    func startFailureLinks() {
        let mic = MeetingsWindowPresentation.systemSettingsURL(
            for: .problem(.missingMicrophonePermission))
        #expect(mic?.absoluteString.hasSuffix("Privacy_Microphone") == true)
        #expect(
            MeetingsWindowPresentation.systemSettingsURL(
                for: .problem(.missingSystemAudioPermission)) != nil)
        #expect(MeetingsWindowPresentation.systemSettingsURL(for: .failed) == nil)
        #expect(MeetingsWindowPresentation.systemSettingsURL(for: .problem(.diskFull)) == nil)
        #expect(
            MeetingsWindowPresentation.banner(
                startFailure: nil, recorderState: .problem(.deviceLost))
                == .problem(.deviceLost))
        #expect(
            MeetingsWindowPresentation.banner(
                startFailure: .busy, recorderState: .problem(.deviceLost))
                == .busy)
        #expect(MeetingsWindowPresentation.banner(startFailure: nil, recorderState: .idle) == nil)
    }

    @Test("Live header, timer, meter value, engine names")
    func liveTexts() {
        #expect(
            MeetingsWindowPresentation.liveHeader(.recording(MeetingID()))?.word == "Recording")
        #expect(MeetingsWindowPresentation.liveHeader(.paused(MeetingID()))?.word == "Paused")
        #expect(MeetingsWindowPresentation.liveHeader(.starting)?.word == "Starting…")
        #expect(MeetingsWindowPresentation.liveHeader(.stopping(MeetingID()))?.word == "Stopping…")
        #expect(MeetingsWindowPresentation.liveHeader(.idle) == nil)
        #expect(MeetingsWindowPresentation.timerText(12) == "00:12")
        #expect(
            MeetingsWindowPresentation.meterAccessibilityValue(track: .me, level: 0.4)
                == "Me level 40 percent")
        #expect(
            MeetingsWindowPresentation.meterAccessibilityValue(track: .them, level: 3)
                == "Them level 100 percent")
        #expect(MeetingsWindowPresentation.engineName(.nemotronEnglish) == "Nemotron English")
        #expect(MeetingsWindowPresentation.engineName(.appleSpeech) == "Apple speech")
        #expect(MeetingsWindowPresentation.engineName(.whisperKit) == "WhisperKit")
        #expect(
            MeetingsWindowPresentation.liveTextLine(engine: .appleSpeech, note: nil)
                == "Live text: Apple speech")
        #expect(
            MeetingsWindowPresentation.liveTextLine(engine: nil, note: "Text comes after Stop")
                == "Text comes after Stop")
    }

    @Test("Engine line names the engine in use and offers Download")
    func engineLine() {
        let missing = MeetingsWindowPresentation.engineLine(
            preference: .whisperKit, availability: [.appleSpeech: .ready])
        #expect(missing.text == "Text: Apple speech, on this Mac.")
        #expect(missing.offersDownload)
        let ready = MeetingsWindowPresentation.engineLine(
            preference: .whisperKit,
            availability: [.appleSpeech: .ready, .whisperKit: .ready])
        #expect(
            ready
                == MeetingsEngineLine(text: "Text: WhisperKit, on this Mac.", offersDownload: false)
        )
        let unavailable = MeetingsWindowPresentation.engineLine(
            preference: .whisperKit, availability: [.whisperKit: .unavailable(reason: "No helper")])
        #expect(unavailable.text == "Text: Apple speech, on this Mac. WhisperKit: No helper")
        #expect(!unavailable.offersDownload)
    }

    @Test("Processing display for each step and state")
    func processingDisplay() {
        guard
            case .running(let text) = MeetingsWindowPresentation.processingDisplay(
                state: .processing, step: .text(track: .them, fraction: 0.25))
        else {
            Issue.record("expected the processing card")
            return
        }
        // The Them track is the second half of the text step.
        #expect(text.label == "Writing the text · 63%")
        #expect(text.fraction == 0.625)
        #expect(text.stepTitle == "Writing the text")
        #expect(text.stages.map(\.progress) == [.current, .waiting, .waiting])
        #expect(
            text.stages.map(\.title) == ["Writing the text", "Finding the speakers", "Finishing"])

        guard
            case .running(let model) = MeetingsWindowPresentation.processingDisplay(
                state: .processing, step: .preparingModel)
        else {
            Issue.record("expected the processing card")
            return
        }
        #expect(model.fraction == nil)
        #expect(model.showsModelNote)

        guard
            case .running(let speakers) = MeetingsWindowPresentation.processingDisplay(
                state: .processing, step: .speakers)
        else {
            Issue.record("expected the processing card")
            return
        }
        #expect(speakers.label == "Finding the speakers")
        #expect(speakers.stages.map(\.progress) == [.done, .current, .waiting])

        #expect(
            MeetingsWindowPresentation.processingDisplay(
                state: .processing, step: .failed(reasonCode: MeetingProcessingFailure.noAudio))
                == .stopped(
                    MeetingsFailureReason(
                        sentence: "The recording has no sound.",
                        short: "No sound in the recording")))
        #expect(
            MeetingsWindowPresentation.processingDisplay(
                state: .failed(reasonCode: MeetingProcessingFailure.cancelled), step: nil)
                == .stopped(
                    MeetingsFailureReason(
                        sentence: "Processing was cancelled.", short: "Processing was cancelled")
                ))
        #expect(
            MeetingsWindowPresentation.processingDisplay(
                state: .failed(reasonCode: MeetingProcessingFailure.textFailed), step: nil)
                == .stopped(
                    MeetingsFailureReason(
                        sentence: "The speech model stopped.", short: "The speech model stopped")
                ))
    }

    /// Regression: the runner clears the step a moment before the library
    /// reports the ready meeting. The content showed "Processing stopped.
    /// Try again." in that moment.
    @Test("No step and no failure reads as Finishing, never as stopped")
    func noStepIsFinishing() {
        let states: [MeetingState?] = [.processing, .recording, .paused, nil]
        for state in states {
            guard
                case .running(let progress) = MeetingsWindowPresentation.processingDisplay(
                    state: state, step: nil)
            else {
                Issue.record("\(String(describing: state)) must not read as stopped")
                continue
            }
            #expect(progress.label == "Finishing")
            #expect(progress.fraction == nil)
            #expect(progress.stages.map(\.progress) == [.done, .done, .current])
        }
        guard
            case .running(let finishing) = MeetingsWindowPresentation.processingDisplay(
                state: .processing, step: .finishing)
        else {
            Issue.record("expected the processing card")
            return
        }
        #expect(finishing.label == "Finishing")
    }

    @Test("The arrow keys move the selection in list order")
    func movedSelection() {
        let first = MeetingID()
        let second = MeetingID()
        let third = MeetingID()
        let ordered = [first, second, third]
        func move(_ selection: MeetingID?, _ step: Int) -> MeetingID? {
            MeetingsWindowPresentation.movedSelection(selection, by: step, in: ordered)
        }
        #expect(move(nil, 1) == first)
        #expect(move(first, 1) == second)
        #expect(move(third, 1) == third)
        #expect(move(second, -1) == first)
        #expect(move(first, -1) == nil)
        #expect(move(nil, -1) == nil)
        #expect(MeetingsWindowPresentation.movedSelection(first, by: 1, in: []) == first)
    }

    @Test("New Recording is not active while the recorder is busy")
    func recorderBusy() {
        let id = MeetingID()
        #expect(MeetingsWindowPresentation.isRecorderBusy(.starting))
        #expect(MeetingsWindowPresentation.isRecorderBusy(.recording(id)))
        #expect(MeetingsWindowPresentation.isRecorderBusy(.paused(id)))
        #expect(MeetingsWindowPresentation.isRecorderBusy(.stopping(id)))
        #expect(!MeetingsWindowPresentation.isRecorderBusy(.idle))
        #expect(!MeetingsWindowPresentation.isRecorderBusy(.problem(.deviceLost)))
    }

    // MARK: 4. Warnings

    @Test("Each warning gives one row with its message; Them warnings first")
    func warningRows() {
        let all = MeetingsLiveWarning.allCases
        let rows = MeetingsWindowPresentation.warningRows(all)
        #expect(rows.count == all.count)
        #expect(Set(rows.map(\.warning)) == Set(all))
        for row in rows {
            #expect(row.message == row.warning.message)
            #expect(row.symbol == row.warning.symbol)
        }
        let firstTwoAreThem = rows.prefix(2).allSatisfy { $0.isThem }
        #expect(firstTwoAreThem)
        let one = MeetingsWindowPresentation.warningRows([.meSilent, .themNoSound, .meSilent])
        #expect(one.map(\.warning) == [.themNoSound, .meSilent])
    }

    // MARK: 5. First-use sheet

    @Test("The first-use sheet shows one time")
    func firstUseSheet() throws {
        let suiteName = TestDefaultsSuite.name("meetings-window-first-use")
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { TestDefaultsSuite.remove(suiteName) }
        func show(sheet: Bool = true, available: Bool = true, installed: Bool = false) -> Bool {
            MeetingsFirstUseSheetRule.shouldShow(
                hasSheet: sheet, isAvailable: available, isModelInstalled: installed,
                defaults: defaults)
        }
        #expect(!show(sheet: false))
        #expect(!show(available: false))
        #expect(!show(installed: true))
        #expect(show())
        MeetingsFirstUseSheetRule.markShown(defaults: defaults)
        #expect(!show())
        #expect(defaults.bool(forKey: MeetingPreferenceKeys.firstUseSheetShown))
    }

    // MARK: 6. No transcript outside the live view

    @Test("No window file reads turns; the live body is in the shared status views")
    func noTurnTextInWindowModel() throws {
        let folder = Self.packageRoot().appending(path: "Sources/RafuApp/Meetings/Window")
        let files = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
        #expect(files.count >= 5)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("MeetingTurn"), "\(file.lastPathComponent) uses MeetingTurn")
            #expect(
                !text.contains("liveTurns") && !text.contains("MeetingLiveTurn"),
                "\(file.lastPathComponent) reads live turns")
        }
    }

    private static func packageRoot(file: StaticString = #filePath) -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/",
            !FileManager.default.fileExists(atPath: directory.appending(path: "Package.swift").path)
        {
            directory = directory.deletingLastPathComponent()
        }
        return directory
    }
}

@MainActor
@Suite("Meetings window actions and model")
struct MeetingsWindowActionTests {
    /// Records each handler call.
    final class Calls {
        var starts = 0
        var pauses = 0
        var resumes = 0
        var stops = 0
        var dismissals = 0
        var cancelled: [MeetingID] = []
        var retried: [MeetingID] = []
        var deleted: [MeetingID] = []
    }

    private static func session(_ calls: Calls) -> MeetingsSessionModel {
        let session = MeetingsSessionModel()
        session.isDriverInstalled = true
        var handlers = MeetingsSessionHandlers()
        handlers.start = { _ in calls.starts += 1 }
        handlers.pause = { calls.pauses += 1 }
        handlers.resume = { calls.resumes += 1 }
        handlers.stop = { calls.stops += 1 }
        handlers.dismissProblem = { calls.dismissals += 1 }
        handlers.cancelProcessing = { calls.cancelled.append($0) }
        handlers.retryProcessing = { calls.retried.append($0) }
        handlers.deleteMeeting = { calls.deleted.append($0) }
        session.handlers = handlers
        return session
    }

    // MARK: 3. Actions

    @Test("Record calls start one time and shows the start view")
    func recordOnce() {
        let calls = Calls()
        let session = Self.session(calls)
        session.windowSelection = MeetingID()
        session.startFailure = .failed
        let commands = MeetingsWindowCommands(session: session)
        #expect(commands.record())
        #expect(calls.starts == 1)
        #expect(session.windowSelection == nil)
        #expect(session.startFailure == nil)
        // While the recorder starts, Record is refused.
        session.recorderState = .starting
        #expect(!commands.record())
        #expect(calls.starts == 1)
    }

    @Test("Record is refused when the driver is not installed")
    func recordRefusedWithoutDriver() {
        let calls = Calls()
        let session = Self.session(calls)
        session.isDriverInstalled = false
        #expect(!MeetingsWindowCommands(session: session).record())
        #expect(calls.starts == 0)
    }

    @Test("Pause, Resume, Stop, Cancel, Try again and Delete call their handlers")
    func actionsCallHandlers() {
        let calls = Calls()
        let session = Self.session(calls)
        let commands = MeetingsWindowCommands(session: session)
        let live = MeetingID()
        let other = MeetingID()
        session.recorderState = .recording(live)
        commands.pause()
        commands.resume()
        commands.stop()
        commands.cancelProcessing(other)
        commands.retryProcessing(other)
        #expect(calls.pauses == 1)
        #expect(calls.resumes == 1)
        #expect(calls.stops == 1)
        #expect(calls.cancelled == [other])
        #expect(calls.retried == [other])

        // Delete of the live meeting is not offered and does nothing.
        #expect(!commands.canDelete(live))
        commands.delete(live)
        #expect(calls.deleted.isEmpty)

        session.windowSelection = other
        #expect(commands.canDelete(other))
        commands.delete(other)
        #expect(calls.deleted == [other])
        #expect(session.windowSelection == nil)
    }

    @Test("Dismiss clears the start failure and dismisses the problem")
    func dismissBanner() {
        let calls = Calls()
        let session = Self.session(calls)
        session.startFailure = .problem(.missingMicrophonePermission)
        MeetingsWindowCommands(session: session).dismissBanner()
        #expect(session.startFailure == nil)
        #expect(calls.dismissals == 1)
    }

    // MARK: Model

    @Test("The model reads the list from the store and reports a failed read")
    func modelReload() async {
        let model = MeetingsWindowModel()
        let first = MeetingSummaryRecord(
            id: MeetingID(), title: "A", startDate: Date(), duration: 60, state: .ready)
        let ids = await model.reload(from: FakeMeetingList(result: .success([first])))
        #expect(ids == [first.id])
        #expect(model.loadState == .loaded)
        #expect(model.summary(for: first.id)?.title == "A")
        #expect(!model.isEmpty)

        let failed = await model.reload(from: FakeMeetingList(result: .failure(FakeError())))
        #expect(failed == nil)
        #expect(model.loadState == .failed)

        let empty = await model.reload(from: FakeMeetingList(result: .success([])))
        #expect(empty == [])
        #expect(model.isEmpty)
        #expect(model.loadState == .loaded)
    }

    /// Regression: the summaries were not observed, so the content column
    /// kept a stale "processing" summary after a reload and showed a false
    /// "Processing stopped".
    @Test("A reload that changes a summary redraws a reader of that summary")
    func summariesAreObserved() {
        let model = MeetingsWindowModel()
        let id = MeetingID()
        let start = Date()
        model.apply(
            [
                MeetingSummaryRecord(
                    id: id, title: "A", startDate: start, duration: 60, state: .processing)
            ], now: start, calendar: .current, locale: .current)
        let changed = Mutex(false)
        withObservationTracking {
            _ = model.summary(for: id)
        } onChange: {
            changed.withLock { $0 = true }
        }
        model.apply(
            [
                MeetingSummaryRecord(
                    id: id, title: "A", startDate: start, duration: 60, state: .ready)
            ],
            now: start, calendar: .current, locale: .current)
        #expect(changed.withLock { $0 })
        #expect(model.summary(for: id)?.state == .ready)
        #expect(model.orderedIDs == [id])
    }

    // MARK: 7. Registration

    @Test("registerWindowParts registers the window view")
    func registration() {
        let feature = MeetingsFeature(availability: .available)
        #expect(feature.windowView == nil)
        feature.registerWindowParts()
        #expect(feature.windowView != nil)
        #expect(feature.registeredKinds.contains(.windowView))
    }
}

private struct FakeError: Error {}

/// A store that answers `list()` only.
private struct FakeMeetingList: MeetingStoring {
    let result: Result<[MeetingSummaryRecord], FakeError>

    func list() async throws -> [MeetingSummaryRecord] { try result.get() }

    func create(title: String, startDate: Date) async throws -> MeetingSummaryRecord {
        throw FakeError()
    }
    func summary(of meeting: MeetingID) async throws -> MeetingSummaryRecord? { nil }
    func appendTurns(_ turns: [MeetingTurn], to meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { throw FakeError() }
    func turns(of meeting: MeetingID, after: MeetingTurnID?, limit: Int) async throws
        -> MeetingTurnPage
    { throw FakeError() }
    func setState(_ state: MeetingState, of meeting: MeetingID, expectedVersion: Int)
        async throws -> Int
    { throw FakeError() }
    func rename(_ meeting: MeetingID, title: String, expectedVersion: Int) async throws -> Int {
        throw FakeError()
    }
    func renameSpeaker(
        _ label: MeetingSpeakerLabel, to name: String, in meeting: MeetingID,
        expectedVersion: Int
    ) async throws -> Int { throw FakeError() }
    func delete(_ meeting: MeetingID) async throws { throw FakeError() }
    func search(_ query: String, limit: Int) async throws -> [MeetingSearchHit] { [] }
    func agentPacketText(of meeting: MeetingID) async throws -> String { throw FakeError() }
    func exportMarkdown(of meeting: MeetingID) async throws -> String { throw FakeError() }
    func sizeOnDisk(of meeting: MeetingID) async throws -> MeetingSizes { MeetingSizes() }
    func applyAudioRetention(_ retention: MeetingAudioRetention, now: Date) async throws {}
    func audioFolder(for meeting: MeetingID) async throws -> URL { throw FakeError() }
}
