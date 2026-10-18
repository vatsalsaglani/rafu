import SwiftUI

/// The Workspaces window's scene identifier.
enum WorkspacesWindow {
    static let id = "workspaces"
}

/// File menu items placed after "Open Folder…".
struct WorkspaceOpenCommandItems: View {
    let session: WorkspaceSession?

    var body: some View {
        Button("Open Workspace…") { session?.requestOpenWorkspaceFile() }
            .disabled(session == nil)
        Button("Add Folder to Workspace…") { session?.requestAddFolder() }
            .disabled(session?.rootURL == nil)
    }
}

/// File menu items placed after the Save group.
struct WorkspaceSaveCommandItems: View {
    let session: WorkspaceSession?

    var body: some View {
        Button("Save Workspace") { session?.saveWorkspaceToBoundFile() }
            .disabled(session?.workspaceFileURL == nil || session?.rootURL == nil)
        Button("Save Workspace As…") { session?.requestSaveWorkspaceAs() }
            .disabled(session?.rootURL == nil)
    }
}

/// Window menu: "Show All Workspaces" (⇧⌘1) opens the Workspaces window.
struct WorkspacesWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowList) {
            Button("Show All Workspaces") { openWindow(id: WorkspacesWindow.id) }
                .keyboardShortcut("1", modifiers: [.command, .shift])
            Divider()
        }
    }
}
