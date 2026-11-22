import Foundation
import RafuCore

// Pure presentation logic for the workspace surfaces of Meetings: the
// navigator list, the meeting tab, the Welcome card and the title-bar record
// button. Nothing here reads a view or a store, so each rule is tested alone.
// Nothing here carries a transcript text, a speaker name or an audio path.

/// A word and a shape for a state. A state is never shown by colour alone.
nonisolated struct MeetingsStatusBadge: Hashable, Sendable {
    var word: String
    var symbol: String
}

/// One row of the meeting list: the summary only, with the date and the
/// length already formatted when the rows load. No turn text.
nonisolated struct MeetingsListRow: Identifiable, Hashable, Sendable {
    var id: MeetingID
    var title: String
    /// For example "Today 10:30".
    var dateText: String
    /// For example "31 min".
    var durationText: String
    var state: MeetingState
}

/// What a meeting tab shows.
nonisolated enum MeetingsTabContent: Hashable, Sendable {
    /// The summary is not read yet.
    case loading
    /// The meeting is ready: the detail view.
    case detail
    /// The meeting is live, processing or failed: its state and one line.
    case status(badge: MeetingsStatusBadge, line: String?, canRetry: Bool)
    /// The store does not know this meeting.
    case deleted
}

/// What the title-bar record button shows.
nonisolated enum MeetingsTitleBarContent: Hashable, Sendable {
    /// The small record icon button.
    case record
    /// The label of the menu while a recording is on, or starting, or stopping.
    case active(text: String, isPaused: Bool, canControl: Bool)
}

nonisolated enum MeetingsWorkspacePresentation {
    static let untitledTitle = "Untitled meeting"
    static let deleteConfirmationTitle = "Delete this meeting?"
    static let deleteConfirmationMessage =
        "Delete this meeting? The audio and the transcript are removed. You cannot undo this."
    static let deletedMeetingMessage = "This meeting was deleted."
    static let welcomeRecentCount = 3

    // MARK: Rows

    /// Rows for the list, newest first.
    static func rows(
        from summaries: [MeetingSummaryRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> [MeetingsListRow] {
        summaries
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { summary in
                MeetingsListRow(
                    id: summary.id,
                    title: displayTitle(summary.title),
                    dateText: dateText(
                        for: summary.startDate, now: now, calendar: calendar, locale: locale),
                    durationText: durationText(summary.duration),
                    state: summary.state
                )
            }
    }

    /// The newest rows for the Welcome card. `rows` is already newest first.
    static func newest(_ rows: [MeetingsListRow], count: Int = welcomeRecentCount)
        -> [MeetingsListRow]
    {
        Array(rows.prefix(max(0, count)))
    }

    static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledTitle : trimmed
    }

    /// "Today 10:30", "Yesterday 16:05" or "21 Nov 2026 09:00".
    static func dateText(
        for date: Date, now: Date, calendar: Calendar, locale: Locale
    ) -> String {
        let time = date.formatted(
            Date.FormatStyle(
                date: .omitted, time: .shortened, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone))
        if calendar.isDate(date, inSameDayAs: now) { return "Today " + time }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
            calendar.isDate(date, inSameDayAs: yesterday)
        {
            return "Yesterday " + time
        }
        let day = date.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: locale, calendar: calendar,
                timeZone: calendar.timeZone))
        return day + " " + time
    }

    /// "31 min", "1 h 05 min" or "Under 1 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(seconds.isFinite ? seconds : 0, 0), 1_000_000_000))
        let minutes = total / 60
        if minutes < 1 { return "Under 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return "\(minutes / 60) h " + (rest < 10 ? "0\(rest)" : "\(rest)") + " min"
    }

    /// The second line of a row: the date, then the state word when there is
    /// one, else the length.
    static func subtitle(row: MeetingsListRow, badge: MeetingsStatusBadge?) -> String {
        row.dateText + " · " + (badge?.word ?? row.durationText)
    }

    // MARK: State

    /// The word and shape for a meeting, or nil for a ready meeting. The live
    /// recorder state wins for the meeting that records now.
    static func badge(
        state: MeetingState,
        meeting: MeetingID,
        recorder: MeetingRecorderState,
        processing: MeetingsProcessingStep?
    ) -> MeetingsStatusBadge? {
        switch recorder {
        case .recording(let live) where live == meeting:
            return MeetingsStatusBadge(word: "Recording", symbol: "record.circle")
        case .paused(let live) where live == meeting:
            return MeetingsStatusBadge(word: "Paused", symbol: "pause.circle")
        case .stopping(let live) where live == meeting:
            return MeetingsStatusBadge(word: "Stopping", symbol: "stop.circle")
        default:
            break
        }
        switch state {
        case .ready:
            return nil
        case .recording:
            return MeetingsStatusBadge(word: "Recording", symbol: "record.circle")
        case .paused:
            return MeetingsStatusBadge(word: "Paused", symbol: "pause.circle")
        case .processing:
            if processing?.isFailed == true {
                return MeetingsStatusBadge(word: "Failed", symbol: "exclamationmark.triangle")
            }
            return MeetingsStatusBadge(word: "Processing", symbol: "gearshape")
        case .failed:
            return MeetingsStatusBadge(word: "Failed", symbol: "exclamationmark.triangle")
        }
    }

    /// A meeting that records now cannot be deleted.
    static func canDelete(meeting: MeetingID, recorder: MeetingRecorderState) -> Bool {
        recorder.meeting != meeting
    }

    // MARK: Meeting tab

    static func tabContent(
        summary: MeetingSummaryRecord?,
        isLoaded: Bool,
        meeting: MeetingID,
        recorder: MeetingRecorderState,
        elapsed: TimeInterval,
        processing: MeetingsProcessingStep?
    ) -> MeetingsTabContent {
        guard isLoaded else { return .loading }
        let isLive = recorder.meeting == meeting
        guard let summary else {
            guard isLive else { return .deleted }
            return .status(
                badge: badge(
                    state: .recording, meeting: meeting, recorder: recorder, processing: nil)
                    ?? MeetingsStatusBadge(word: "Recording", symbol: "record.circle"),
                line: MeetingClockText.text(elapsed), canRetry: false)
        }
        if isLive,
            let live = badge(
                state: summary.state, meeting: meeting, recorder: recorder, processing: nil)
        {
            return .status(badge: live, line: MeetingClockText.text(elapsed), canRetry: false)
        }
        switch summary.state {
        case .ready:
            return .detail
        case .recording, .paused:
            let word =
                badge(
                    state: summary.state, meeting: meeting, recorder: recorder, processing: nil)
                ?? MeetingsStatusBadge(word: "Recording", symbol: "record.circle")
            return .status(
                badge: word, line: MeetingClockText.text(summary.duration), canRetry: false)
        case .processing:
            let word =
                badge(
                    state: summary.state, meeting: meeting, recorder: recorder,
                    processing: processing)
                ?? MeetingsStatusBadge(word: "Processing", symbol: "gearshape")
            return .status(
                badge: word, line: processing?.label ?? "Waiting",
                canRetry: processing?.isFailed == true)
        case .failed:
            return .status(
                badge: MeetingsStatusBadge(word: "Failed", symbol: "exclamationmark.triangle"),
                line: "The meeting could not finish.", canRetry: true)
        }
    }

    // MARK: Title bar

    /// What the title bar shows for a recorder state. Idle and a recorder
    /// problem show the record button.
    static func titleBar(recorder: MeetingRecorderState, elapsed: TimeInterval)
        -> MeetingsTitleBarContent
    {
        switch recorder {
        case .idle, .problem:
            return .record
        case .starting:
            return .active(text: "Starting…", isPaused: false, canControl: false)
        case .recording:
            return .active(
                text: "● " + MeetingClockText.text(elapsed), isPaused: false, canControl: true)
        case .paused:
            return .active(
                text: "❚❚ " + MeetingClockText.text(elapsed), isPaused: true, canControl: true)
        case .stopping:
            return .active(text: "Stopping…", isPaused: false, canControl: false)
        }
    }

    /// The spoken text of the title-bar control, for example "Recording, 12
    /// minutes 47 seconds".
    static func titleBarAccessibility(recorder: MeetingRecorderState, elapsed: TimeInterval)
        -> String
    {
        switch recorder {
        case .idle, .problem: return "Record a meeting"
        case .starting: return "Starting the recording"
        case .recording: return "Recording, " + spokenDuration(elapsed)
        case .paused: return "Paused, " + spokenDuration(elapsed)
        case .stopping: return "Stopping the recording"
        }
    }

    /// "12 minutes 47 seconds", "1 hour 0 minutes 5 seconds", "5 seconds".
    static func spokenDuration(_ seconds: TimeInterval) -> String {
        let total = Int(min(max(seconds.isFinite ? seconds : 0, 0), 1_000_000_000))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let rest = total % 60
        var parts: [String] = []
        if hours > 0 { parts.append("\(hours) " + (hours == 1 ? "hour" : "hours")) }
        if hours > 0 || minutes > 0 {
            parts.append("\(minutes) " + (minutes == 1 ? "minute" : "minutes"))
        }
        parts.append("\(rest) " + (rest == 1 ? "second" : "seconds"))
        return parts.joined(separator: " ")
    }
}
