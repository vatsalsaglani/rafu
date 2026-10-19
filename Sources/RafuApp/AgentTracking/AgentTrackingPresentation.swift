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
        switch session.state {
        case .working:
            return session.isStale(at: now) ? nil : .working
        case .waitingForPermission, .needsInput:
            return .needsYou
        case .finished:
            if status == .bell { return session.replyEventID == nil ? nil : .replyReady }
            return .idle
        case .ended:
            return nil
        }
    }

    /// The notch phase for a session outside Rafu. A reply stays "ready"
    /// for `TrackedAgentSession.replyFreshInterval`, as nothing in Rafu can
    /// clear it.
    static func externalPhase(session: TrackedAgentSession, now: Date) -> NotchAgentPhase {
        switch session.state {
        case .working: session.isStale(at: now) ? .idle : .working
        case .waitingForPermission, .needsInput: .needsYou
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

    /// Whether the agent in `controller` waits for approval or an answer.
    func needsAttention(_ controller: WorkspaceTerminalController) -> Bool {
        trackedSession(for: controller)?.needsAttention ?? false
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
                phase: phase)
        }
    }
}
