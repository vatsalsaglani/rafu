import Foundation

/// What the answer-mode helper (`rafu-agent-events claude <spool> --answer`)
/// keeps of one Claude Code `PermissionRequest` while it waits: the class of
/// the request, the raw `tool_input`, and the one raw permission suggestion.
/// The helper needs the raw input because an AskUserQuestion answer is the
/// whole input with `answers` added (`updatedInput`). In memory only: never
/// written to the spool, never logged.
///
/// `output(for:)` is the last check before the helper prints. It prints only
/// what fits the class of the request:
///
/// - an allow with answers only for a question set, and only when every
///   answer matches the kept questions (`AgentPermissionAnswer.hookOutput`);
/// - never a plain allow for a question set (Claude Code needs
///   `updatedInput` for AskUserQuestion; an allow alone is not valid);
/// - an allow for a command, a file change or a tool call;
/// - "remember" only for a command or a tool call, and only while
///   `CanvasAgentRequest.PersistPolicy` allows lasting grants;
/// - a deny for any class the helper waits on.
///
/// Anything else prints nothing, so the terminal dialog stays.
public nonisolated struct ClaudeAnswerModeRequest {
    public let classification: AgentPermissionRequestSummary.Classification
    /// The helper waits for an answer (`AgentPermissionRequestSummary.waitsForAnswer`).
    public let waitsForAnswer: Bool
    let toolInput: [String: Any]?
    let suggestion: Any?

    /// The request of `event`, with the raw values read again from
    /// `payload`. Nil when the event carries no request summary.
    public init?(event: AgentHookEvent, payload: Data) {
        guard let summary = event.requestSummary else { return nil }
        let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        let suggestions = object?["permission_suggestions"] as? [Any]
        self.init(
            classification: summary.classification, waitsForAnswer: summary.waitsForAnswer,
            toolInput: object?["tool_input"] as? [String: Any],
            suggestion: suggestions?.count == 1 ? suggestions?.first : nil)
    }

    init(
        classification: AgentPermissionRequestSummary.Classification, waitsForAnswer: Bool,
        toolInput: [String: Any]?, suggestion: Any?
    ) {
        self.classification = classification
        self.waitsForAnswer = waitsForAnswer
        self.toolInput = toolInput
        self.suggestion = suggestion
    }

    /// What the helper prints for `outcome`, or nil to print nothing.
    public func output(
        for outcome: AgentAnswerOutcome,
        policy: CanvasAgentRequest.PersistPolicy = .current
    ) -> Data? {
        guard waitsForAnswer, case .answered(let answer) = outcome else { return nil }
        switch answer.verdict {
        case .allow:
            let isQuestionSet = classification == .questions
            // Answers belong to a question set only, and a question set
            // takes no allow without them.
            guard isQuestionSet == (answer.answers != nil) else { return nil }
            let remembers = classification == .command || classification == .toolCall
            guard !answer.remember || remembers else { return nil }
            return answer.hookOutput(
                originalInput: isQuestionSet ? toolInput : nil,
                suggestion: remembers ? suggestion : nil, policy: policy)
        case .deny:
            return answer.hookOutput
        case .dismiss:
            return nil
        }
    }
}
