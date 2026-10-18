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
        }

        Settings {
            RafuSettingsView()
        }
        .defaultSize(
            width: SettingsPresentationLayout.windowWidth,
            height: SettingsPresentationLayout.idealPaneHeight
        )
    }
}
