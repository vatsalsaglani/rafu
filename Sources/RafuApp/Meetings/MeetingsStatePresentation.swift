import Foundation
import RafuCore

// The words, shapes and progress of a meeting state, shared by the window
// list, the navigator, the Welcome card, the meeting tab and the window
// content. Pure: the tests cover each rule. No transcript text here.

/// The colour role of a row icon. The word and the shape always say the
/// same thing, so colour is never the only cue.
nonisolated enum MeetingsRowTone: Hashable, Sendable {
    case ready
    case recording
    case paused
    case processing
    case failed
}

/// What one meeting row shows: the icon, the second line, an optional thin
/// progress bar, and the spoken label.
nonisolated struct MeetingsRowDisplay: Hashable, Sendable {
    var symbol: String
    var tone: MeetingsRowTone
    /// "Today 12:06 · 6 min", "Recording · 02:13", "Writing the text · 57%",
    /// "No sound in the recording".
    var subtitle: String
    /// True for a processing row: it shows a thin bar.
    var showsProgress: Bool
    /// 0...1, or nil for an indeterminate bar.
    var progress: Double?
    /// The state part of the spoken label, for example "Recording, 2 minutes
    /// 13 seconds" or "Failed. No sound in the recording". Nil when ready.
    var spokenState: String?
    /// True for a failed meeting: "Try Again" shows on hover and in the menu.
    var canRetry: Bool
}

/// Why processing stopped, in three texts.
nonisolated struct MeetingsFailureReason: Hashable, Sendable {
    /// For example "The recording has no sound."
    var sentence: String
    /// For example "No sound in the recording" (a row subtitle).
    var short: String
}

/// One of the steps in the processing card.
nonisolated struct MeetingsProcessingStage: Hashable, Sendable, Identifiable {
    enum Progress: Hashable, Sendable {
        case done
        case current
        case waiting
    }

    var title: String
    var progress: Progress

    var id: String { title }

    var symbol: String {
        switch progress {
        case .done: "checkmark.circle.fill"
        case .current: "circle.dashed"
        case .waiting: "circle"
        }
    }
}

/// What the processing card shows while processing runs.
nonisolated struct MeetingsProcessingProgress: Hashable, Sendable {
    /// For example "Writing the text · 57%" or "Finishing".
    var label: String
    /// The name of the step, for the spoken label of the bar.
    var stepTitle: String
    /// 0...1, or nil for an indeterminate bar.
    var fraction: Double?
    /// True while the model loads: "The first use of a model takes about
    /// one minute."
    var showsModelNote: Bool
    var stages: [MeetingsProcessingStage]
}

nonisolated enum MeetingsStatePresentation {
    static let writingText = "Writing the text"
    static let findingSpeakers = "Finding the speakers"
    static let finishing = "Finishing"
    static let modelNote = "The first use of a model takes about one minute."
    static let audioKept = "The audio is kept."
    static let failedTitle = "Rafu could not write the text"

    // MARK: Failure

    /// The reason for a stable failure code. An unknown code reads as the
    /// speech model stopping.
    static func failureReason(code: String?) -> MeetingsFailureReason {
        switch code {
        case MeetingProcessingFailure.noAudio:
            MeetingsFailureReason(
                sentence: "The recording has no sound.", short: "No sound in the recording")
        case MeetingProcessingFailure.cancelled:
            MeetingsFailureReason(
                sentence: "Processing was cancelled.", short: "Processing was cancelled")
        case MeetingProcessingFailure.interrupted:
            MeetingsFailureReason(
                sentence: "Rafu stopped before the text was written.",
                short: "Rafu stopped before the end")
        case MeetingProcessingFailure.libraryWrite:
            MeetingsFailureReason(
                sentence: "Rafu could not save the text.", short: "The text was not saved")
        default:
            MeetingsFailureReason(
                sentence: "The speech model stopped.", short: "The speech model stopped")
        }
    }

    /// Why a meeting failed: the processing step wins, then the stored
    /// state. Nil when the meeting did not fail.
    static func failure(state: MeetingState?, step: MeetingsProcessingStep?)
        -> MeetingsFailureReason?
    {
        if case .failed(let code) = step { return failureReason(code: code) }
        if step == nil, case .failed(let code) = state { return failureReason(code: code) }
        return nil
    }

    // MARK: Processing

    /// The progress for a step. No step (the moment between the last step
    /// and the library change) reads as "Finishing", never as a failure.
    static func processingProgress(step: MeetingsProcessingStep?) -> MeetingsProcessingProgress {
        let current: Int
        var label: String
        var stepTitle: String
        var fraction: Double?
        var showsModelNote = false
        switch step {
        case .waiting:
            current = 0
            label = "Waiting for the meeting before it"
            stepTitle = writingText
        case .preparingModel:
            current = 0
            label = "Preparing the speech model"
            stepTitle = writingText
            showsModelNote = true
        case .text(let track, let trackFraction):
            current = 0
            let overall = textFraction(track: track, fraction: trackFraction)
            fraction = overall
            label = writingText + " · \(MeetingsFormat.percent(overall))%"
            stepTitle = writingText
        case .speakers:
            current = 1
            label = findingSpeakers
            stepTitle = findingSpeakers
        case .finishing, .failed, nil:
            current = 2
            label = finishing
            stepTitle = finishing
        }
        let titles = [writingText, findingSpeakers, finishing]
        let stages = titles.enumerated().map { index, title in
            MeetingsProcessingStage(
                title: title,
                progress: index < current ? .done : (index == current ? .current : .waiting))
        }
        return MeetingsProcessingProgress(
            label: label, stepTitle: stepTitle, fraction: fraction,
            showsModelNote: showsModelNote, stages: stages)
    }

    /// The text step runs one track after the other (Me, then Them), so the
    /// whole step is two halves.
    static func textFraction(track: MeetingTrack, fraction: Double) -> Double {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        return track == .me ? clamped / 2 : 0.5 + clamped / 2
    }

    // MARK: Rows

    /// The display of one meeting row. The live recorder state wins, then
    /// the processing step, then the stored state. A stored "processing"
    /// with no step reads as "Finishing": the launch sweep marks a meeting
    /// that was cut off as failed.
    static func rowDisplay(
        meeting: MeetingID, state: MeetingState, readyLine: String,
        recorder: MeetingRecorderState, elapsed: TimeInterval, step: MeetingsProcessingStep?
    ) -> MeetingsRowDisplay {
        if recorder.meeting == meeting {
            switch recorder {
            case .recording:
                return live("circle.fill", .recording, "Recording", elapsed: elapsed)
            case .paused:
                return live("pause.fill", .paused, "Paused", elapsed: elapsed)
            case .stopping:
                return MeetingsRowDisplay(
                    symbol: "stop.fill", tone: .paused, subtitle: "Stopping…",
                    showsProgress: false, progress: nil, spokenState: "Stopping", canRetry: false)
            case .idle, .starting, .problem:
                break
            }
        }
        if let reason = failure(state: state, step: step) {
            return MeetingsRowDisplay(
                symbol: "exclamationmark.triangle", tone: .failed, subtitle: reason.short,
                showsProgress: false, progress: nil, spokenState: "Failed. \(reason.short)",
                canRetry: true)
        }
        if step == nil, state == .ready {
            return MeetingsRowDisplay(
                symbol: "waveform", tone: .ready, subtitle: readyLine, showsProgress: false,
                progress: nil, spokenState: nil, canRetry: false)
        }
        let progress = processingProgress(step: step)
        return MeetingsRowDisplay(
            symbol: "circle.dashed", tone: .processing, subtitle: progress.label,
            showsProgress: true, progress: progress.fraction, spokenState: progress.label,
            canRetry: false)
    }

    private static func live(
        _ symbol: String, _ tone: MeetingsRowTone, _ word: String, elapsed: TimeInterval
    ) -> MeetingsRowDisplay {
        MeetingsRowDisplay(
            symbol: symbol, tone: tone, subtitle: "\(word) · \(MeetingsFormat.clock(elapsed))",
            showsProgress: false, progress: nil,
            spokenState: "\(word), \(MeetingsFormat.spokenDuration(elapsed))", canRetry: false)
    }

    /// The whole spoken label of a row: "Weekly, Recording, 2 minutes 13
    /// seconds", or "Weekly, Today 12:06 · 6 min" when ready.
    static func rowAccessibilityLabel(title: String, display: MeetingsRowDisplay) -> String {
        "\(title), \(display.spokenState ?? display.subtitle)"
    }
}
