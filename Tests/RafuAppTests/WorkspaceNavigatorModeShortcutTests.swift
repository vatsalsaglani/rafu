import Testing

@testable import RafuApp

@Suite("Navigator mode shortcuts")
struct WorkspaceNavigatorModeShortcutTests {
    @Test("Digits are one to six, in rail order")
    func digitsAreOneToSixInRailOrder() {
        let digits = WorkspaceNavigatorMode.allCases.map(\.shortcutDigit)
        #expect(digits == ["1", "2", "3", "4", "5", "6"])
        #expect(
            WorkspaceNavigatorMode.allCases == [
                .files, .search, .sourceControl, .terminals, .ensemble, .history,
            ])
    }

    @Test("Labels show the full shortcut")
    func labelsShowTheFullShortcut() {
        #expect(WorkspaceNavigatorMode.files.shortcutLabel == "⌘1")
        #expect(WorkspaceNavigatorMode.history.shortcutLabel == "⌘6")
        #expect(WorkspaceNavigatorMode.terminals.shortcutHint == "Command 4")
    }

    @Test("The rail tooltip names the shortcut for a usable icon only")
    func tooltipNamesTheShortcut() {
        #expect(
            NavigatorRailPresentation.tooltip(
                title: "Search", isEnabled: true, isActive: false, shortcut: "⌘2")
                == "Search (⌘2)")
        #expect(
            NavigatorRailPresentation.tooltip(
                title: "Files", isEnabled: true, isActive: true, shortcut: "⌘1")
                == "Hide Files (⌘1)")
        #expect(
            NavigatorRailPresentation.tooltip(
                title: "History", isEnabled: false, isActive: false, shortcut: "⌘6")
                == "History — open a folder first")
    }
}
