import Foundation
import RafuCore

extension AgentHookProvider {
    /// The agent CLI identity Rafu's icons and terminals use.
    nonisolated var cli: ConductorCLIID {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        case .cursor: .cursor
        }
    }

    /// The hook provider for a terminal's agent CLI; `nil` for CLIs without
    /// hook support.
    nonisolated init?(cli: ConductorCLIID) {
        switch cli {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        case .cursor: self = .cursor
        case .openCode, .cline, .kimi, .geminiCLI: return nil
        }
    }
}

/// How hook state reads on each surface. Pure: the store supplies the
/// matched session and the clock.
nonisolated enum AgentTrackedPhase {
    /// The notch phase for a Rafu terminal with a matched session, or `nil`
    /// to keep the output-based phase. Hook state wins for work and
    /// attention; the terminal's own bell still owns "reply ready", because
    /// opening the terminal is what clears it.
    static func terminalPhase(
        session: TrackedAgentSession?, status: TerminalSessionStatus, now: Date
    ) -> NotchAgentPhase? {
        guard let session else { return nil }
        switch status {
        case .idle, .exited: return nil
        case .running, .bell: break
        }
        func finishedPhase() -> NotchAgentPhase? {
            if status == .bell { return session.replyEventID == nil ? nil : .replyReady }
            return .idle
        }
        switch session.state {
        case .working:
            return session.isStale(at: now) ? nil : .working
        case .waitingForPermission, .needsInput:
            // A Claude wait nothing answered for five minutes reads as idle.
            return session.isAttentionStale(at: now) ? finishedPhase() : .needsYou
        case .finished:
            return finishedPhase()
        case .ended:
            return nil
        }
    }

    /// A session's active sub-agents as notch entries, in start order.
    static func subagentEntries(_ session: TrackedAgentSession?) -> [NotchSubagentEntry] {
        (session?.subagents ?? []).map {
            NotchSubagentEntry(
                id: $0.id, type: $0.type, model: $0.model, taskDescription: $0.taskDescription)
        }
    }

    /// The folder line of an outside agent's card: the working folder with
    /// the home folder shortened to `~`; `nil` when the hook sent none.
    static func cardDetail(cwd: String) -> String? {
        cwd.isEmpty ? nil : (cwd as NSString).abbreviatingWithTildeInPath
    }

    /// The last 8 characters of a session id, as Cider shows to tell two
    /// cards with the same title apart; `nil` for an empty id.
    static func sessionSuffix(_ sessionID: String) -> String? {
        sessionID.isEmpty ? nil : String(sessionID.suffix(8))
    }

    /// The notch phase for a session outside Rafu. A reply stays "ready"
    /// for `TrackedAgentSession.replyFreshInterval`, as nothing in Rafu can
    /// clear it.
    static func externalPhase(session: TrackedAgentSession, now: Date) -> NotchAgentPhase {
        switch session.state {
        case .working: session.isStale(at: now) ? .idle : .working
        case .waitingForPermission, .needsInput:
            session.isAttentionStale(at: now) ? .idle : .needsYou
        case .finished: session.hasFreshReply(at: now) ? .replyReady : .idle
        case .ended: .stopped
        }
    }

    /// The Ensemble terminal node header word, or `nil` to keep "Running".
    /// Sources the words `AgentCardStatus` also shows, so the notch and
    /// the canvas card header can never read differently for the same
    /// state.
    static func stateWord(phase: NotchAgentPhase?, session: TrackedAgentSession?) -> String? {
        guard let phase, let session else { return nil }
        switch phase {
        case .working: return AgentCardStatus.working.word
        case .needsYou:
            return session.state == .waitingForPermission
                ? AgentCardStatus.needsYou(.approval).word : AgentCardStatus.needsYou(.input).word
        case .replyReady: return "Reply ready"
        case .idle: return "Waiting"
        case .stopped: return nil
        }
    }
}

extension AgentActivityStore {
    /// The hook-based notch phase for `controller`, or `nil` to keep the
    /// output-based one.
    func notchPhase(for controller: WorkspaceTerminalController) -> NotchAgentPhase? {
        AgentTrackedPhase.terminalPhase(
            session: trackedSession(for: controller), status: controller.status, now: now)
    }

    /// Whether the agent in `controller` waits for approval or an answer. A
    /// Claude wait nothing answered for five minutes no longer counts.
    func needsAttention(_ controller: WorkspaceTerminalController) -> Bool {
        guard let session = trackedSession(for: controller) else { return false }
        return session.needsAttention && !session.isAttentionStale(at: now)
    }

    /// The Ensemble terminal node header word for `controller`, or `nil`.
    func stateWord(for controller: WorkspaceTerminalController?) -> String? {
        guard let controller, let session = trackedSession(for: controller) else { return nil }
        return AgentTrackedPhase.stateWord(
            phase: AgentTrackedPhase.terminalPhase(
                session: session, status: controller.status, now: now),
            session: session)
    }

    /// Notch rows for sessions outside every terminal in `controllers`. A
    /// row has no window, so the notch shows it without a "show" action.
    func externalNotchRows(excluding controllers: [WorkspaceTerminalController])
        -> [NotchAgentRow]
    {
        externalSessions(excluding: controllers).map { session in
            let phase = AgentTrackedPhase.externalPhase(session: session, now: now)
            return NotchAgentRow(
                id: phase == .replyReady ? (session.replyEventID ?? session.rowID) : session.rowID,
                title: session.projectName,
                cli: session.provider.cli,
                phase: phase,
                subagents: AgentTrackedPhase.subagentEntries(session),
                detail: AgentTrackedPhase.cardDetail(cwd: session.cwd),
                updatedAt: session.updatedAt,
                lastMessage: session.lastMessagePreview,
                sessionSuffix: AgentTrackedPhase.sessionSuffix(session.sessionID))
        }
    }
}
