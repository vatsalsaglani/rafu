import Foundation
import Testing

@testable import RafuApp

@Suite("Workspace session Zen mode")
@MainActor
struct WorkspaceSessionZenModeTests {
    @Test("Toggling Zen mode hides the rail and the sidebar")
    func toggleZenModeHidesRailAndSidebar() {
        let session = WorkspaceSession()
        #expect(session.showsNavigatorRail)
        #expect(session.showsSidebarPane)

        session.toggleZenMode()
        #expect(session.isZenMode)
        #expect(!session.showsNavigatorRail)
        #expect(!session.showsSidebarPane)

        session.toggleZenMode()
        #expect(!session.isZenMode)
        #expect(session.showsNavigatorRail)
        #expect(session.showsSidebarPane)
    }

    @Test("Zen mode keeps a collapsed sidebar collapsed when it ends")
    func leavingZenRestoresTheCollapseBit() {
        let session = WorkspaceSession()
        session.isSidebarCollapsed = true
        session.toggleZenMode()
        session.toggleZenMode()
        #expect(session.isSidebarCollapsed)
        #expect(session.showsNavigatorRail)
        #expect(!session.showsSidebarPane)
    }

    @Test("Showing a navigator mode leaves Zen mode and expands the sidebar")
    func showNavigatorLeavesZenModeAndExpandsTheSidebar() {
        let session = WorkspaceSession()
        session.isSidebarCollapsed = true
        session.toggleZenMode()

        session.showNavigator(.search)

        #expect(!session.isZenMode)
        #expect(session.navigatorMode == .search)
        #expect(!session.isSidebarCollapsed)
        #expect(session.showsSidebarPane)
    }

    @Test("A rail icon press in Zen mode switches mode instead of toggling the sidebar")
    func railIconLeavesZenMode() {
        let session = WorkspaceSession()
        session.navigatorMode = .files
        session.toggleZenMode()

        session.selectNavigatorRailIcon(.files)

        #expect(!session.isZenMode)
        #expect(!session.isSidebarCollapsed)
    }

    @Test("Toggling the sidebar leaves Zen mode and shows the sidebar")
    func toggleSidebarLeavesZenMode() {
        let session = WorkspaceSession()
        session.toggleZenMode()

        session.toggleSidebar()

        #expect(!session.isZenMode)
        #expect(!session.isSidebarCollapsed)
        #expect(session.showsSidebarPane)
    }

    @Test("A number key leaves Zen mode and switches")
    func numberKeyLeavesZenMode() {
        let session = WorkspaceSession()
        session.toggleZenMode()

        session.switchNavigator(to: .files)

        #expect(!session.isZenMode)
        #expect(session.navigatorMode == .files)
    }

    @Test("A number key for a mode that needs a folder does nothing without one")
    func numberKeyNeedsAFolderForNonFilesModes() {
        let session = WorkspaceSession()
        session.toggleZenMode()

        #expect(!session.isNavigatorModeAvailable(.history))
        #expect(session.isNavigatorModeAvailable(.files))
        session.switchNavigator(to: .history)

        #expect(session.isZenMode)
        #expect(session.navigatorMode == .files)
    }

    @Test("Zen mode is not restored")
    func zenModeIsNotRestored() throws {
        let payload = RestorableWorkspace(
            bookmark: Data(), rootPath: "/tmp/zen", openRelativePaths: [],
            selectedRelativePath: nil, navigatorMode: .files, editorLayout: nil)
        let data = try JSONEncoder().encode(payload)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object.keys.allSatisfy { !$0.lowercased().contains("zen") })

        // A fresh session after a restore always shows the rail and sidebar.
        #expect(!WorkspaceSession().isZenMode)
    }
}
