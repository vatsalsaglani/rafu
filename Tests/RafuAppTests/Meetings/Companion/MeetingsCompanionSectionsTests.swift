import Foundation
import Synchronization
import Testing

@testable import RafuApp

/// Where the Meetings section shows, when its tab list is computed again,
/// how the tab titles shrink in a long row, and what the app makes at launch.
@Suite("Meetings companion sections")
struct MeetingsCompanionSectionsTests {
    private static let everySection: [NotchSection] = [
        .ensembles, .upNext, .nowPlaying, .usage, .meetings,
    ]

    // MARK: Menu bar card

    @Test("The menu bar card offers Meetings after Usage, never Now Playing")
    func menuBarCardOffersMeetings() {
        #expect(
            NotchSection.offered(Self.everySection, host: .menuBar)
                == [.ensembles, .upNext, .usage, .meetings])
        // The person turned the Meetings tab off: the card drops it.
        let withoutMeetings = Self.everySection.filter { $0 != .meetings }
        #expect(
            NotchSection.offered(withoutMeetings, host: .menuBar) == [.ensembles, .upNext, .usage])
        // The notch panel keeps every section; the island card keeps Usage only.
        #expect(NotchSection.offered(Self.everySection, host: .notchPanel) == Self.everySection)
        #expect(NotchSection.offered(Self.everySection, host: .islandCard) == [.usage])
    }

    // MARK: Tab list recomputed

    @Test("The gate posts one notification, and only when its value changes")
    func gatePostsOnChange() {
        let gate = MeetingsCompanionGate()
        let count = Mutex(0)
        let token = NotificationCenter.default.addObserver(
            forName: MeetingsCompanionGate.didChangeNotification, object: gate, queue: nil
        ) { _ in count.withLock { $0 += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        #expect(!gate.isRecorderRegistered)
        gate.setRecorderRegistered(false)
        #expect(count.withLock { $0 } == 0)
        gate.setRecorderRegistered(true)
        #expect(gate.isRecorderRegistered)
        #expect(count.withLock { $0 } == 1)
        gate.setRecorderRegistered(true)
        #expect(count.withLock { $0 } == 1)
        gate.setRecorderRegistered(false)
        #expect(count.withLock { $0 } == 2)
    }

    @MainActor
    @Test("The companion model computes its tabs again when the gate notification arrives")
    func modelRecomputesOnGateNotification() {
        let suite = TestDefaultsSuite.name("dev.rafu.tests.meetings-gate")
        defer { TestDefaultsSuite.remove(suite) }
        let model = NotchCompanionModel()
        model.displayPreferences = NotchDisplayPreferenceStore(suiteName: suite)
        model.setSurfaceForTesting(.notch)
        #expect(model.visibleSections.contains(.upNext))

        // Only the stored flag changes, so the shared gate stays as it is
        // for the tests that run beside this one. A model that does not
        // listen would keep its old tab list.
        model.displayPreferences.setSection(.upNext, visible: false)
        #expect(model.visibleSections.contains(.upNext))
        NotificationCenter.default.post(
            name: MeetingsCompanionGate.didChangeNotification, object: MeetingsCompanionGate.shared)
        #expect(!model.visibleSections.contains(.upNext))
        #expect(!model.sections(for: .menuBar).contains(.upNext))
    }

    // MARK: Tab titles

    @Test("With more than four tabs only the selected tab shows its title")
    func tabTitleRule() {
        for count in 1...4 {
            #expect(CompanionChromeMetrics.showsTabTitle(selected: false, tabCount: count))
            #expect(CompanionChromeMetrics.showsTabTitle(selected: true, tabCount: count))
        }
        #expect(CompanionChromeMetrics.showsTabTitle(selected: true, tabCount: 5))
        #expect(!CompanionChromeMetrics.showsTabTitle(selected: false, tabCount: 5))
        #expect(!CompanionChromeMetrics.showsTabTitle(selected: false, tabCount: 6))
    }

    @Test("A tab keeps its title in its accessibility label and its help text")
    func tabKeepsTitleForAssistiveTools() throws {
        let source = try SidebarPanelRedesignTests.source(
            "Sources/RafuApp/Views/NotchCompanionView.swift")
        let bar = try SidebarPanelRedesignTests.section(
            of: source, from: "struct CompanionTabBar: View",
            to: "private struct CompanionTabShortcut")
        #expect(bar.contains("CompanionChromeMetrics.showsTabTitle"))
        #expect(bar.contains(".accessibilityLabel(section.title +"))
        #expect(bar.contains(".help(section.title)"))
    }

    // MARK: Launch

    @MainActor
    @Test("Launch makes nothing on a Mac without Meetings, and no registration in a test factory")
    func launchPreparation() {
        let old = MeetingsFeatureFactory(availability: .needsMacOS26)
        old.prepareStatusAtLaunch()
        #expect(old.feature == nil)
        #expect(old.makeCount == 0)

        let factory = MeetingsFeatureFactory(availability: .available)
        factory.prepareStatusAtLaunch()
        #expect(factory.makeCount == 1)
        // A test factory registers nothing: no store, no recorder, no engine.
        #expect(factory.feature?.registeredKinds.isEmpty == true)
        factory.prepareStatusAtLaunch()
        #expect(factory.resolve() === factory.feature)
        #expect(factory.makeCount == 1)
    }
}
