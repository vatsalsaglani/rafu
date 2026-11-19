import Foundation

extension WorkspaceSession {
    func showEnsembles() { showNavigator(.ensemble) }

    /// The live pane behind a terminal card: the agent CLI it runs (the same
    /// rule as the card header) and the name its header shows.
    func canvasSearchTerminalInfo(for card: CanvasCard) -> CanvasSearchTerminalInfo? {
        guard case .terminal(let groupID) = card.content,
            let pane = terminal.terminalGroup(groupID)?.panes.first
        else { return nil }
        var provider: ConductorCLIID?
        if case .directAgentTerminal(let direct) = pane.runtimeKind {
            provider = direct
        } else if pane.status == .live {
            provider = terminal.terminalController(for: pane.id)?.resolvedAgentProvider
        }
        let shown =
            TerminalNaming.isAutomaticGroupName(card.title)
            ? pane.explicitUserName?.rawValue : nil
        return CanvasSearchTerminalInfo(providerName: provider?.displayName, shownTitle: shown)
    }

    /// Boards open in another live window of this workspace. Only membership
    /// matters, so the navigator's task key does not sort the window entries.
    func canvasIDsOpenInOtherWindows() -> Set<CanvasID> {
        guard let root = rootURL?.standardizedFileURL else { return [] }
        var ids = Set<CanvasID>()
        for entry in WorkspaceWindowRegistry.shared.entries.values {
            guard entry.window != nil, let session = entry.session, session !== self,
                entry.rootURL()?.standardizedFileURL == root
            else { continue }
            ids.formUnion(session.canvas.boards.keys)
        }
        return ids
    }
}
