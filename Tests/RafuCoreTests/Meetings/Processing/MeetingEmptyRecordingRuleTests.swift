import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting empty recording rule")
struct MeetingEmptyRecordingRuleTests {
    private static let interrupted = MeetingState.failed(
        reasonCode: MeetingProcessingFailure.interrupted)

    @Test("Recording, paused and failed-interrupted with nothing in them are deleted")
    func emptyStatesDelete() {
        for state in [MeetingState.recording, .paused, Self.interrupted] {
            #expect(
                MeetingEmptyRecordingRule.shouldDelete(
                    state: state, hasFinalAudio: false, recoveredSeconds: 0, turnCount: 0),
                "\(state)")
        }
    }

    @Test("Processing, ready and other failures are never deleted")
    func otherStatesKeep() {
        for state in [
            MeetingState.processing, .ready,
            .failed(reasonCode: MeetingProcessingFailure.textFailed),
            .failed(reasonCode: MeetingProcessingFailure.noAudio),
        ] {
            #expect(
                !MeetingEmptyRecordingRule.shouldDelete(
                    state: state, hasFinalAudio: false, recoveredSeconds: 0, turnCount: 0),
                "\(state)")
        }
    }

    @Test("A final audio file keeps the meeting")
    func finalAudioKeeps() {
        #expect(
            !MeetingEmptyRecordingRule.shouldDelete(
                state: .recording, hasFinalAudio: true, recoveredSeconds: 0, turnCount: 0))
    }

    @Test("Recovered seconds keep the meeting; a value that is not 0 is not empty")
    func recoveredKeeps() {
        for seconds in [0.5, 42, -1, .nan] as [TimeInterval] {
            #expect(
                !MeetingEmptyRecordingRule.shouldDelete(
                    state: .paused, hasFinalAudio: false, recoveredSeconds: seconds,
                    turnCount: 0),
                "\(seconds)")
        }
    }

    @Test("A turn keeps the meeting")
    func turnKeeps() {
        #expect(
            !MeetingEmptyRecordingRule.shouldDelete(
                state: Self.interrupted, hasFinalAudio: false, recoveredSeconds: 0, turnCount: 1))
    }
}
