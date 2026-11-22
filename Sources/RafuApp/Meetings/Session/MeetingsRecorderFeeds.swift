import Foundation
import RafuCore

/// The parts of the recorder that the session driver reads beside
/// `MeetingRecorderControlling`. A seam for tests: the real one is
/// `MeetingRecorder` on macOS 26.
nonisolated protocol MeetingsRecorderFeeds: Sendable {
    /// Events beside the state. Each read gives a new subscription.
    var events: AsyncStream<MeetingRecorderEvent> { get }
    /// The converted audio of both tracks until the current (or next)
    /// recording stops. Call it one time for each recording.
    func liveAudio() -> AsyncStream<MeetingAudioChunk>
    /// The latest block peak of a track in dBFS (-160 is silence).
    func peakDBFS(_ track: MeetingTrack) -> Double
    /// The facts of the running recording, or nil.
    func readStartFacts() async -> MeetingRecorderStartFacts?
    func dismissProblem() async
    /// Writes the final audio files of a meeting from its journal.
    func recoverAbandoned(_ meeting: MeetingID) async throws -> MeetingJournalRecoveryReport
}

@available(macOS 26, *)
extension MeetingRecorder: MeetingsRecorderFeeds {
    nonisolated func peakDBFS(_ track: MeetingTrack) -> Double {
        levels.peakDBFS(track)
    }

    func readStartFacts() async -> MeetingRecorderStartFacts? {
        startFacts
    }
}
