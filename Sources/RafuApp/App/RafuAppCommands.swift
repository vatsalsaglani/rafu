import SwiftUI

struct RafuAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceSession) private var workspaceSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Workspace Window") {
                openWindow(id: "workspace")
            }
            .keyboardShortcut("n", modifiers: .command)

            Button("Open Folder…") {
                workspaceSession?.requestOpenFolder()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(workspaceSession == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") { workspaceSession?.saveSelectedDocument() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(workspaceSession?.selectedDocument == nil)
        }

        // Replaces the default File > Print… so ⌘P owns Go to File.
        CommandGroup(replacing: .printItem) {
            Button("Go to File…") {
                workspaceSession?.showCommandPalette(seed: "")
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(workspaceSession == nil)
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Toggle Line Comment") { workspaceSession?.toggleLineComment() }
                .keyboardShortcut("/", modifiers: .command)
                .disabled(workspaceSession?.selectedDocument == nil)
            Divider()
            Button("Find in File…") { workspaceSession?.showDocumentFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(workspaceSession?.selectedDocument == nil)
            Button("Find and Replace in File…") {
                workspaceSession?.showDocumentFind(includeReplace: true)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(workspaceSession?.selectedDocument == nil)
        }

        CommandMenu("Rafu") {
            Button("Command Palette…") {
                workspaceSession?.showCommandPalette(seed: ">")
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Button("Search Workspace") {
                workspaceSession?.navigatorMode = .search
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Show Source Control") {
                workspaceSession?.toggleUtilityPane(.sourceControl)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Button("Toggle Terminal") {
                workspaceSession?.toggleTerminal()
            }
            .keyboardShortcut("`", modifiers: [.control])

            Button("New Terminal Tab") {
                workspaceSession?.newTerminalTab()
            }
            .keyboardShortcut("`", modifiers: [.control, .shift])

            Divider()

            Button("Close Editor") {
                workspaceSession?.requestCloseActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }
}
