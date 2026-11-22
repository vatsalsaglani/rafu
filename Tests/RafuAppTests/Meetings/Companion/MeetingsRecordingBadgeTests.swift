import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Meetings recording badge on the closed surfaces")
struct MeetingsRecordingBadgeTests {
    @Test("Only the paused state draws the pause mark")
    func pausedStateOnly() {
        let meeting = MeetingID()
        #expect(MeetingsRecordingBadge.isPaused(.paused(meeting)))
        #expect(!MeetingsRecordingBadge.isPaused(.recording(meeting)))
        #expect(!MeetingsRecordingBadge.isPaused(.idle))
    }

    @Test("A factory with no feature shows no badge and makes no feature")
    func noFeatureNoBadge() {
        let factory = MeetingsFeatureFactory(isShared: false)
        #expect(factory.feature == nil)
        _ = MeetingsRecordingBadge(factory: factory).body
        #expect(factory.feature == nil)
        #expect(factory.makeCount == 0)
    }
}
