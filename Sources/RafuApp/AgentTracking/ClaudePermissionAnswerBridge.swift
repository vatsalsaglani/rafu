import Foundation
import RafuCore

/// The app side of answering a Claude Code `PermissionRequest` from Up next.
///
/// The hook helper's answer mode (`rafu-agent-events claude <spool> --answer`)
/// writes the event with a bounded request summary and waits. This type:
///
/// 1. maps that event to a `CanvasAgentRequest` for `AgentRequestStore`. The
///    request key is the hook event id, so the store's answer for a key is the
///    answer for exactly one waiting helper;
/// 2. maps the user's `CanvasAgentRequestDecision` to an
///    `AgentPermissionAnswer` and writes it to the private answer channel;
/// 3. writes `dismiss` when Rafu will not answer (the session belongs to no
///    Rafu terminal, or the request was answered in the terminal), so the
///    helper exits at once and Claude keeps its own dialog.
///
/// Free of SwiftUI and of any store. Request and answer text never reaches a
/// log.
nonisolated struct ClaudePermissionAnswerBridge: Equatable, Sendable {
    let channel: AgentAnswerChannel

    enum SubmitResult: Equatable, Sendable {
        case written
        /// An answer for this event is on its way already (first one wins).
        case alreadyAnswered
        /// The decision does not map to an answer Claude Code understands.
        case unsupported
        case failed
    }

    /// The reason line of a file change, followed by the path.
    static let fileChangeReasonPrefix = "Change file: "

    // MARK: Event to request

    /// True for the event the helper's answer mode writes: a Claude Code
    /// `PermissionRequest` that carries a request summary.
    static func isAnswerable(_ event: AgentHookEvent) -> Bool {
        event.provider == .claude && event.hookEventName == "PermissionRequest"
            && event.requestSummary != nil
    }

    /// The request for `event`, or nil when the event is not answerable. A
    /// command that was cut or changed becomes terminal-only. A file change is
    /// always terminal-only: the row shows the path, not the change.
    static func request(for event: AgentHookEvent) -> CanvasAgentRequest? {
        guard isAnswerable(event), let summary = event.requestSummary else { return nil }
        let cwd = event.cwd.isEmpty ? nil : event.cwd
        if let command = summary.command {
            return CanvasAgentRequest(
                key: event.id, kind: .command, command: command, cwd: cwd,
                reason: summary.description, terminalOnly: !summary.isComplete,
                offersSessionAllow: false, receivedAt: event.time)
        }
        if let path = summary.filePath {
            return CanvasAgentRequest(
                key: event.id, kind: .fileChange, cwd: cwd,
                reason: fileChangeReasonPrefix + path, terminalOnly: true,
                offersSessionAllow: false, receivedAt: event.time)
        }
        return nil
    }

    // MARK: Decision to answer

    /// The answer for `decision`. Accept allows, decline denies, and cancel
    /// denies and stops the turn. "Allow for this session" and question
    /// answers have no hook equivalent here, so they give nil.
    static func answer(
        for decision: CanvasAgentRequestDecision, eventID: UUID
    ) -> AgentPermissionAnswer? {
        switch decision {
        case .accept: AgentPermissionAnswer(eventID: eventID, verdict: .allow)
        case .decline: AgentPermissionAnswer(eventID: eventID, verdict: .deny)
        case .cancel: AgentPermissionAnswer(eventID: eventID, verdict: .deny, interrupt: true)
        case .acceptForSession, .answers: nil
        }
    }

    // MARK: Channel

    /// Writes the user's answer for the waiting helper of `answer.key`.
    func submit(_ answer: CanvasAgentRequestAnswer) -> SubmitResult {
        guard let mapped = Self.answer(for: answer.decision, eventID: answer.key) else {
            return .unsupported
        }
        return write(mapped)
    }

    /// Tells the helper of `eventID` that Rafu will not answer.
    @discardableResult
    func dismiss(eventID: UUID) -> SubmitResult {
        write(AgentPermissionAnswer(eventID: eventID, verdict: .dismiss))
    }

    private func write(_ answer: AgentPermissionAnswer) -> SubmitResult {
        do {
            try channel.write(answer)
            return .written
        } catch AgentAnswerChannelError.alreadyAnswered {
            return .alreadyAnswered
        } catch {
            return .failed
        }
    }
}
