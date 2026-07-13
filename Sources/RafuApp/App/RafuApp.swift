import RafuCore
import SwiftUI

@main
struct RafuApplication: App {
    @NSApplicationDelegateAdaptor(RafuAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Rafu", id: "workspace") {
            WorkspaceSceneRoot()
        }
        .defaultSize(width: 1_100, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            RafuAppCommands()
        }

        Settings {
            RafuSettingsView()
        }
    }
}
