import SwiftUI

struct RafuAppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceSession) private var workspaceSession

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // Issue #6: ⌘N opens a blank untitled document (⌘S saves it
            // anywhere via a save panel), matching VS Code's File > New File
            // instead of opening a second window.
            Button("New File") {
                workspaceSession?.newUntitledDocument()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(workspaceSession == nil)

            // Issue #7: what ⌘N used to do (open a new window) moves to
            // ⌘⇧N.
            Button("New Workspace Window") {
                openWindow(id: "workspace")
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

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
            Button("Select Next Occurrence") { workspaceSession?.selectNextOccurrence() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(workspaceSession?.selectedDocument == nil)
            Button("Select All Occurrences") { workspaceSession?.selectAllOccurrences() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(workspaceSession?.selectedDocument == nil)
            Button("Add Caret Above") { workspaceSession?.addCaretAbove() }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(workspaceSession?.selectedDocument == nil)
            Button("Add Caret Below") { workspaceSession?.addCaretBelow() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
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

            // Issue #14: ⌘B toggles the Files/Search/Source Control
            // sidebar, mirroring `NavigationSplitView`'s own built-in
            // toolbar toggle (ADR 0002's "one system sidebar toggle" — this
            // is a keyboard path to that same control, not a second one).
            Button("Toggle Sidebar") {
                workspaceSession?.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)
            .disabled(workspaceSession == nil)

            // Issue #14: ⌃G opens the command palette seeded with ":" for
            // go-to-line ("Go to Line…" mirrors VS Code's Ctrl+G).
            Button("Go to Line…") {
                workspaceSession?.showCommandPalette(seed: ":")
            }
            .keyboardShortcut("g", modifiers: [.control])
            .disabled(workspaceSession?.selectedDocument == nil)

            Button("Search Workspace") {
                workspaceSession?.navigatorMode = .search
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            // Issue #14: ⌘⇧G stays Show Source Control — do NOT rebind ⌘G.
            Button("Show Source Control") {
                workspaceSession?.toggleUtilityPane(.sourceControl)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])

            Divider()

            Button("Stage Hunk") {
                guard let session = workspaceSession,
                    let hunk = soleHunk(in: session, scope: .workingTree)
                else { return }
                Task { await session.stageHunk(hunk) }
            }
            .disabled(
                workspaceSession.map {
                    soleHunk(in: $0, scope: .workingTree) == nil || $0.isGitBusy
                        || $0.isGitHunkActionBusy
                } ?? true
            )

            Button("Unstage Hunk") {
                guard let session = workspaceSession,
                    let hunk = soleHunk(in: session, scope: .staged)
                else { return }
                Task { await session.unstageHunk(hunk) }
            }
            .disabled(
                workspaceSession.map {
                    soleHunk(in: $0, scope: .staged) == nil || $0.isGitBusy
                        || $0.isGitHunkActionBusy
                } ?? true
            )

            Button("Stash Changes") {
                guard let session = workspaceSession else { return }
                Task { await session.stashChanges(message: "", includeUntracked: false) }
            }
            .disabled(
                workspaceSession.map {
                    !hasTrackedChanges(in: $0) || $0.isGitBusy || $0.isGitHunkActionBusy
                } ?? true
            )

            Button("Blame File") {
                guard let session = workspaceSession else { return }
                Task { await session.openBlameForSelectedFile() }
            }
            .disabled(
                workspaceSession.map {
                    $0.selectedDocument == nil || $0.selectedDocument?.isDirty == true
                        || $0.gitSnapshot == nil || $0.isGitBusy
                } ?? true
            )

            Button("Toggle Inline Blame") {
                workspaceSession?.toggleInlineBlame()
            }
            .disabled(workspaceSession == nil)

            Button("Toggle AI Completion") {
                workspaceSession?.toggleAICompletion()
            }
            .disabled(workspaceSession == nil)

            Button("Peek Change at Line") {
                workspaceSession?.peekChangeAtCaret()
            }
            .disabled(
                workspaceSession.map {
                    $0.selectedDocument == nil || $0.gitSnapshot == nil
                } ?? true
            )

            Divider()

            Button("Toggle Terminal") {
                workspaceSession?.toggleTerminal()
            }
            .keyboardShortcut("`", modifiers: [.control])

            Button("New Terminal Tab") {
                workspaceSession?.newTerminalTab()
            }
            .keyboardShortcut("`", modifiers: [.control, .shift])

            Button("Show Resources") {
                workspaceSession?.showResources()
            }
            .accessibilityIdentifier(NavigationCommandID.showResources)
            .disabled(workspaceSession == nil)

            Divider()

            Button("Go to Definition") {
                workspaceSession?.navigate(kind: .definition)
            }
            .keyboardShortcut("j", modifiers: [.control, .command])
            .accessibilityIdentifier(NavigationCommandID.goToDefinition)
            .disabled(workspaceSession?.selectedDocument == nil)

            Button("Go to Declaration") {
                workspaceSession?.navigate(kind: .declaration)
            }
            .accessibilityIdentifier(NavigationCommandID.goToDeclaration)
            .disabled(workspaceSession?.selectedDocument == nil)

            Button("Find References") {
                workspaceSession?.navigate(kind: .references)
            }
            .keyboardShortcut("r", modifiers: [.control, .command])
            .accessibilityIdentifier(NavigationCommandID.findReferences)
            .disabled(workspaceSession?.selectedDocument == nil)

            Divider()

            Button("Close Editor") {
                workspaceSession?.requestCloseActiveTab()
            }
            .keyboardShortcut("w", modifiers: .command)
        }
    }

    private func soleHunk(in session: WorkspaceSession, scope: GitDiffScope) -> GitDiffHunk? {
        guard let openDiff = session.gitOpenDiff,
            openDiff.scope == scope,
            openDiff.diff.hunks.count == 1,
            session.gitSnapshot?.changes.first(where: { $0.path == openDiff.diff.path })?.kind
                == .modified
        else { return nil }
        return openDiff.diff.hunks[0]
    }

    private func hasTrackedChanges(in session: WorkspaceSession) -> Bool {
        session.gitSnapshot?.changes.contains { $0.kind != .untracked } == true
    }
}
