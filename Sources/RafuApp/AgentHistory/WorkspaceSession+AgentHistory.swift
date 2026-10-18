import AppKit
import Foundation
import RafuCore

/// Agent History actions for one workspace window (round-2 X12). Every
/// action is read-only toward the transcript files and starts only from an
/// explicit user click.
extension WorkspaceSession {
    /// This window's folders, for "This Workspace". Symlinked folders are
    /// matched by both their given and their resolved path.
    var agentHistoryWorkspaceRoots: [String] {
        guard let rootURL else { return [] }
        let given = rootURL.standardizedFileURL.path
        let resolved = rootURL.resolvingSymlinksInPath().standardizedFileURL.path
        return given == resolved ? [given] : [given, resolved]
    }

    /// Shows the History navigator. `focusSearch` also moves keyboard focus
    /// to its search field ("Search Agent History…").
    func showAgentHistory(focusSearch: Bool = false) {
        navigatorMode = .history
        if focusSearch { agentHistory.searchFocusRequest &+= 1 }
    }

    /// Opens (or selects) the read-only Agent Session tab for `session`.
    func openAgentSession(_ session: AgentHistorySessionSummary) {
        let reference = AgentSessionTabReference(key: session.key, title: session.title)
        _ = agentHistory.openTranscript(for: session)
        prepareAuxiliarySelection()
        suspendAuxiliarySelection()
        agentHistory.visibleSession = reference
        selectedDocumentID = nil
        selectedTreePath = nil
        recordAuxiliaryTab(.agentSession(reference))
    }

    func revealAgentTranscript(_ session: AgentHistorySessionSummary) {
        guard FileManager.default.fileExists(atPath: session.fileURL.path) else {
            presentAgentHistoryMessage("The transcript file is no longer there.")
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([session.fileURL])
    }

    func copyAgentSessionID(_ session: AgentHistorySessionSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.key.sessionID, forType: .string)
    }

    /// Focuses a window that already shows the folder, else opens a new
    /// workspace window for it. The current window keeps its workspace.
    func openAgentProjectFolder(_ session: AgentHistorySessionSummary) {
        guard let folder = existingAgentProjectFolder(session) else { return }
        let target = AgentHistoryPath.normalized(folder.resolvingSymlinksInPath().path)
        for snapshot in WorkspaceWindowRegistry.shared.snapshots() {
            guard let root = snapshot.rootURL else { continue }
            if AgentHistoryPath.normalized(root.resolvingSymlinksInPath().path) == target {
                WorkspaceWindowRegistry.shared.focus(windowID: snapshot.windowID)
                return
            }
        }
        ExternalOpenRequests.shared.enqueueForNewWindow(folder)
        if !WorkspaceWindowRegistry.shared.openWorkspaceWindow() {
            ExternalOpenRequests.shared.cancelNewWindowRequest(folder)
            presentAgentHistoryMessage("Rafu could not open a new window.")
        }
    }

    /// Opens a terminal in the session's folder and types the resume command
    /// (`claude --resume <id>` / `codex resume <id>`). The folder must be
    /// open in a Rafu window: this one, or another one, which then comes to
    /// the front.
    func resumeAgentSession(_ session: AgentHistorySessionSummary) {
        guard let arguments = AgentHistoryResumeCommand.arguments(for: session.key) else {
            presentAgentHistoryMessage("This session id cannot be resumed safely.")
            return
        }
        guard let folder = existingAgentProjectFolder(session) else { return }
        let line = AgentHistoryResumeCommand.shellLine(arguments)
        if containsAgentFolder(folder) {
            startAgentResumeTerminal(in: folder, line: line)
            return
        }
        for snapshot in WorkspaceWindowRegistry.shared.sessionSnapshots()
        where snapshot.session !== self && snapshot.session.containsAgentFolder(folder) {
            snapshot.session.startAgentResumeTerminal(in: folder, line: line)
            WorkspaceWindowRegistry.shared.focus(session: snapshot.session)
            return
        }
        let name = AgentHistoryPath.displayName(of: folder.path)
        presentAgentHistoryMessage(
            "“\(name)” is not open in a Rafu window. Choose Open Project Folder, then choose Resume in Terminal in that window."
        )
    }

    // MARK: Helpers

    func containsAgentFolder(_ folder: URL) -> Bool {
        let candidate = folder.resolvingSymlinksInPath().standardizedFileURL.path
        return agentHistoryWorkspaceRoots.contains {
            AgentHistoryPath.isPath(candidate, inside: $0)
        }
    }

    private func startAgentResumeTerminal(in folder: URL, line: String) {
        guard let groupID = newTerminalGroup(startingIn: folder) else { return }
        Task(name: "Type the agent resume command") { [weak self] in
            guard let self else { return }
            let typed = await self.typeAgentResumeLine(line, into: groupID)
            if !typed {
                self.presentAgentHistoryMessage(
                    "The terminal did not start in time. Type the command yourself: \(line)")
            }
        }
    }

    /// Waits (at most ten seconds) for the new pane's shell, then types one
    /// line. The pty buffers the line until the shell reads it.
    private func typeAgentResumeLine(_ line: String, into groupID: TerminalGroupID) async -> Bool {
        for attempt in 0..<100 {
            if let pane = terminal.terminalGroup(groupID)?.panes.first,
                let controller = terminal.terminalController(for: pane.id),
                pane.status == .live
            {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                if controller.sendReply(line) { return true }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    /// The session's folder when it still exists; otherwise says so.
    private func existingAgentProjectFolder(_ session: AgentHistorySessionSummary) -> URL? {
        guard let path = session.projectPath, path.hasPrefix("/") else {
            presentAgentHistoryMessage("This session did not record its folder.")
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            let name = AgentHistoryPath.displayName(of: path)
            presentAgentHistoryMessage("The folder “\(name)” no longer exists on this Mac.")
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func presentAgentHistoryMessage(_ message: String) {
        openFolderErrorTitle = "Agent History"
        openFolderErrorMessage = message
        isOpenFolderErrorPresented = true
    }
}
