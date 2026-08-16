import AppKit

/// Creates the native panel used by every workspace-open action. The panel
/// stays imperative because `WorkspaceWindowView` already owns a separate
/// SwiftUI `fileImporter` for Terminal Pane starting folders; mounting two
/// importers on one window causes the later presentation host to shadow the
/// earlier one on macOS 26.
@MainActor
enum WorkspaceFolderPicker {
    static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.title = "Open Folder"
        panel.prompt = "Open"
        panel.message = "Choose a folder to open as a workspace."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        return panel
    }
}
