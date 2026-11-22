import Foundation

/// The recorder's internal phase. It holds two facts that the public
/// `MeetingRecorderState` does not: a Stop that came while the recording was
/// starting, and the problem that ends a stop.
public enum MeetingRecorderPhase: Hashable, Sendable {
    case idle
    case starting(stopRequested: Bool)
    case recording(MeetingID)
    case paused(MeetingID)
    /// `problem` is set when a fault (not the user) stopped the recording.
    case stopping(MeetingID, problem: MeetingCaptureProblem?)
    case problem(MeetingCaptureProblem)

    /// The state that the interface and the status surfaces see.
    public var state: MeetingRecorderState {
        switch self {
        case .idle: .idle
        case .starting: .starting
        case .recording(let id): .recording(id)
        case .paused(let id): .paused(id)
        case .stopping(let id, _): .stopping(id)
        case .problem(let problem): .problem(problem)
        }
    }

    /// One value of each shape, for the transition table test.
    public static func samples(meeting: MeetingID) -> [MeetingRecorderPhase] {
        [
            .idle, .starting(stopRequested: false), .starting(stopRequested: true),
            .recording(meeting), .paused(meeting), .stopping(meeting, problem: nil),
            .stopping(meeting, problem: .diskFull), .problem(.noBuffers),
        ]
    }
}

/// What happens to the recorder.
public enum MeetingRecorderCommand: Hashable, Sendable {
    /// The user pressed Record.
    case start
    case pause
    case resume
    /// The user pressed Stop.
    case stop
    /// The start work finished and both sources run.
    case startSucceeded(MeetingID)
    /// The start work failed.
    case startFailed(MeetingCaptureProblem)
    /// The stop work finished: the audio is kept and the sources are closed.
    case stopFinished
    /// A problem that ends the recording (the audio written so far is kept).
    case fault(MeetingCaptureProblem)
    /// The user closed the problem message.
    case dismissProblem

    /// One value of each shape, for the transition table test.
    public static func samples(meeting: MeetingID) -> [MeetingRecorderCommand] {
        [
            .start, .pause, .resume, .stop, .startSucceeded(meeting),
            .startFailed(.missingMicrophonePermission), .stopFinished, .fault(.diskFull),
            .dismissProblem,
        ]
    }
}

/// The work that a transition asks the recorder to do.
public enum MeetingRecorderEffect: Hashable, Sendable {
    case none
    /// Check permissions, make the meeting, start both sources.
    case beginStart
    /// The start finished after a Stop: close what the start opened.
    case abandonStart(MeetingID)
    case pauseCapture(MeetingID)
    case resumeCapture(MeetingID)
    /// Stop both sources, close the journal, make the audio files.
    case beginStop(MeetingID)
}

/// The result of one command in one phase.
public struct MeetingRecorderTransition: Hashable, Sendable {
    public var phase: MeetingRecorderPhase
    public var effect: MeetingRecorderEffect

    public init(phase: MeetingRecorderPhase, effect: MeetingRecorderEffect = .none) {
        self.phase = phase
        self.effect = effect
    }
}

/// The recorder state machine: a pure function, so each command in each
/// phase has one defined result. Rules:
///
/// - Two Starts give one session (a Start while starting or recording does
///   nothing).
/// - A Stop while starting is remembered; when the start finishes, the
///   recorder closes it and goes back to idle.
/// - A fault while recording or paused stops the recording, keeps the audio,
///   and ends in `problem`.
/// - A Start from `problem` tries again.
public enum MeetingRecorderMachine {
    public static func transition(
        from phase: MeetingRecorderPhase, on command: MeetingRecorderCommand
    ) -> MeetingRecorderTransition {
        switch phase {
        case .idle:
            switch command {
            case .start: return .init(phase: .starting(stopRequested: false), effect: .beginStart)
            default: return .init(phase: .idle)
            }

        case .starting(let stopRequested):
            switch command {
            case .stop:
                return .init(phase: .starting(stopRequested: true))
            case .startSucceeded(let id):
                if stopRequested { return .init(phase: .idle, effect: .abandonStart(id)) }
                return .init(phase: .recording(id))
            case .startFailed(let problem):
                if stopRequested { return .init(phase: .idle) }
                return .init(phase: .problem(problem))
            case .start, .pause, .resume, .stopFinished, .fault, .dismissProblem:
                // The start result decides; a fault during start arrives as
                // `startFailed`.
                return .init(phase: phase)
            }

        case .recording(let id):
            switch command {
            case .pause: return .init(phase: .paused(id), effect: .pauseCapture(id))
            case .stop: return .init(phase: .stopping(id, problem: nil), effect: .beginStop(id))
            case .fault(let problem):
                return .init(phase: .stopping(id, problem: problem), effect: .beginStop(id))
            case .start, .resume, .startSucceeded, .startFailed, .stopFinished, .dismissProblem:
                return .init(phase: phase)
            }

        case .paused(let id):
            switch command {
            case .resume: return .init(phase: .recording(id), effect: .resumeCapture(id))
            case .stop: return .init(phase: .stopping(id, problem: nil), effect: .beginStop(id))
            case .fault(let problem):
                return .init(phase: .stopping(id, problem: problem), effect: .beginStop(id))
            case .start, .pause, .startSucceeded, .startFailed, .stopFinished, .dismissProblem:
                return .init(phase: phase)
            }

        case .stopping(let id, let problem):
            switch command {
            case .stopFinished:
                if let problem { return .init(phase: .problem(problem)) }
                return .init(phase: .idle)
            case .fault(let newProblem) where problem == nil:
                // Keep the first reason; the stop is already running.
                return .init(phase: .stopping(id, problem: newProblem))
            default:
                return .init(phase: phase)
            }

        case .problem:
            switch command {
            case .start: return .init(phase: .starting(stopRequested: false), effect: .beginStart)
            case .dismissProblem: return .init(phase: .idle)
            default: return .init(phase: phase)
            }
        }
    }
}
