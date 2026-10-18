import RafuCore
import SwiftUI

@main
struct RafuApplication: App {
    static let displayName = RafuBuildInformation.appName

    @NSApplicationDelegateAdaptor(RafuAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(Self.displayName, id: "workspace") {
            WorkspaceSceneRoot()
        }
        .defaultSize(width: 1_100, height: 720)
        .windowResizability(.contentMinSize)
        // Set the initial title presentation before SwiftUI orders a new
        // window. The AppKit bridge handles safe areas and later transitions.
        .windowStyle(.hiddenTitleBar)
        .commands {
            RafuAppCommands()
            CanvasNoteCommands()
            WorkspacesWindowCommands()
        }

        // Saved workspaces and recent folders (Window > Show All Workspaces,
        // ⇧⌘1). The scene's automatic Window-menu item is removed so that
        // command is the one menu path.
        Window("Workspaces", id: WorkspacesWindow.id) {
            WorkspacesWindowView()
        }
        .defaultSize(width: 560, height: 480)
        .commandsRemoved()

        Settings {
            RafuSettingsView()
        }
        .defaultSize(
            width: SettingsPresentationLayout.windowWidth,
            height: SettingsPresentationLayout.idealPaneHeight
        )
    }
}
