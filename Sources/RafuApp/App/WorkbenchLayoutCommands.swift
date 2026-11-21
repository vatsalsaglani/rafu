import SwiftUI

/// View menu items for the workbench layout: switch the navigator section
/// with ⌘1 to ⌘6, move the rail and sidebar to the other window edge, and
/// Zen mode. Each item has a menu path, a key path and a command palette
/// entry (`CommandPaletteView`).
struct WorkbenchLayoutCommands: Commands {
    @FocusedValue(\.workspaceSession) private var session
    @AppStorage(WorkbenchLayoutPreferences.sidebarEdgeKey) private var sidebarEdgeRaw =
        WorkbenchSidebarEdge.standard.rawValue

    private var sidebarEdge: WorkbenchSidebarEdge {
        WorkbenchSidebarEdge.resolve(raw: sidebarEdgeRaw)
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(WorkspaceNavigatorMode.allCases, id: \.self) { mode in
                Button(mode.title) { session?.switchNavigator(to: mode) }
                    .keyboardShortcut(KeyEquivalent(mode.shortcutDigit), modifiers: .command)
                    .disabled(session?.isNavigatorModeAvailable(mode) != true)
            }
            Divider()
            Button(sidebarEdge.moveCommandTitle) {
                sidebarEdgeRaw = sidebarEdge.opposite.rawValue
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            Button(WorkbenchLayoutShortcuts.zenCommandTitle(isOn: session?.isZenMode == true)) {
                session?.toggleZenMode()
            }
            .keyboardShortcut("z", modifiers: [.control, .command])
            // A window with no folder shows the welcome screen and has no
            // rail to hide; leaving Zen stays possible either way.
            .disabled(session == nil || (session?.descriptor == nil && session?.isZenMode != true))
        }
    }
}
