import AppKit
import Observation
import RafuCore
import SwiftUI

// The shared state of the live recording and of processing. The package
// "Recording session and processing pipeline" writes the state and installs
// the handlers. Each interface package only reads the state and calls the
// actions. No wave 2 package edits this file.

/// A warning that the live view and each status surface show while a
/// recording runs. The recording continues.
nonisolated enum MeetingsLiveWarning: String, Hashable, Sendable, CaseIterable, Identifiable {
    /// No "Them" buffers for 5 s while another app plays sound.
    case themNoSound
    /// "Them" is exact silence while another app plays sound.
    case themSilent
    /// "Me" is exact silence.
    case meSilent
    /// The microphone in use is a Bluetooth headset microphone.
    case headsetMicrophone
    /// The call sound comes out of the built-in speakers.
    case speakersEcho

    var id: String { rawValue }

    var message: String {
        switch self {
        case .themNoSound: "No call sound for 5 seconds. Rafu still records your microphone."
        case .themSilent:
            "The call sound is silent. Check that Rafu can record system audio in System Settings ▸ Privacy & Security."
        case .meSilent:
            "Your microphone is silent. Check the microphone in System Settings ▸ Privacy & Security ▸ Microphone."
        case .headsetMicrophone: "A headset microphone gives poor text. Use the Mac microphone."
        case .speakersEcho: "Use headphones for a clean Me track."
        }
    }

    var symbol: String {
        switch self {
        case .themNoSound, .themSilent: "speaker.slash"
        case .meSilent: "mic.slash"
        case .headsetMicrophone: "headphones"
        case .speakersEcho: "speaker.wave.2"
        }
    }
}

/// Where the processing of one stopped meeting is.
nonisolated enum MeetingsProcessingStep: Hashable, Sendable {
    case waiting
    case preparingModel
    /// `fraction` is 0...1 of that track.
    case text(track: MeetingTrack, fraction: Double)
    case speakers
    case finishing
    /// `reasonCode` is a short stable code, for example `interrupted`.
    case failed(reasonCode: String)

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .waiting: "Waiting"
        case .preparingModel: "Preparing model"
        case .text(let track, let fraction):
            "Writing the text (\(track == .me ? "Me" : "Them")) \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        case .speakers: "Finding speakers"
        case .finishing: "Finishing"
        case .failed: "Processing stopped. Try again."
        }
    }
}

/// Why Record did not start a recording.
nonisolated enum MeetingsStartFailure: Hashable, Sendable {
    case problem(MeetingCaptureProblem)
    /// For example "Meetings needs macOS 26".
    case notAvailable(reason: String)
    case busy
    case failed

    var message: String {
        switch self {
        case .problem(.missingMicrophonePermission):
            "Rafu cannot use the microphone. Allow it in System Settings ▸ Privacy & Security ▸ Microphone."
        case .problem(.missingSystemAudioPermission):
            "Rafu cannot record the call sound. Allow it in System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording."
        case .problem(.noBuffers):
            "The microphone gave no sound. Check the microphone and try again."
        case .problem(.deviceLost): "The audio device went away. Check the device and try again."
        case .problem(.diskFull): "The disk is full. Rafu kept the audio so far."
        case .notAvailable(let reason): reason
        case .busy: "The last recording is still stopping. Try again in a moment."
        case .failed: "The recording did not start. Try again."
        }
    }
}

/// The levels of the two tracks, 0...1, about 10 times a second. A separate
/// object, so only the small meter view redraws.
@MainActor
@Observable
final class MeetingsLevelsModel {
    var me: Double = 0
    var them: Double = 0
}

/// The actions behind the session model. The pipeline package replaces
/// them; a test replaces them to record calls.
struct MeetingsSessionHandlers {
    var start: @MainActor (String?) -> Void = { _ in }
    var pause: @MainActor () -> Void = {}
    var resume: @MainActor () -> Void = {}
    var stop: @MainActor () -> Void = {}
    var dismissProblem: @MainActor () -> Void = {}
    var retryProcessing: @MainActor (MeetingID) -> Void = { _ in }
    var cancelProcessing: @MainActor (MeetingID) -> Void = { _ in }
    var remakeText: @MainActor (MeetingID, MeetingTextEngineID) -> Void = { _, _ in }
    var deleteMeeting: @MainActor (MeetingID) -> Void = { _ in }
}

/// One for the app, owned by `MeetingsFeature.session`.
@MainActor
@Observable
final class MeetingsSessionModel {
    // Live recording.
    var recorderState: MeetingRecorderState = .idle
    var liveTitle = ""
    /// Recorded seconds; a pause is not counted.
    var liveElapsed: TimeInterval = 0
    /// The newest live turns (at most 200). A preview only.
    var liveTurns: [MeetingLiveTurn] = []
    /// The engine that makes the live text now, or nil when there is none.
    var liveTextEngine: MeetingTextEngineID?
    /// For example "Text comes after Stop".
    var liveTextNote: String?
    var warnings: [MeetingsLiveWarning] = []
    /// The name of the microphone in use.
    var microphoneName: String?
    var startFailure: MeetingsStartFailure?
    let levels = MeetingsLevelsModel()

    // Processing.
    var processing: [MeetingID: MeetingsProcessingStep] = [:]
    /// Goes up when the list of meetings or one meeting changed in the
    /// library. A list or a detail view reloads from the store.
    var libraryRevision = 0

    /// The meeting that the Meetings window shows.
    var windowSelection: MeetingID?

    /// True after the pipeline package installed its handlers.
    var isDriverInstalled = false
    @ObservationIgnored var handlers = MeetingsSessionHandlers()

    var liveMeeting: MeetingID? { recorderState.meeting }

    var isRecordingOrPaused: Bool {
        switch recorderState {
        case .recording, .paused: true
        case .idle, .starting, .stopping, .problem: false
        }
    }

    var canStartRecording: Bool {
        guard isDriverInstalled else { return false }
        switch recorderState {
        case .idle, .problem: return true
        case .starting, .recording, .paused, .stopping: return false
        }
    }

    func startRecording(title: String? = nil) { handlers.start(title) }
    func pause() { handlers.pause() }
    func resume() { handlers.resume() }
    func stop() { handlers.stop() }
    func dismissProblem() { handlers.dismissProblem() }
    func retryProcessing(_ meeting: MeetingID) { handlers.retryProcessing(meeting) }
    func cancelProcessing(_ meeting: MeetingID) { handlers.cancelProcessing(meeting) }
    func remakeText(_ meeting: MeetingID, with engine: MeetingTextEngineID) {
        handlers.remakeText(meeting, engine)
    }
    func deleteMeeting(_ meeting: MeetingID) { handlers.deleteMeeting(meeting) }
    func noteLibraryChanged() { libraryRevision += 1 }

    // MARK: Hidden agent runs and the summary (owned by the meeting agent package)

    /// The summary of each meeting that the interface asked about or that
    /// the agent wrote in this launch. A meeting that is not here has no
    /// known state yet (`refreshSummaryState` reads it).
    var summaryStates: [MeetingID: MeetingSummaryState] = [:]
    /// The hidden agent runs in progress, for each meeting.
    var agentRuns: [MeetingID: [MeetingAgentActivity]] = [:]
    /// The meetings whose processing shows the "Writing the summary" step.
    var summaryStepActive: Set<MeetingID> = []
    @ObservationIgnored var summaryHandlers = MeetingsSummaryHandlers()

    func isAgentRunning(_ kind: MeetingAgentRunKind, for meeting: MeetingID) -> Bool {
        agentRuns[meeting]?.contains { $0.kind == kind } ?? false
    }

    /// Writes the summary now (a user action), with no regard to the
    /// Settings switch.
    func makeSummary(_ meeting: MeetingID) { summaryHandlers.make(meeting) }
    func cancelSummary(_ meeting: MeetingID) { summaryHandlers.cancel(meeting) }
    /// Reads the summary state of one meeting from its notes file.
    func refreshSummaryState(_ meeting: MeetingID) { summaryHandlers.refresh(meeting) }
    /// Hides the "Writing the summary" step. The run goes on.
    func leaveSummaryStep(_ meeting: MeetingID) { summaryStepActive.remove(meeting) }

    /// Records the start (`isRunning` true) or the end of one hidden agent run.
    func noteAgentRun(_ activity: MeetingAgentActivity, of meeting: MeetingID, isRunning: Bool) {
        var runs = agentRuns[meeting] ?? []
        if isRunning {
            runs.append(activity)
        } else if let index = runs.firstIndex(of: activity) {
            runs.remove(at: index)
        }
        agentRuns[meeting] = runs.isEmpty ? nil : runs
    }
}

/// The actions behind the summary of the session model. The meeting agent
/// package installs them; a test replaces them to record calls.
struct MeetingsSummaryHandlers {
    /// A processing job wrote the text of this meeting (the library state is
    /// `ready`).
    var afterProcessing: @MainActor (MeetingID) -> Void = { _ in }
    var make: @MainActor (MeetingID) -> Void = { _ in }
    var cancel: @MainActor (MeetingID) -> Void = { _ in }
    var refresh: @MainActor (MeetingID) -> Void = { _ in }
}

/// Opens the Meetings window from code that has no SwiftUI environment (the
/// menu bar item). The hook hosts give it the `openWindow` action when they
/// appear. It never makes the Meetings feature.
@MainActor
final class MeetingsWindowOpener {
    static let shared = MeetingsWindowOpener()

    private var action: (@MainActor () -> Void)?

    var canOpen: Bool { action != nil }

    func capture(_ openWindow: OpenWindowAction) {
        action = { openWindow(id: MeetingsWindowRoot.windowID) }
    }

    /// Opens the window; `meeting` becomes the window selection. Returns
    /// false when no host gave the action yet.
    @discardableResult
    func open(selecting meeting: MeetingID? = nil) -> Bool {
        if let meeting {
            MeetingsFeatureFactory.shared.feature?.session.windowSelection = meeting
        }
        guard let action else { return false }
        NSApp.activate()
        action()
        return true
    }
}
