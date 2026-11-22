import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Meetings Welcome card")
struct MeetingsWelcomeCardTests {
    @MainActor
    @Test("The registered Welcome card builds from a test feature without making the shared one")
    func cardBuildsFromTestFeature() {
        let feature = MeetingsFeature(availability: .available)
        feature.registerWorkspaceParts()
        let hook = feature.welcomeCard
        #expect(hook != nil)
        _ = hook?(feature, WorkspaceSession())
        #expect(MeetingsFeatureFactory.shared.feature == nil)
    }

    @MainActor
    @Test("The Welcome card shows the macOS 26 line when Meetings is not available")
    func unavailableReason() {
        let feature = MeetingsFeature(availability: .needsMacOS26)
        #expect(feature.availability.unavailableReason == "Meetings needs macOS 26")
        #expect(!feature.session.canStartRecording)
    }

    @Test("Three rows is the Welcome limit")
    func recentLimit() {
        #expect(MeetingsWorkspacePresentation.welcomeRecentCount == 3)
    }
}
