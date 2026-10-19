import Foundation
import RafuCore

/// Resume in Terminal and Resume in Ensemble (round 4). Both start only from
/// an explicit user action. Agent control does not apply: the person, not an
/// agent, asks for the node.
extension WorkspaceSession {
    /// The session of the Agent Session tab on screen, for the palette.
    var visibleAgentSessionSummary: AgentHistorySessionSummary? {
        guard let reference = agentHistory.visibleSession else { return nil }
        return agentHistory.transcripts[reference.key]?.summary
    }

    // MARK: Resume in Terminal

    /// Starts the provider's CLI as the terminal process in `folder`, with
    /// the resume arguments. Nothing is typed into a shell. When the CLI is
    /// not found, a message gives the exact command to run.
    func launchAgentResumeTerminal(_ key: AgentHistorySessionKey, in folder: URL) {
        let folderName = AgentHistoryPath.displayName(of: folder.path)
        let adapter = ConductorAdapterRegistry.adapter(for: key.provider.cli)
        Task(name: "Resume agent session in a terminal") { [weak self] in
            let probe = await adapter?.probe()
            guard let self else { return }
            guard let probe, probe.installed, let executableURL = probe.executableURL,
                let specification = AgentHistoryResumeLaunch.specification(
                    for: key, executableURL: executableURL, folder: folder)
            else {
                self.presentAgentHistoryMessage(
                    AgentHistoryResumeLaunch.missingCLIMessage(for: key, folderName: folderName))
                return
            }
            self.openAgentTerminal(spec: specification)
        }
    }

    // MARK: Resume in Ensemble

    /// Adds a terminal node that resumes `summary` to `target`, else to this
    /// window's current Ensemble, centred on `center` (board units) when
    /// given. With no Ensemble open, asks to create one first.
    func resumeAgentSessionInEnsemble(
        _ summary: AgentHistorySessionSummary, on target: CanvasBoardState? = nil,
        center: CGPoint? = nil
    ) {
        guard AgentHistoryResumeCommand.arguments(for: summary.key) != nil else {
            presentAgentHistoryMessage("This session id cannot be resumed safely.")
            return
        }
        guard let folder = existingAgentProjectFolder(summary) else { return }
        guard let rootURL, containsAgentFolder(folder),
            let plan = AgentHistoryResumeLaunch.ensemblePlan(
                for: summary.key, sessionTitle: summary.title, folder: folder,
                workspaceRoot: rootURL)
        else {
            let name = AgentHistoryPath.displayName(of: folder.path)
            presentAgentHistoryMessage(
                "“\(name)” is not inside this window’s folder. An Ensemble terminal starts only inside the workspace folder. Choose Resume in Terminal instead."
            )
            return
        }
        if let board = target ?? agentResumeEnsembleBoard {
            startAgentResumeNode(plan, on: board, center: center)
        } else {
            agentEnsembleResumeAwaitingConfirmation = plan
        }
    }

    /// The Ensemble on screen, else the first Ensemble tab in the focused
    /// editor group, else in any group.
    var agentResumeEnsembleBoard: CanvasBoardState? {
        if let selectedCanvas { return selectedCanvas }
        let groupIDs = [editorLayout.focusedGroupID] + editorLayout.groupIDs
        for groupID in groupIDs {
            for tab in editorLayout.group(id: groupID)?.tabs ?? [] {
                if case .canvas(let id) = tab.resource, let board = canvas.boards[id] {
                    return board
                }
            }
        }
        return nil
    }

    /// "New Ensemble" in the confirmation: creates an Ensemble named after
    /// the session, then adds the resume node to it.
    func createEnsembleForAgentResume(_ plan: AgentHistoryEnsembleResumePlan) {
        agentEnsembleResumeAwaitingConfirmation = nil
        guard let rootURL else { return }
        let title = CanvasDocument.validTitle(plan.title) ? plan.title : "Ensemble"
        Task(name: "Create an Ensemble for an agent resume") { [weak self] in
            guard let self else { return }
            guard await self.canvas.configure(root: rootURL),
                let board = await self.canvas.create(title: title),
                self.rootURL == rootURL
            else {
                self.presentAgentHistoryMessage(
                    self.canvas.libraryNotice ?? "Rafu could not create the Ensemble.")
                return
            }
            self.startAgentResumeNode(plan, on: board)
        }
    }

    /// A history row dropped on a board (shared by the SwiftUI delegate and
    /// the AppKit bridge). The summary comes from the app-wide index, so a row
    /// dragged from another window works. `point` is in the board view's
    /// top-left space; `nil` places the card as a normal add does. The drop is
    /// handled once either way: a refusal puts a message on the board.
    @discardableResult
    func dropAgentSessionOnCanvas(
        _ key: AgentHistorySessionKey, boardID: CanvasID, at point: CGPoint?
    ) -> Bool {
        guard let board = canvas.boards[boardID] else { return false }
        guard let summary = AgentHistoryStore.shared.index.sessions.first(where: { $0.key == key })
        else {
            board.errorMessage = "This session is no longer in Agent History."
            return true
        }
        let center = point.map { CanvasBoardDropGeometry.boardPoint($0, viewport: board.viewport) }
        resumeAgentSessionInEnsemble(summary, on: board, center: center)
        return true
    }

    /// Shows `board`, adds the node, starts its shell, then types the resume
    /// line once the shell process runs.
    func startAgentResumeNode(
        _ plan: AgentHistoryEnsembleResumePlan, on board: CanvasBoardState,
        center: CGPoint? = nil
    ) {
        presentCanvasBoard(board)
        guard let cardID = addAgentResumeNode(plan, to: board, center: center),
            let card = board.cards.first(where: { $0.id == cardID }),
            case .terminal(let groupID) = card.content
        else { return }
        board.revealCard(cardID)
        let line = plan.line
        let boardID = board.id
        let failure =
            "The Ensemble terminal did not start in time. Type the command yourself: \(line)"
        // Waits (at most fifteen seconds) for the node's shell process, then
        // types one line. The session is held only for each short check.
        Task(name: "Type the agent resume command into an Ensemble terminal") { [weak self] in
            for attempt in 1...150 {
                guard
                    let step = self?.agentResumeTypingStep(
                        line, into: groupID, cardID: cardID, boardID: boardID, attempt: attempt)
                else { return }
                switch step {
                case .typed, .gone: return
                case .failed:
                    self?.presentAgentHistoryMessage(failure)
                    return
                case .waiting: break
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            self?.presentAgentHistoryMessage(failure)
        }
    }

    /// Adds a stopped Ensemble terminal node in the plan's folder, selects
    /// and focuses it, and asks its card to start the shell. One undoable
    /// board edit. Returns the new card, or `nil` when the board is full.
    @discardableResult
    func addAgentResumeNode(
        _ plan: AgentHistoryEnsembleResumePlan, to board: CanvasBoardState,
        center: CGPoint? = nil
    ) -> CanvasCardID? {
        guard board.cards.count < CanvasLimits.cards else {
            presentAgentHistoryMessage("This Ensemble is full. Remove a card, then try again.")
            return nil
        }
        guard let name = TerminalGroupName(plan.title) ?? TerminalGroupName("Terminal") else {
            return nil
        }
        var cardID: CanvasCardID?
        performCanvasEdit(board) {
            let paneID = SavedTerminalPaneID()
            let pane = try SavedTerminalPaneRecord(
                id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
                launchProfile: .init(shell: .preferredShell, startingFolder: plan.startingFolder))
            let record = try SavedTerminalGroupRecord(
                id: SavedTerminalGroupID(), name: name,
                root: .pane(paneID), focusedPaneID: paneID, panes: [pane])
            let snapshot = try terminal.insertStoppedSavedGroup(record)
            _ = try terminal.perform(.detachDeletedSavedLayout(record.id))
            _ = try terminal.perform(.parkGroup(snapshot.id))
            try board.add(
                title: snapshot.name.rawValue, content: .terminal(groupID: snapshot.id),
                center: center)
            cardID =
                board.cards.first(where: { $0.content == .terminal(groupID: snapshot.id) })?
                .id
        }
        guard let cardID else { return nil }
        board.focus(cardID)
        board.terminalStartRequest = cardID
        return cardID
    }

    /// One check of the resume node. The line is typed only when the shell
    /// process runs: SwiftTerm drops input sent before the process exists, so
    /// the wait is on the process, not on a timer; the pty keeps the line
    /// until the shell reads it. A start request that the card could not act
    /// on yet (the board was still appearing) is asked again.
    private func agentResumeTypingStep(
        _ line: String, into groupID: TerminalGroupID, cardID: CanvasCardID, boardID: CanvasID,
        attempt: Int
    ) -> AgentResumeTypingStep {
        guard let pane = terminal.terminalGroup(groupID)?.panes.first else { return .gone }
        if pane.status == .live, let controller = terminal.terminalController(for: pane.id),
            controller.isProcessRunning
        {
            return controller.sendReply(line) ? .typed : .failed
        }
        if pane.status == .stopped, attempt.isMultiple(of: 10),
            let board = canvas.boards[boardID], board.terminalStartRequest == nil
        {
            board.terminalStartRequest = cardID
        }
        return .waiting
    }
}

/// The result of one `agentResumeTypingStep`.
private nonisolated enum AgentResumeTypingStep {
    case typed, waiting, failed, gone
}
