import Foundation
import Testing

@testable import RafuApp

@Suite("Workbench layout preferences")
struct WorkbenchLayoutPreferencesTests {
    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = TestDefaultsSuite.name("workbench-layout")
        defer { TestDefaultsSuite.remove(name) }
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Could not make a test defaults suite")
            return
        }
        body(defaults)
    }

    @Test("The default edge is leading")
    func defaultEdgeIsLeading() {
        withDefaults { defaults in
            #expect(WorkbenchLayoutPreferences.sidebarEdge(in: defaults) == .leading)
        }
    }

    @Test("Toggling stores trailing, and toggling again stores leading")
    func toggleStoresTrailing() {
        withDefaults { defaults in
            let first = WorkbenchLayoutPreferences.toggleSidebarEdge(in: defaults)
            #expect(first == .trailing)
            #expect(
                defaults.string(forKey: WorkbenchLayoutPreferences.sidebarEdgeKey) == "trailing")
            #expect(WorkbenchLayoutPreferences.sidebarEdge(in: defaults) == .trailing)

            let second = WorkbenchLayoutPreferences.toggleSidebarEdge(in: defaults)
            #expect(second == .leading)
            #expect(WorkbenchLayoutPreferences.sidebarEdge(in: defaults) == .leading)
        }
    }

    @Test("An unknown stored value reads as leading")
    func unknownStoredValueReadsAsLeading() {
        withDefaults { defaults in
            defaults.set("sideways", forKey: WorkbenchLayoutPreferences.sidebarEdgeKey)
            #expect(WorkbenchLayoutPreferences.sidebarEdge(in: defaults) == .leading)
        }
        #expect(WorkbenchSidebarEdge.resolve(raw: nil) == .leading)
    }

    @Test("The move command names the edge the sidebar goes to")
    func moveCommandTitleNamesTheDestination() {
        #expect(WorkbenchSidebarEdge.leading.moveCommandTitle == "Move Sidebar to Right")
        #expect(WorkbenchSidebarEdge.trailing.moveCommandTitle == "Move Sidebar to Left")
    }

    @Test("The seam offset mirrors on the trailing edge")
    func seamOffsetMirrors() {
        #expect(WorkbenchSidebarEdge.leading.seamOffset(distance: 258) == 258)
        #expect(WorkbenchSidebarEdge.trailing.seamOffset(distance: 258) == -258)
    }

    @Test("Zen announcement names the real shortcut")
    func zenAnnouncementNamesTheShortcut() {
        #expect(
            WorkbenchLayoutShortcuts.zenAnnouncement(isOn: true)
                == "Zen mode on. Press ⌃⌘Z to leave.")
        #expect(WorkbenchLayoutShortcuts.zenCommandTitle(isOn: false) == "Enter Zen Mode")
        #expect(WorkbenchLayoutShortcuts.zenCommandTitle(isOn: true) == "Exit Zen Mode")
    }
}
