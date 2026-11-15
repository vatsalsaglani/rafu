import Testing

@testable import RafuApp

/// The left Activity Rail's interaction contract (user decision 2026-10-19,
/// Phase 2 of the window redesign): `navigatorMode` selects which section the
/// one left sidebar shows and is never "closed"; `isSidebarCollapsed` is the
/// single, separate visibility bit, toggled only by `toggleSidebar()`
/// (`WindowTitlebarRow`'s button and ⌘B) or by a click on the selected rail
/// icon. The panel headers have no close button (ADR 0002: one sidebar
/// toggle; the sidebar redesign removed the header ✕).
///
///   | Click an unselected rail icon | mode = X; expand if collapsed |
///   | Click the selected rail icon  | toggle collapsed; mode kept   |
///   | Titlebar toggle / ⌘B          | toggle collapsed only         |
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

    /// The panel header ✕ was a second sidebar toggle. With it gone, the
    /// active rail icon is the in-panel way to hide the sidebar, so it must
    /// collapse every mode and keep that mode for the next show.
    @Test(
        "The active rail icon hides the sidebar for every panel and keeps its mode",
        arguments: WorkspaceNavigatorMode.allCases)
    func activeRailIconHidesEveryPanel(mode: WorkspaceNavigatorMode) {
        let session = WorkspaceSession()
        session.navigatorMode = mode
        session.isSidebarCollapsed = false

        session.selectNavigatorRailIcon(mode)

        #expect(session.navigatorMode == mode)
        #expect(session.isSidebarCollapsed == true)
    }

    @Test("The active rail icon says that a click hides its panel")
    func activeRailIconAnnouncesHide() {
        #expect(
            NavigatorRailPresentation.tooltip(
                title: "Source Control", isEnabled: true, isActive: true)
                == "Hide Source Control")
        #expect(
            NavigatorRailPresentation.tooltip(title: "Search", isEnabled: true, isActive: false)
                == "Search")
        #expect(
            NavigatorRailPresentation.tooltip(title: "History", isEnabled: false, isActive: false)
                == "History — open a folder first")
        #expect(
            NavigatorRailPresentation.accessibilityValue(isActive: true, attentionCount: 0)
                == "Selected, sidebar shown")
        #expect(
            NavigatorRailPresentation.accessibilityValue(isActive: false, attentionCount: 2)
                == "2 needing attention")
        #expect(
            NavigatorRailPresentation.accessibilityValue(isActive: true, attentionCount: 1)
                == "Selected, sidebar shown, 1 needing attention")
        #expect(
            NavigatorRailPresentation.accessibilityValue(isActive: false, attentionCount: 0)
                == nil)
    }
}
