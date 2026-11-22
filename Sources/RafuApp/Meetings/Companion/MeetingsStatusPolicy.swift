import Foundation
import RafuCore

// The pure rules of the Meetings status surfaces: the menu bar item, its
// menu, the companion section and the floating recording bar. The
// controllers and views only draw these values. No value here holds a
// meeting title, a speaker name or transcript text: shape, word and time
// only.

/// The state that a status surface shows.
nonisolated enum MeetingsStatusPhase: Hashable, Sendable {
    /// Ready to record. Also after a meeting became ready.
    case idle
    case starting
    case recording
    case paused
    case stopping
    /// No recording; one or more stopped meetings are being processed.
    case processing
    /// The last recording could not start or had to stop.
    case problem(MeetingCaptureProblem)

    /// A device records sound now, so an indicator must show.
    var isCapturing: Bool {
        switch self {
        case .starting, .recording, .paused: true
        case .idle, .stopping, .processing, .problem: false
        }
    }
}

/// An action that a status surface runs.
nonisolated enum MeetingsStatusAction: Hashable, Sendable, CaseIterable {
    case startRecording
    case pause
    case resume
    case stop
    case openMeetings
    case toggleFloatingBar
}

/// The facts that the policy reads. Built from the session model.
nonisolated struct MeetingsStatusInput: Hashable, Sendable {
    var recorderState: MeetingRecorderState = .idle
    var elapsed: TimeInterval = 0
    var processing: [MeetingID: MeetingsProcessingStep] = [:]
    var warnings: [MeetingsLiveWarning] = []
    var canStartRecording = false
    var canOpenWindow = false
    var floatingBarEnabled = false
}

/// The look of the menu bar item.
nonisolated struct MeetingsStatusItemContent: Hashable, Sendable {
    /// An SF Symbol, or nil when the title alone shows the state.
    var symbolName: String?
    /// The text beside the symbol. Starts with "●" while a recording runs.
    var title: String
    var accessibilityLabel: String
}

/// One line of the menu bar item's menu.
nonisolated struct MeetingsStatusMenuItem: Hashable, Sendable {
    var title: String
    var isEnabled: Bool
    var action: MeetingsStatusAction?
    var isChecked = false
    var isSeparator = false

    static let separator = MeetingsStatusMenuItem(
        title: "", isEnabled: false, action: nil, isSeparator: true)

    static func info(_ title: String) -> MeetingsStatusMenuItem {
        MeetingsStatusMenuItem(title: title, isEnabled: false, action: nil)
    }
}

/// One button of the companion section and of the floating bar.
nonisolated struct MeetingsStatusButton: Hashable, Sendable, Identifiable {
    var action: MeetingsStatusAction
    var title: String
    var symbolName: String
    var isEnabled: Bool

    var id: MeetingsStatusAction { action }
}

/// What the companion section shows.
nonisolated struct MeetingsCompanionSectionContent: Hashable, Sendable {
    var phase: MeetingsStatusPhase
    var symbolName: String
    /// The state word, for example "Recording".
    var word: String
    /// The time, while a recording runs or is paused.
    var timeText: String?
    var showsMeters: Bool
    /// Lines that are not warnings: processing and problems.
    var notes: [String]
    var warnings: [MeetingsLiveWarning]
    var buttons: [MeetingsStatusButton]

    /// True when nothing runs: the section shows its empty state.
    var isEmpty: Bool {
        phase == .idle && notes.isEmpty && warnings.isEmpty
    }
}

nonisolated enum MeetingsStatusPolicy {
    static let processingStoppedNote = "Processing stopped. Open Meetings to try again."

    // MARK: Phase

    static func phase(_ input: MeetingsStatusInput) -> MeetingsStatusPhase {
        switch input.recorderState {
        case .starting: return .starting
        case .recording: return .recording
        case .paused: return .paused
        case .stopping: return .stopping
        case .problem(let problem): return .problem(problem)
        case .idle:
            return activeProcessing(input.processing).isEmpty ? .idle : .processing
        }
    }

    /// The steps that still run, in a stable order (failed steps excluded).
    static func activeProcessing(
        _ processing: [MeetingID: MeetingsProcessingStep]
    ) -> [MeetingsProcessingStep] {
        processing
            .filter { !$0.value.isFailed }
            .sorted { $0.key.rawValue.uuidString < $1.key.rawValue.uuidString }
            .map(\.value)
    }

    static func hasFailedProcessing(_ processing: [MeetingID: MeetingsProcessingStep]) -> Bool {
        processing.values.contains { $0.isFailed }
    }

    /// "Writing the text (Me) 40%", or "2 meetings" for more than one.
    static func processingText(_ processing: [MeetingID: MeetingsProcessingStep]) -> String? {
        let active = activeProcessing(processing)
        switch active.count {
        case 0: return nil
        case 1: return active[0].label
        default: return "\(active.count) meetings"
        }
    }

    // MARK: Menu bar item

    static func statusItem(_ input: MeetingsStatusInput) -> MeetingsStatusItemContent {
        let time = MeetingClockText.text(input.elapsed)
        switch phase(input) {
        case .idle:
            return MeetingsStatusItemContent(
                symbolName: "waveform", title: "", accessibilityLabel: "Meetings: ready to record")
        case .starting:
            return MeetingsStatusItemContent(
                symbolName: nil, title: "● " + time,
                accessibilityLabel: "Meetings: starting to record")
        case .recording:
            return MeetingsStatusItemContent(
                symbolName: nil, title: "● " + time,
                accessibilityLabel: "Meetings: recording, \(time)")
        case .paused:
            return MeetingsStatusItemContent(
                symbolName: "pause.fill", title: time,
                accessibilityLabel: "Meetings: recording paused, \(time)")
        case .stopping:
            return MeetingsStatusItemContent(
                symbolName: "circle.dashed", title: "",
                accessibilityLabel: "Meetings: stopping the recording")
        case .processing:
            return MeetingsStatusItemContent(
                symbolName: "circle.dashed", title: "",
                accessibilityLabel: "Meetings: processing")
        case .problem:
            return MeetingsStatusItemContent(
                symbolName: "exclamationmark.triangle", title: "",
                accessibilityLabel: "Meetings: the recording stopped")
        }
    }

    /// The not-active first line of the menu.
    static func stateLine(_ input: MeetingsStatusInput) -> String {
        let time = MeetingClockText.text(input.elapsed)
        switch phase(input) {
        case .idle: return "Ready to record"
        case .starting: return "Starting to record"
        case .recording: return "Recording \(time)"
        case .paused: return "Paused \(time)"
        case .stopping: return "Stopping the recording"
        case .processing: return "Processing: " + (processingText(input.processing) ?? "")
        case .problem: return "The recording stopped"
        }
    }

    /// The lines under the state line that are not warnings.
    static func notes(_ input: MeetingsStatusInput) -> [String] {
        var notes: [String] = []
        let phase = phase(input)
        if case .problem(let problem) = phase {
            notes.append(MeetingsStartFailure.problem(problem).message)
        }
        if phase != .processing, let text = processingText(input.processing) {
            notes.append("Processing: " + text)
        }
        if hasFailedProcessing(input.processing) {
            notes.append(processingStoppedNote)
        }
        return notes
    }

    /// The recording controls for the phase, in order.
    static func buttons(_ input: MeetingsStatusInput) -> [MeetingsStatusButton] {
        let stop = MeetingsStatusButton(
            action: .stop, title: "Stop", symbolName: "stop.fill", isEnabled: true)
        switch phase(input) {
        case .recording:
            return [
                MeetingsStatusButton(
                    action: .pause, title: "Pause", symbolName: "pause.fill", isEnabled: true),
                stop,
            ]
        case .paused:
            return [
                MeetingsStatusButton(
                    action: .resume, title: "Resume", symbolName: "record.circle",
                    isEnabled: true),
                stop,
            ]
        case .starting, .stopping:
            return [
                MeetingsStatusButton(
                    action: .startRecording, title: "Start Recording",
                    symbolName: "record.circle", isEnabled: false)
            ]
        case .idle, .processing, .problem:
            return [
                MeetingsStatusButton(
                    action: .startRecording, title: "Start Recording",
                    symbolName: "record.circle", isEnabled: input.canStartRecording)
            ]
        }
    }

    static func menu(_ input: MeetingsStatusInput) -> [MeetingsStatusMenuItem] {
        var items: [MeetingsStatusMenuItem] = [.info(stateLine(input))]
        items += notes(input).map(MeetingsStatusMenuItem.info)
        items += input.warnings.map { .info($0.message) }
        items.append(.separator)
        items += buttons(input).map {
            MeetingsStatusMenuItem(title: $0.title, isEnabled: $0.isEnabled, action: $0.action)
        }
        items.append(.separator)
        items.append(
            MeetingsStatusMenuItem(
                title: "Open Meetings", isEnabled: input.canOpenWindow, action: .openMeetings))
        items.append(
            MeetingsStatusMenuItem(
                title: "Show Floating Recording Bar", isEnabled: true,
                action: .toggleFloatingBar, isChecked: input.floatingBarEnabled))
        return items
    }

    // MARK: Floating bar

    /// The bar shows only while a recording runs or is paused, and only
    /// when the user turned it on.
    static func showsFloatingBar(_ input: MeetingsStatusInput) -> Bool {
        guard input.floatingBarEnabled else { return false }
        switch input.recorderState {
        case .recording, .paused: return true
        case .idle, .starting, .stopping, .problem: return false
        }
    }

    // MARK: Companion section

    static func section(_ input: MeetingsStatusInput) -> MeetingsCompanionSectionContent {
        let phase = phase(input)
        let time = MeetingClockText.text(input.elapsed)
        let symbol: String
        let word: String
        var timeText: String?
        switch phase {
        case .idle:
            symbol = "waveform"
            word = "No recording"
        case .starting:
            symbol = "record.circle"
            word = "Starting"
        case .recording:
            symbol = "record.circle.fill"
            word = "Recording"
            timeText = time
        case .paused:
            symbol = "pause.circle.fill"
            word = "Paused"
            timeText = time
        case .stopping:
            symbol = "circle.dashed"
            word = "Stopping"
        case .processing:
            symbol = "circle.dashed"
            word = "Processing"
        case .problem:
            symbol = "exclamationmark.triangle.fill"
            word = "Stopped"
        }
        var notes = notes(input)
        if phase == .processing, let text = processingText(input.processing) {
            notes.insert(text, at: 0)
        }
        return MeetingsCompanionSectionContent(
            phase: phase, symbolName: symbol, word: word, timeText: timeText,
            showsMeters: phase == .recording || phase == .paused, notes: notes,
            warnings: input.warnings, buttons: buttons(input))
    }
}
