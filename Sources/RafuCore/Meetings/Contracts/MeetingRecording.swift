import Foundation

/// Why a recording cannot start or had to stop.
public enum MeetingCaptureProblem: String, Hashable, Codable, Sendable, CaseIterable {
    case missingMicrophonePermission
    case missingSystemAudioPermission
    case noBuffers
    case deviceLost
    case diskFull
}

/// The recorder's state, for the record button and the status surfaces.
public enum MeetingRecorderState: Hashable, Sendable {
    case idle
    case starting
    case recording(MeetingID)
    case paused(MeetingID)
    case stopping(MeetingID)
    case problem(MeetingCaptureProblem)

    /// The meeting being recorded, when there is one.
    public var meeting: MeetingID? {
        switch self {
        case .recording(let id), .paused(let id), .stopping(let id): id
        case .idle, .starting, .problem: nil
        }
    }
}

/// Events from the recorder beside its state.
public enum MeetingRecorderEvent: Hashable, Sendable {
    case started(MeetingID)
    case paused(MeetingID)
    case resumed(MeetingID)
    case stopped(MeetingID)
    /// The first buffer of a track arrived.
    case firstBuffer(MeetingID, MeetingTrack)
    case problem(MeetingCaptureProblem)
}

/// Starts, pauses, resumes and stops one recording at a time. A recording
/// starts only from an explicit user action.
public protocol MeetingRecorderControlling: Sendable {
    var states: AsyncStream<MeetingRecorderState> { get }
    func start(title: String) async throws -> MeetingID
    func pause() async
    func resume() async
    func stop() async
}
