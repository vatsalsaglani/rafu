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
        .windowToolbarStyle(.unified)
        .commands {
            RafuAppCommands()
        }

        Settings {
            RafuSettingsView()
        }
        .defaultSize(width: 760, height: 620)
    }
}
