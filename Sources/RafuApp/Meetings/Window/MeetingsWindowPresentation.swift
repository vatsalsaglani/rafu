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

/// One row of the meeting list: the summary and its precomputed subtitle.
nonisolated struct MeetingsListRowModel: Hashable, Sendable, Identifiable {
    var summary: MeetingSummaryRecord
    var subtitle: String

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
        case .failed: "exclamationmark.triangle.fill"
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

/// What the processing view shows.
nonisolated enum MeetingsProcessingDisplay: Hashable, Sendable {
    /// `fraction` is nil for an indeterminate step.
    case running(label: String, fraction: Double?, showsModelNote: Bool)
    /// Processing does not run. The view offers "Try again" and "Delete…".
    case stopped(message: String)
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

    /// For example "Today 10:30 · 31 min · 14.2 MB". A zero duration or a
    /// zero size is left out.
    static func subtitle(
        for summary: MeetingSummaryRecord, now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        let time = summary.startDate.formatted(style)
        let day: String
        switch group(for: summary.startDate, now: now, calendar: calendar) {
        case .today: day = "Today"
        case .yesterday: day = "Yesterday"
        case .earlier:
            var dayStyle = Date.FormatStyle().month(.abbreviated).day()
            dayStyle.locale = locale
            dayStyle.calendar = calendar
            dayStyle.timeZone = calendar.timeZone
            day = summary.startDate.formatted(dayStyle)
        }
        var parts = ["\(day) \(time)"]
        if let duration = durationText(summary.duration) { parts.append(duration) }
        if let size = sizeText(summary.sizes.totalBytes) { parts.append(size) }
        return parts.joined(separator: " · ")
    }

    /// "45 s", "31 min", "1 h 5 min"; nil for zero.
    static func durationText(_ seconds: TimeInterval) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        if seconds < 60 { return "\(Int(seconds)) s" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// Decimal units, one fraction digit: "14.2 MB"; nil for zero.
    static func sizeText(_ bytes: Int64) -> String? {
        guard bytes > 0 else { return nil }
        let value = Double(bytes)
        if value < 1_000_000 { return "\(max(1, Int((value / 1_000).rounded()))) KB" }
        if value < 1_000_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        return String(format: "%.2f GB", value / 1_000_000_000)
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
        // Not live and no processing step: the recording or the processing
        // was cut off (for example, the app quit). The user can try again.
        case .recording, .paused, .processing, .failed: return .failed
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

    // MARK: Record

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
        case .recording: MeetingsLiveHeader(word: "Rec", symbol: "circle.fill", isRecording: true)
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

    /// For example "Text: Apple speech (Nemotron English is not installed)".
    /// An engine with no availability entry is not installed.
    static func engineLine(
        preference: MeetingTextEngineID,
        availability: [MeetingTextEngineID: MeetingEngineAvailability]
    ) -> MeetingsEngineLine {
        let used = resolvedFinalTextEngine(preference: preference, availability: availability)
        if used == preference {
            return MeetingsEngineLine(text: "Text: \(engineName(used))", offersDownload: false)
        }
        let preferred = engineName(preference)
        switch availability[preference] {
        case .unavailable(let reason):
            return MeetingsEngineLine(
                text: "Text: \(engineName(used)) (\(preferred): \(reason))", offersDownload: false)
        case .needsModel, .ready, nil:
            return MeetingsEngineLine(
                text: "Text: \(engineName(used)) (\(preferred) is not installed)",
                offersDownload: true)
        }
    }

    /// "Live text: Apple speech", or the note, for example "Text comes after Stop".
    static func liveTextLine(engine: MeetingTextEngineID?, note: String?) -> String {
        if let engine { return "Live text: \(engineName(engine))" }
        return note ?? "Text comes after Stop"
    }

    // MARK: Processing

    static func processingDisplay(
        state: MeetingState?, step: MeetingsProcessingStep?
    ) -> MeetingsProcessingDisplay {
        if let step {
            switch step {
            case .failed: return .stopped(message: "Processing stopped. The audio is kept.")
            case .text(_, let fraction):
                return .running(
                    label: step.label, fraction: min(max(fraction, 0), 1), showsModelNote: false)
            case .preparingModel:
                return .running(label: step.label, fraction: nil, showsModelNote: true)
            case .waiting, .speakers, .finishing:
                return .running(label: step.label, fraction: nil, showsModelNote: false)
            }
        }
        if case .failed = state {
            return .stopped(message: "Processing stopped. The audio is kept.")
        }
        return .stopped(message: "Processing stopped. Try again.")
    }
}

/// The first-use download sheet rule: shown one time, when the sheet exists,
/// Meetings is available, and Nemotron English is not installed.
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
