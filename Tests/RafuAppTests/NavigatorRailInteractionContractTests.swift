import Testing

@testable import RafuApp

/// The left Activity Rail's interaction contract (user decision 2026-10-19,
/// Phase 2 of the window redesign): `navigatorMode` selects which section the
/// one left sidebar shows and is never "closed"; `isSidebarCollapsed` is the
/// single, separate visibility bit, toggled only by `toggleSidebar()`
/// (`WindowTitlebarRow`'s button and ⌘B) or by a panel header's close button.
///
///   | Click an unselected rail icon | mode = X; expand if collapsed |
///   | Click the selected rail icon  | toggle collapsed; mode kept   |
///   | Titlebar toggle / ⌘B          | toggle collapsed only         |
///   | Panel header ✕ (onClose)      | collapse; mode kept           |
@Suite("Navigator rail interaction contract")
@MainActor
struct NavigatorRailInteractionContractTests {
    @Test("Selecting an unselected mode shows it, expanding a collapsed sidebar")
    func selectingUnselectedModeExpandsAndSwitches() {
        let session = WorkspaceSession()
        session.isSidebarCollapsed = true

        session.selectNavigatorRailIcon(.search)

        #expect(session.navigatorMode == .search)
        #expect(session.isSidebarCollapsed == false)
    }

    @Test("Selecting an unselected mode while already expanded only switches the mode")
    func selectingUnselectedModeWhileExpandedStaysExpanded() {
        let session = WorkspaceSession()
        session.navigatorMode = .files
        session.isSidebarCollapsed = false

        session.selectNavigatorRailIcon(.terminals)

        #expect(session.navigatorMode == .terminals)
        #expect(session.isSidebarCollapsed == false)
    }

    @Test("Clicking the already-selected rail icon toggles collapse and keeps the mode")
    func selectingSelectedModeTogglesCollapseOnly() {
        let session = WorkspaceSession()
        session.navigatorMode = .sourceControl
        session.isSidebarCollapsed = false

        session.selectNavigatorRailIcon(.sourceControl)
        #expect(session.navigatorMode == .sourceControl)
        #expect(session.isSidebarCollapsed == true)

        session.selectNavigatorRailIcon(.sourceControl)
        #expect(session.navigatorMode == .sourceControl)
        #expect(session.isSidebarCollapsed == false)
    }

    @Test("showNavigator always selects the mode and expands, regardless of prior state")
    func showNavigatorAlwaysExpands() {
        let session = WorkspaceSession()
        session.navigatorMode = .files
        session.isSidebarCollapsed = false

        session.showNavigator(.history)
        #expect(session.navigatorMode == .history)
        #expect(session.isSidebarCollapsed == false)

        session.isSidebarCollapsed = true
        session.showNavigator(.history)
        #expect(session.navigatorMode == .history)
        #expect(session.isSidebarCollapsed == false)
    }

    @Test("Toggling the sidebar (titlebar button and ⌘B) never changes the selected mode")
    func toggleSidebarPreservesMode() {
        let session = WorkspaceSession()
        session.navigatorMode = .terminals
        session.isSidebarCollapsed = false

        session.toggleSidebar()
        #expect(session.navigatorMode == .terminals)
        #expect(session.isSidebarCollapsed == true)

        session.toggleSidebar()
        #expect(session.navigatorMode == .terminals)
        #expect(session.isSidebarCollapsed == false)
    }

    @Test("A panel header's close collapses the sidebar and keeps its mode")
    func panelHeaderCloseCollapsesAndKeepsMode() {
        let session = WorkspaceSession()
        session.navigatorMode = .history
        session.isSidebarCollapsed = false

        // This mirrors every `RafuUtilityPanelHeader(onClose:)` closure in
        // Search, Source Control, Terminals, and History.
        session.isSidebarCollapsed = true

        #expect(session.navigatorMode == .history)
        #expect(session.isSidebarCollapsed == true)
    }
}
