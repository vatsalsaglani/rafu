import Foundation
import RafuCore

// Pure presentation logic for the workspace surfaces of Meetings: the
// navigator list, the meeting tab, the Welcome card and the title-bar record
// button. Nothing here reads a view or a store, so each rule is tested alone.
// Nothing here carries a transcript text, a speaker name or an audio path.

/// One row of the meeting list: the summary only, with the second line of
/// a ready meeting already formatted when the rows load. No turn text.
nonisolated struct MeetingsWorkspaceRow: Identifiable, Hashable, Sendable {
    var id: MeetingID
    var title: String
    /// For example "Today 10:30 · 31 min".
    var readyLine: String
    var state: MeetingState
}

/// What a meeting tab shows.
nonisolated enum MeetingsTabContent: Hashable, Sendable {
    /// The summary is not read yet.
    case loading
    /// The meeting is ready: the detail view.
    case detail
    /// The meeting records now: the live body, in the tab.
    case live
    /// The meeting is processing: the processing card, in the tab.
    case processing(MeetingsProcessingProgress)
    /// Processing stopped: the failed card, in the tab.
    case failed(MeetingsFailureReason)
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
    ) -> [MeetingsWorkspaceRow] {
        summaries
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate > rhs.startDate }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .map { summary in
                MeetingsWorkspaceRow(
                    id: summary.id,
                    title: displayTitle(summary.title),
                    readyLine: MeetingsFormat.meetingLine(
                        start: summary.startDate, duration: summary.duration, now: now,
                        calendar: calendar, locale: locale),
                    state: summary.state
                )
            }
    }

    /// The newest rows for the Welcome card. `rows` is already newest first.
    static func newest(_ rows: [MeetingsWorkspaceRow], count: Int = welcomeRecentCount)
        -> [MeetingsWorkspaceRow]
    {
        Array(rows.prefix(max(0, count)))
    }

    static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? untitledTitle : trimmed
    }

    // MARK: State

    /// A meeting that records now cannot be deleted.
    static func canDelete(meeting: MeetingID, recorder: MeetingRecorderState) -> Bool {
        recorder.meeting != meeting
    }

    /// "Try Again" shows for a failed meeting that does not record now.
    static func canRetry(
        state: MeetingState, meeting: MeetingID, recorder: MeetingRecorderState,
        step: MeetingsProcessingStep?
    ) -> Bool {
        recorder.meeting != meeting
            && MeetingsStatePresentation.failure(state: state, step: step) != nil
    }

    // MARK: Meeting tab

    /// The tab shows the same content as the Meetings window: the live
    /// body, the processing card, the failed card, or the detail view.
    static func tabContent(
        summary: MeetingSummaryRecord?,
        isLoaded: Bool,
        meeting: MeetingID,
        recorder: MeetingRecorderState,
        processing: MeetingsProcessingStep?
    ) -> MeetingsTabContent {
        guard isLoaded else { return .loading }
        if recorder.meeting == meeting { return .live }
        guard let summary else { return .deleted }
        if summary.state == .ready { return .detail }
        switch MeetingsWindowPresentation.processingDisplay(
            state: summary.state, step: processing)
        {
        case .running(let progress): return .processing(progress)
        case .stopped(let reason): return .failed(reason)
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
        case .recording: return "Recording, " + MeetingsFormat.spokenDuration(elapsed)
        case .paused: return "Paused, " + MeetingsFormat.spokenDuration(elapsed)
        case .stopping: return "Stopping the recording"
        }
    }
}
