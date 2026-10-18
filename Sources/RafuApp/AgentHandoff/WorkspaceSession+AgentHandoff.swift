import AppKit
import Foundation
import Observation
import RafuCore

extension AgentHistoryProvider {
    /// The History provider that matches an agent CLI, if Rafu can read its
    /// transcripts.
    nonisolated init?(cli: ConductorCLIID?) {
        switch cli {
        case .claudeCode?: self = .claudeCode
        case .codex?: self = .codex
        default: return nil
        }
    }
}

extension AgentHistoryStore {
    /// Starts a scan when History was never loaded, then returns once no
    /// scan is running. It waits on the store's own observation, not on a
    /// timer.
    func ensureIndexLoaded() async {
        if lastScanDate == nil, phase != .scanning { refresh() }
        while phase == .scanning {
            await withCheckedContinuation { continuation in
                withObservationTracking {
                    _ = self.phase
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }
}

/// Agent handoff entry points and the start of the target agent. Every
/// start waits for an explicit click on "Write & Start".
extension WorkspaceSession {
    // MARK: Present

    /// Opens the review sheet for `summary`.
    func presentAgentHandoff(_ summary: AgentHistorySessionSummary, target: AgentHistoryProvider) {
        guard rootURL != nil else {
            presentAgentHandoffMessage("Open a project folder first. Handoffs are written there.")
            return
        }
        agentHistory.handoffRequest = AgentHandoffRequest(
            summary: summary, target: target, origin: .history)
    }

    /// The palette entry: the Agent Session tab that is on screen.
    func presentVisibleAgentSessionHandoff(target: AgentHistoryProvider) {
        guard let key = agentHistory.visibleSession?.key,
            let model = agentHistory.transcripts[key]
        else {
            presentAgentHandoffMessage("Open an Agent Session tab first.")
            return
        }
        presentAgentHandoff(model.summary, target: target)
    }

    /// The agent and the folders of a running terminal card on a board, or
    /// `nil` when the card is not a Claude Code or Codex terminal.
    func agentHandoffNode(for card: CanvasCard) -> (
        provider: AgentHistoryProvider, folders: [String]
    )? {
        guard case .terminal(let groupID) = card.content,
            let pane = terminal.terminalGroup(groupID)?.panes.first, let rootURL
        else { return nil }
        let cli: ConductorCLIID?
        if case .directAgentTerminal(let provider) = pane.runtimeKind {
            cli = provider
        } else if pane.status == .live,
            let controller = terminal.terminalController(for: pane.id)
        {
            cli = controller.resolvedAgentProvider
        } else {
            cli = nil
        }
        guard let provider = AgentHistoryProvider(cli: cli) else { return nil }
        let relative = pane.launchProfile?.startingFolder.rawValue ?? "."
        let folder = rootURL.appending(path: relative).standardizedFileURL
        var folders = [folder.path]
        let resolved = folder.resolvingSymlinksInPath().path
        if resolved != folder.path { folders.append(resolved) }
        return (provider, folders)
    }

    /// The newest History session that ran in the card's folder with the
    /// card's agent, from the sessions loaded so far.
    func agentHandoffSession(for card: CanvasCard) -> AgentHistorySessionSummary? {
        guard let node = agentHandoffNode(for: card) else { return nil }
        return AgentHistoryStore.shared.index.newestSession(
            provider: node.provider, inFolders: node.folders)
    }

    /// The Ensemble card entry. Loads History first when it never loaded.
    func presentAgentHandoff(
        fromCard cardID: CanvasCardID, board: CanvasBoardState, target: AgentHistoryProvider
    ) {
        guard rootURL != nil else {
            presentAgentHandoffMessage("Open a project folder first. Handoffs are written there.")
            return
        }
        Task(name: "Find the session for a handoff") { [weak self, weak board] in
            await AgentHistoryStore.shared.ensureIndexLoaded()
            guard let self, let board else { return }
            guard let card = board.cards.first(where: { $0.id == cardID }),
                let summary = self.agentHandoffSession(for: card)
            else {
                self.presentAgentHandoffMessage(
                    "Agent History has no session that matches this terminal’s folder and agent.")
                return
            }
            self.agentHistory.handoffRequest = AgentHandoffRequest(
                summary: summary, target: target,
                origin: .ensembleCard(boardID: board.id, cardID: cardID))
        }
    }

    // MARK: Start

    /// Starts the target agent on a written handoff: in a new terminal, or
    /// in a new terminal card on the board it was requested from.
    func startAgentHandoff(_ launch: AgentHandoffLaunchRequest) {
        guard let root = rootURL else { return }
        let directory = agentHandoffDirectory(for: launch.sessionFolder, root: root)
        let sameAsRoot =
            directory.resolvingSymlinksInPath().standardizedFileURL.path
            == root.resolvingSymlinksInPath().standardizedFileURL.path
        let handoffPath =
            sameAsRoot
            ? "\(AgentHandoffWriter.relativeFolder)/\(launch.result.folderName)/"
                + AgentHandoffWriter.markdownName
            : launch.result.markdownURL.path
        guard
            let arguments = AgentHandoffLaunch.arguments(
                target: launch.target, source: launch.source, title: launch.title,
                handoffPath: handoffPath, imagePaths: launch.result.imageURLs.map(\.path))
        else {
            presentAgentHandoffMessage(
                "The handoff was written, but its start command is too long. Start the agent yourself and ask it to read HANDOFF.md."
            )
            return
        }
        switch launch.origin {
        case .history:
            Task(name: "Start the handoff agent") { [weak self] in
                await self?.startAgentHandoffTerminal(
                    arguments, target: launch.target, directory: directory, root: root)
            }
        case .ensembleCard(let boardID, let cardID):
            startAgentHandoffOnBoard(
                arguments, target: launch.target, directory: directory, root: root,
                boardID: boardID, sourceCardID: cardID)
        }
    }

    /// The session's folder when it still exists inside this window's
    /// project; otherwise the project folder.
    private func agentHandoffDirectory(for sessionFolder: String?, root: URL) -> URL {
        guard let sessionFolder, sessionFolder.hasPrefix("/") else { return root }
        let candidate = URL(fileURLWithPath: sessionFolder, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return root }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return AgentHistoryPath.isPath(resolved, inside: rootPath) ? candidate : root
    }

    private func startAgentHandoffTerminal(
        _ arguments: [String], target: AgentHistoryProvider, directory: URL, root: URL
    ) async {
        let cli = target.cli
        let service = AgentTerminalLaunchService(
            workspaceRoot: root, adapters: ConductorAdapterRegistry.all.filter { $0.id == cli })
        let options = await service.options()
        guard let option = options.first(where: { $0.id == cli }) else {
            presentAgentHandoffMessage("\(target.displayName) is not available on this Mac.")
            return
        }
        guard option.isReady else {
            presentAgentHandoffMessage(
                "The handoff was written, but \(target.displayName) did not start. "
                    + (option.availability.reason ?? "It is not ready."))
            return
        }
        do {
            let base = try service.specification(
                option: option, model: nil, startingDirectory: directory)
            // Same executable, folder, and environment as an Agent Terminal;
            // only the arguments differ.
            openAgentTerminal(
                spec: TerminalProcessSpec(
                    executableURL: base.executableURL, arguments: Array(arguments.dropFirst()),
                    currentDirectoryPath: base.currentDirectoryPath,
                    environment: base.environment, roleBadge: base.roleBadge,
                    resourceAttribution: base.resourceAttribution,
                    agentProvider: base.agentProvider))
        } catch {
            presentAgentHandoffMessage(
                "The handoff was written, but \(target.displayName) did not start.")
        }
    }

    // MARK: Ensemble

    /// A new terminal card next to the source card, joined to it by a link
    /// labelled "handoff". One undo step removes both. The agent starts
    /// through the card's own Start path.
    private func startAgentHandoffOnBoard(
        _ arguments: [String], target: AgentHistoryProvider, directory: URL, root: URL,
        boardID: CanvasID, sourceCardID: CanvasCardID
    ) {
        guard let board = canvas.boards[boardID],
            let source = board.cards.first(where: { $0.id == sourceCardID }),
            board.cards.count < CanvasLimits.cards,
            board.connections.count < CanvasLimits.connections,
            let line = AgentHandoffLaunch.shellLine(arguments)
        else {
            presentAgentHandoffMessage(
                "The handoff was written, but the Ensemble could not take a new terminal.")
            return
        }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let directoryPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let relative =
            directoryPath == rootPath ? "." : String(directoryPath.dropFirst(rootPath.count + 1))
        let folder = TerminalWorkspaceRelativePath(relative) ?? .root
        let title = "\(target.displayName) handoff"
        guard let name = TerminalGroupName(title) else { return }
        do {
            let paneID = SavedTerminalPaneID()
            let pane = try SavedTerminalPaneRecord(
                id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: .init(shell: .preferredShell, startingFolder: folder))
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: name, root: .pane(paneID),
                focusedPaneID: paneID, panes: [pane])
            let snapshot = try terminal.insertStoppedSavedGroup(record)
            _ = try terminal.perform(.detachDeletedSavedLayout(record.id))
            _ = try terminal.perform(.parkGroup(snapshot.id))
            let card = CanvasCard(
                title: title, rect: agentHandoffPlacement(next: source, board: board),
                content: .terminal(groupID: snapshot.id))
            try board.edit { value in
                value.cards.append(card)
                value.connections.append(
                    CanvasConnection(
                        from: source.id, to: card.id, label: "handoff", behavior: .related))
            }
            board.select([card.id])
            board.terminalStartRequest = card.id
            let groupID = snapshot.id
            Task(name: "Type the handoff command into an Ensemble terminal") { [weak self] in
                guard let self else { return }
                let typed = await self.typeAgentHandoffLine(line, into: groupID)
                if !typed {
                    self.presentAgentHandoffMessage(
                        "The terminal did not start in time. Type this command yourself: \(line)")
                }
            }
        } catch {
            presentAgentHandoffMessage(
                "The handoff was written, but the Ensemble could not take a new terminal.")
        }
    }

    /// To the right of `next`, moved down while another card is in the way.
    private func agentHandoffPlacement(next source: CanvasCard, board: CanvasBoardState)
        -> CanvasRect
    {
        var rect = CanvasRect(
            x: source.rect.x + source.rect.width + 48, y: source.rect.y, width: 640, height: 420)
        for _ in 0..<12 {
            let blocked = board.cards.contains { other in
                rect.x < other.rect.x + other.rect.width && other.rect.x < rect.x + rect.width
                    && rect.y < other.rect.y + other.rect.height
                    && other.rect.y < rect.y + rect.height
            }
            guard blocked else { break }
            rect.y += 48 + min(rect.height, 400)
        }
        rect.x = min(50_000 - rect.width, max(-50_000, rect.x.rounded()))
        rect.y = min(50_000 - rect.height, max(-50_000, rect.y.rounded()))
        return rect
    }

    /// A bounded wait (at most ten seconds) for the card's shell, then one
    /// line. The pty buffers the line until the shell reads it.
    private func typeAgentHandoffLine(_ line: String, into groupID: TerminalGroupID) async -> Bool {
        for attempt in 0..<100 {
            if let pane = terminal.terminalGroup(groupID)?.panes.first,
                let controller = terminal.terminalController(for: pane.id),
                pane.status == .live,
                CanvasLiveBridge.shared.hasBootstrap(controllerID: controller.id) || attempt >= 40
            {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                if controller.sendReply(line) { return true }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    // MARK: Messages

    func presentAgentHandoffMessage(_ message: String) {
        openFolderErrorTitle = "Agent Handoff"
        openFolderErrorMessage = message
        isOpenFolderErrorPresented = true
    }
}
