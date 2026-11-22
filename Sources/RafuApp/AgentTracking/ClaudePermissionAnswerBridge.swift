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
///    helper exits at once and Claude keeps its own dialog. Only for a
///    request whose helper waits (`helperWaits(_:)`);
/// 4. maps a Claude Code `Notification` that asks for the person to a
///    read-only `.notice` request (`notice(for:)`).
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
    /// `PermissionRequest` that carries a request summary, of any class.
    static func isAnswerable(_ event: AgentHookEvent) -> Bool {
        event.provider == .claude && event.hookEventName == "PermissionRequest"
            && event.requestSummary != nil
    }

    /// True when the helper of `event` waits for an answer, so Rafu must
    /// write one (or `dismiss`). A plan or an unclassified request is only
    /// shown: its helper exited already.
    static func helperWaits(_ event: AgentHookEvent) -> Bool {
        isAnswerable(event) && event.requestSummary?.waitsForAnswer == true
    }

    /// The request for `event`, or nil when the event is not answerable.
    /// Every class gives a request:
    ///
    /// - a command, a file change, or a tool call (MCP or built-in) that was
    ///   cut or changed is terminal-only: the row shows the whole request or
    ///   none of it;
    /// - a question set is a `.userInput` request; ids are the indexes in
    ///   `tool_input.questions`;
    /// - a plan is a `.plan` request (path and plan text), always
    ///   terminal-only;
    /// - an unclassified request is a `.notice` that names the tool.
    ///
    /// The one permission suggestion Rafu understands becomes the remember
    /// choice `rule`. `PersistPolicy.current` keeps it hidden.
    static func request(for event: AgentHookEvent) -> CanvasAgentRequest? {
        guard isAnswerable(event), let summary = event.requestSummary else { return nil }
        let cwd = event.cwd.isEmpty ? nil : event.cwd
        let remember =
            summary.permissionSuggestion.map {
                [CanvasAgentRequest.PersistChoice(kind: .rule, line: $0.line)]
            } ?? []
        switch summary.classification {
        case .command:
            guard let command = summary.command else { return nil }
            return CanvasAgentRequest(
                key: event.id, kind: .command, command: command, cwd: cwd,
                reason: summary.description, persistChoices: remember,
                terminalOnly: !summary.isComplete, offersSessionAllow: false,
                receivedAt: event.time)
        case .toolCall:
            guard let call = summary.toolCall else { return nil }
            // The arguments ride in `command` (bounded, exact or terminal-only)
            // and the tool identity in `reason`. No session answer.
            return CanvasAgentRequest(
                key: event.id, kind: .toolCall, command: call.arguments, cwd: cwd,
                reason: call.reasonLine, persistChoices: remember,
                terminalOnly: !summary.isComplete, offersSessionAllow: false,
                receivedAt: event.time)
        case .fileChange:
            guard let path = summary.filePath else { return nil }
            return CanvasAgentRequest(
                key: event.id, kind: .fileChange, cwd: cwd,
                reason: fileChangeReasonPrefix + path, fileChanges: summary.fileChanges,
                terminalOnly: !summary.isComplete, offersSessionAllow: false,
                receivedAt: event.time)
        case .questions:
            return CanvasAgentRequest(
                key: event.id, kind: .userInput, cwd: cwd, questions: summary.questions,
                terminalOnly: !summary.isComplete, offersSessionAllow: false,
                receivedAt: event.time)
        case .plan:
            guard let plan = summary.plan else { return nil }
            return CanvasAgentRequest(
                key: event.id, kind: .plan, cwd: cwd, reason: plan.path, text: plan.text,
                textIsCut: !summary.isComplete, offersSessionAllow: false,
                receivedAt: event.time)
        case .unclassified:
            return CanvasAgentRequest(
                key: event.id, kind: .notice, cwd: cwd, reason: summary.noticeReason,
                offersSessionAllow: false, receivedAt: event.time)
        }
    }

    // MARK: Notifications

    /// The word that names each Claude Code notification that asks for the
    /// person and that no hook can answer: a sandboxed command's network
    /// request, or an MCP server form or browser link (Claude Code hooks
    /// reference, "Notification"). The same types as
    /// `AgentSessionLedger.attentionNotificationTypes`; `agent_needs_input`
    /// also fires for background sessions, so it opens no notice.
    static let noticeTitles: [String: String] = [
        "permission_prompt": "Permission request",
        "worker_permission_prompt": "Permission request",
        "elicitation_dialog": "MCP server form",
        "elicitation_url_dialog": "Sign-in in browser",
    ]

    /// A `.notice` request for a Claude Code `Notification` that asks for
    /// the person and carries a message, or nil. Keyed by the event id; no
    /// helper waits for it.
    static func notice(for event: AgentHookEvent) -> CanvasAgentRequest? {
        guard event.provider == .claude, event.hookEventName == "Notification",
            let type = event.notificationType, let title = noticeTitles[type],
            let message = event.notificationMessage, !message.isEmpty
        else { return nil }
        return CanvasAgentRequest(
            key: event.id, kind: .notice, cwd: event.cwd.isEmpty ? nil : event.cwd,
            reason: title, text: message, offersSessionAllow: false, receivedAt: event.time)
    }

    // MARK: Decision to answer

    /// The answer for `decision`. Accept allows, decline denies, and cancel
    /// denies and stops the turn. Question answers carry the index of each
    /// question (its id), the chosen labels and the typed text; the helper
    /// checks them against its own copy of the questions. "Allow for this
    /// session" has no hook equivalent, and "remember" is sent only while
    /// `policy` allows lasting grants (off today), so both give nil.
    static func answer(
        for decision: CanvasAgentRequestDecision, eventID: UUID,
        policy: CanvasAgentRequest.PersistPolicy = .current
    ) -> AgentPermissionAnswer? {
        switch decision {
        case .accept: return AgentPermissionAnswer(eventID: eventID, verdict: .allow)
        case .decline: return AgentPermissionAnswer(eventID: eventID, verdict: .deny)
        case .cancel:
            return AgentPermissionAnswer(eventID: eventID, verdict: .deny, interrupt: true)
        case .acceptAndRemember(let kind):
            // The hook can only echo a permission suggestion as a rule.
            guard kind == .rule, policy.allows(kind) else { return nil }
            return AgentPermissionAnswer(eventID: eventID, verdict: .allow, remember: true)
        case .answers(let answers):
            var mapped: [AgentPermissionAnswer.QuestionAnswer] = []
            for (id, answer) in answers {
                guard let index = Int(id), String(index) == id, index >= 0 else { return nil }
                mapped.append(.init(index: index, labels: answer.labels, text: answer.text))
            }
            guard !mapped.isEmpty else { return nil }
            return AgentPermissionAnswer(
                eventID: eventID, verdict: .allow, answers: mapped.sorted { $0.index < $1.index })
        case .acceptForSession: return nil
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
