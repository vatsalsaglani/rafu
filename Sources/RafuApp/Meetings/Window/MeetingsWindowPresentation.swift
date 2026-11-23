import Foundation
import RafuCore

// The pure presentation rules of the Meetings window. The views call these
// functions; the tests cover them. Nothing here holds a transcript: only
// meeting summaries, recorder states and processing steps.

/// What the content column of the Meetings window shows.
nonisolated enum MeetingsWindowContent: Hashable, Sendable {
    /// No selection: the large Record button and the facts before a recording.
    case start
    /// The meeting that records now (also while the recorder starts or stops).
    case live
    /// A stopped meeting that is not ready.
    case processing(MeetingID)
    /// A ready meeting: the detail hook.
    case detail(MeetingID)
}

/// The groups of the meeting list, newest first.
nonisolated enum MeetingsListGroup: String, Hashable, Sendable, CaseIterable {
    case today = "Today"
    case yesterday = "Yesterday"
    case earlier = "Earlier"
}

/// One row of the meeting list: the summary and its precomputed second
/// line for a ready meeting ("Today 12:06 · 6 min").
nonisolated struct MeetingsListRowModel: Hashable, Sendable, Identifiable {
    var summary: MeetingSummaryRecord
    var subtitle: String

    var title: String { MeetingsWorkspacePresentation.displayTitle(summary.title) }

    var id: MeetingID { summary.id }
}

/// One group of the meeting list.
nonisolated struct MeetingsListSection: Hashable, Sendable, Identifiable {
    var group: MeetingsListGroup
    var rows: [MeetingsListRowModel]

    var id: MeetingsListGroup { group }
}

/// The state of one row. Each status has a word and a shape, so the state
/// is never shown by colour alone.
nonisolated enum MeetingsRowStatus: Hashable, Sendable {
    case recording
    case paused
    case stopping
    case processing
    case failed

    var word: String {
        switch self {
        case .recording: "Recording"
        case .paused: "Paused"
        case .stopping: "Stopping"
        case .processing: "Processing"
        case .failed: "Stopped — try again"
        }
    }

    /// A dot for recording, two bars for paused, a ring for processing, a
    /// triangle for a failure.
    var symbol: String {
        switch self {
        case .recording: "circle.fill"
        case .paused: "pause.fill"
        case .stopping: "stop.fill"
        case .processing: "circle.dashed"
        case .failed: "exclamationmark.triangle"
        }
    }
}

/// The header of the live view: a shape and a word.
nonisolated struct MeetingsLiveHeader: Hashable, Sendable {
    var word: String
    var symbol: String
    /// True only while the recording runs (the dot can pulse).
    var isRecording: Bool
}

/// The line about the text engine in the start view.
nonisolated struct MeetingsEngineLine: Hashable, Sendable {
    var text: String
    /// True when the preferred engine needs a model that is not installed.
    var offersDownload: Bool
}

/// One visible warning row of the live view.
nonisolated struct MeetingsWarningRow: Hashable, Sendable, Identifiable {
    var warning: MeetingsLiveWarning
    var message: String
    var symbol: String
    /// A "Them" problem: the recording continues, so it shows first.
    var isThem: Bool

    var id: MeetingsLiveWarning { warning }
}

/// What the content shows for a stopped meeting that is not ready.
nonisolated enum MeetingsProcessingDisplay: Hashable, Sendable {
    /// The processing card: the step, the bar and the three steps.
    case running(MeetingsProcessingProgress)
    /// Processing does not run. The failed card offers "Try Again" and
    /// "Delete…".
    case stopped(MeetingsFailureReason)
}

nonisolated enum MeetingsWindowPresentation {
    // MARK: List

    static func group(for date: Date, now: Date, calendar: Calendar) -> MeetingsListGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return .yesterday
        }
        return .earlier
    }

    /// The list groups in the order Today, Yesterday, Earlier; each group
    /// newest first. A group with no meeting is left out.
    static func sections(
        _ summaries: [MeetingSummaryRecord], now: Date, calendar: Calendar, locale: Locale
    ) -> [MeetingsListSection] {
        let sorted = summaries.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        var buckets: [MeetingsListGroup: [MeetingsListRowModel]] = [:]
        for summary in sorted {
            let group = group(for: summary.startDate, now: now, calendar: calendar)
            let row = MeetingsListRowModel(
                summary: summary,
                subtitle: subtitle(for: summary, now: now, calendar: calendar, locale: locale))
            buckets[group, default: []].append(row)
        }
        return MeetingsListGroup.allCases.compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return MeetingsListSection(group: group, rows: rows)
        }
    }

    /// For example "Today 10:30 · 31 min". A zero duration is left out.
    static func subtitle(
        for summary: MeetingSummaryRecord, now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        MeetingsFormat.meetingLine(
            start: summary.startDate, duration: summary.duration, now: now, calendar: calendar,
            locale: locale)
    }

    /// The state of a row. The live recorder state wins, then a processing
    /// step, then the stored state. A ready meeting has no status.
    static func status(
        for summary: MeetingSummaryRecord, recorderState: MeetingRecorderState,
        step: MeetingsProcessingStep?
    ) -> MeetingsRowStatus? {
        if recorderState.meeting == summary.id {
            switch recorderState {
            case .recording: return .recording
            case .paused: return .paused
            case .stopping: return .stopping
            case .idle, .starting, .problem: break
            }
        }
        if let step { return step.isFailed ? .failed : .processing }
        switch summary.state {
        case .ready: return nil
        case .failed: return .failed
        // Not live and no processing step: the short moment between the
        // last step and the library change. The launch sweep marks a
        // meeting that was cut off (the app quit) as failed.
        case .recording, .paused, .processing: return .processing
        }
    }

    /// Which content shows for the selection.
    static func content(
        selection: MeetingID?, recorderState: MeetingRecorderState,
        summary: MeetingSummaryRecord?, step: MeetingsProcessingStep?
    ) -> MeetingsWindowContent {
        if case .starting = recorderState { return .live }
        guard let selection else { return .start }
        if selection == recorderState.meeting { return .live }
        if summary?.state == .ready { return .detail(selection) }
        if step != nil { return .processing(selection) }
        guard let summary else { return .start }
        switch summary.state {
        case .ready: return .detail(selection)
        case .recording, .paused, .processing, .failed: return .processing(selection)
        }
    }

    /// The selection after a reload: a meeting that is gone is cleared. The
    /// live meeting and a processing meeting stay (the list can lag behind).
    static func validSelection(
        _ selection: MeetingID?, listed: Set<MeetingID>, liveMeeting: MeetingID?,
        processing: Set<MeetingID>
    ) -> MeetingID? {
        guard let selection else { return nil }
        if listed.contains(selection) || selection == liveMeeting
            || processing.contains(selection)
        {
            return selection
        }
        return nil
    }

    /// The selection after an arrow key: the next or the previous meeting
    /// in list order. Up from the first meeting clears the selection (the
    /// start page); down from no selection takes the first meeting.
    static func movedSelection(
        _ selection: MeetingID?, by step: Int, in ordered: [MeetingID]
    ) -> MeetingID? {
        guard !ordered.isEmpty, step != 0 else { return selection }
        guard let selection, let index = ordered.firstIndex(of: selection) else {
            return step > 0 ? ordered.first : selection
        }
        let next = index + step
        if next < 0 { return nil }
        return ordered[min(next, ordered.count - 1)]
    }

    // MARK: Record

    /// True while a recording starts, runs, pauses or stops: "New
    /// Recording" is not active then.
    static func isRecorderBusy(_ state: MeetingRecorderState) -> Bool {
        switch state {
        case .starting, .recording, .paused, .stopping: true
        case .idle, .problem: false
        }
    }

    /// Why Record is not active, or nil when it is.
    static func recordDisabledReason(
        availability: MeetingsAvailability, recorderState: MeetingRecorderState,
        isDriverInstalled: Bool
    ) -> String? {
        if let reason = availability.unavailableReason { return reason }
        switch recorderState {
        case .starting, .recording, .paused, .stopping: return "A recording is in progress"
        case .idle, .problem: break
        }
        if !isDriverInstalled { return "Recording is not ready in this build" }
        return nil
    }

    /// The System Settings link for a start failure, when one helps.
    static func systemSettingsURL(for failure: MeetingsStartFailure) -> URL? {
        switch failure {
        case .problem(.missingMicrophonePermission):
            URL(
                string:
                    "x-apple.systemsettings:com.apple.preference.security?Privacy_Microphone")
        case .problem(.missingSystemAudioPermission):
            // The exact pane link for system audio is not verified.
            URL(string: "x-apple.systemsettings:com.apple.preference.security")
        default: nil
        }
    }

    /// The banner of the content column: a start failure, else a recorder
    /// problem that ended a recording.
    static func banner(
        startFailure: MeetingsStartFailure?, recorderState: MeetingRecorderState
    ) -> MeetingsStartFailure? {
        if let startFailure { return startFailure }
        if case .problem(let problem) = recorderState { return .problem(problem) }
        return nil
    }

    // MARK: Live

    static func timerText(_ seconds: TimeInterval) -> String {
        MeetingClockText.text(seconds)
    }

    static func liveHeader(_ state: MeetingRecorderState) -> MeetingsLiveHeader? {
        switch state {
        case .starting: MeetingsLiveHeader(word: "Starting…", symbol: "circle", isRecording: false)
        case .recording:
            MeetingsLiveHeader(word: "Recording", symbol: "circle.fill", isRecording: true)
        case .paused: MeetingsLiveHeader(word: "Paused", symbol: "pause.fill", isRecording: false)
        case .stopping:
            MeetingsLiveHeader(word: "Stopping…", symbol: "stop.fill", isRecording: false)
        case .idle, .problem: nil
        }
    }

    /// Each warning as one row; "Them" warnings first, so they are seen at once.
    static func warningRows(_ warnings: [MeetingsLiveWarning]) -> [MeetingsWarningRow] {
        var seen = Set<MeetingsLiveWarning>()
        let rows = warnings.compactMap { warning -> MeetingsWarningRow? in
            guard seen.insert(warning).inserted else { return nil }
            return MeetingsWarningRow(
                warning: warning, message: warning.message, symbol: warning.symbol,
                isThem: isThemWarning(warning))
        }
        return rows.filter(\.isThem) + rows.filter { !$0.isThem }
    }

    static func isThemWarning(_ warning: MeetingsLiveWarning) -> Bool {
        switch warning {
        case .themNoSound, .themSilent: true
        case .meSilent, .headsetMicrophone, .speakersEcho: false
        }
    }

    static func speakerWord(_ track: MeetingTrack) -> String {
        track == .me ? "Me" : "Them"
    }

    static func speakerSymbol(_ track: MeetingTrack) -> String {
        track == .me ? "person.fill" : "person.2.fill"
    }

    /// For example "Me level 40 percent".
    static func meterAccessibilityValue(track: MeetingTrack, level: Double) -> String {
        let percent = Int((min(max(level.isFinite ? level : 0, 0), 1) * 100).rounded())
        return "\(speakerWord(track)) level \(percent) percent"
    }

    // MARK: Engines

    static func engineName(_ engine: MeetingTextEngineID) -> String {
        switch engine {
        case .nemotronEnglish: "Nemotron English"
        case .appleSpeech: "Apple speech"
        case .whisperKit: "WhisperKit"
        }
    }

    /// For example "Text: WhisperKit, on this Mac.", or "Text: Apple
    /// speech, on this Mac." with Download when the preferred engine needs
    /// a model. An engine with no availability entry is not installed.
    static func engineLine(
        preference: MeetingTextEngineID,
        availability: [MeetingTextEngineID: MeetingEngineAvailability]
    ) -> MeetingsEngineLine {
        let used = resolvedFinalTextEngine(preference: preference, availability: availability)
        let text = "Text: \(engineName(used)), on this Mac."
        if used == preference {
            return MeetingsEngineLine(text: text, offersDownload: false)
        }
        switch availability[preference] {
        case .unavailable(let reason):
            return MeetingsEngineLine(
                text: text + " \(engineName(preference)): \(reason)", offersDownload: false)
        case .needsModel, .ready, nil:
            return MeetingsEngineLine(text: text, offersDownload: true)
        }
    }

    /// "Live text: Apple speech", or the note, for example "Text comes after Stop".
    static func liveTextLine(engine: MeetingTextEngineID?, note: String?) -> String {
        if let engine { return "Live text: \(engineName(engine))" }
        return note ?? "Text comes after Stop"
    }

    // MARK: Processing

    /// The processing card, or the failed card. No step and no failure
    /// reads as "Finishing" (never "Processing stopped"): the runner clears
    /// the step just before the library reports the ready meeting.
    static func processingDisplay(
        state: MeetingState?, step: MeetingsProcessingStep?
    ) -> MeetingsProcessingDisplay {
        if let reason = MeetingsStatePresentation.failure(state: state, step: step) {
            return .stopped(reason)
        }
        return .running(MeetingsStatePresentation.processingProgress(step: step))
    }
}

/// The first-use download sheet rule: shown one time, when the sheet exists,
/// Meetings is available, and the WhisperKit model is not installed.
nonisolated enum MeetingsFirstUseSheetRule {
    static func shouldShow(
        hasSheet: Bool, isAvailable: Bool, isModelInstalled: Bool, defaults: UserDefaults
    ) -> Bool {
        hasSheet && isAvailable && !isModelInstalled
            && !defaults.bool(forKey: MeetingPreferenceKeys.firstUseSheetShown)
    }

    static func markShown(defaults: UserDefaults) {
        defaults.set(true, forKey: MeetingPreferenceKeys.firstUseSheetShown)
    }
}
