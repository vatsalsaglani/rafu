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
        var paths: [String] = []
        for root in roots {
            let url = URL(fileURLWithPath: root.path)
            for path in [
                url.standardizedFileURL.path,
                url.resolvingSymlinksInPath().standardizedFileURL.path,
            ] where !paths.contains(path) {
                paths.append(path)
            }
        }
        return paths
    }

    /// Shows the History navigator. `focusSearch` also moves keyboard focus
    /// to its search field ("Search Agent History…").
    func showAgentHistory(focusSearch: Bool = false) {
        showNavigator(.history)
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

    /// Opens an Agent Terminal in the session's folder that runs the resume
    /// command (`claude --resume <id>` / `codex resume <id>`) as its own
    /// process (`launchAgentResumeTerminal`). The folder must be open in a
    /// Rafu window: this one, or another one, which then comes to the front.
    func resumeAgentSession(_ session: AgentHistorySessionSummary) {
        guard AgentHistoryResumeCommand.arguments(for: session.key) != nil else {
            presentAgentHistoryMessage("This session id cannot be resumed safely.")
            return
        }
        guard let folder = existingAgentProjectFolder(session) else { return }
        if containsAgentFolder(folder) {
            launchAgentResumeTerminal(session.key, in: folder)
            return
        }
        for snapshot in WorkspaceWindowRegistry.shared.sessionSnapshots()
        where snapshot.session !== self && snapshot.session.containsAgentFolder(folder) {
            snapshot.session.launchAgentResumeTerminal(session.key, in: folder)
            WorkspaceWindowRegistry.shared.focus(session: snapshot.session)
            return
        }
        let name = AgentHistoryPath.displayName(of: folder.path)
        presentAgentHistoryMessage(
            "“\(name)” is not open in a Rafu window. Choose Open Project Folder, then choose Resume in Terminal in that window."
        )
    }

    // MARK: Helpers

    /// Terminal Groups start only inside the primary folder, so Resume
    /// matches the primary folder; "This Workspace" lists every folder.
    func containsAgentFolder(_ folder: URL) -> Bool {
        guard let rootURL else { return false }
        let candidate = folder.resolvingSymlinksInPath().standardizedFileURL.path
        let primary = Set([
            rootURL.standardizedFileURL.path,
            rootURL.resolvingSymlinksInPath().standardizedFileURL.path,
        ])
        return primary.contains { AgentHistoryPath.isPath(candidate, inside: $0) }
    }

    /// The session's folder when it still exists; otherwise says so.
    func existingAgentProjectFolder(_ session: AgentHistorySessionSummary) -> URL? {
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

    func presentAgentHistoryMessage(_ message: String) {
        openFolderErrorTitle = "Agent History"
        openFolderErrorMessage = message
        isOpenFolderErrorPresented = true
    }
}
