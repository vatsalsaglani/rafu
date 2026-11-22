import Foundation
import RafuCore

struct CompanionRequestPresentation {
    let request: CanvasAgentRequest
    let decision: CanvasAgentRequestDecision?

    enum Controls: Equatable {
        /// Only the terminal can answer: "Open terminal". A plan or a notice
        /// also shows its text.
        case terminal
        case options([CanvasAgentRequest.Option])
        /// The question set, answerable.
        case questions([CanvasAgentRequest.Question])
        /// The question set of a request only the terminal can answer:
        /// shown, not answerable, with "Open terminal".
        case readOnlyQuestions([CanvasAgentRequest.Question])
        case sending
    }

    var controls: Controls {
        if request.terminalOnly {
            if request.kind == .userInput, !request.questions.isEmpty {
                return .readOnlyQuestions(request.questions)
            }
            return .terminal
        }
        if decision != nil { return .sending }
        if request.kind == .userInput { return .questions(request.questions) }
        return .options(request.options)
    }

    var title: String { Self.title(for: request) }

    /// The row title. A notice names its kind ("Network request") with the
    /// first line of its reason.
    nonisolated static func title(for request: CanvasAgentRequest) -> String {
        switch request.kind {
        case .command: "Run command"
        case .fileChange: "Apply file changes"
        case .permissions: "Grant permissions"
        case .userInput: request.questions.count == 1 ? "Answer a question" : "Answer questions"
        case .toolCall: "Use MCP tool"
        case .plan: "Plan ready"
        case .notice: noticeKind(request) ?? "Prompt in the terminal"
        }
    }

    /// The first line of a notice's reason, or nil when it has none.
    nonisolated static func noticeKind(_ request: CanvasAgentRequest) -> String? {
        guard request.kind == .notice, let reason = request.reason else { return nil }
        let first = reason.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let trimmed = first.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func message(for result: AgentRequestStore.ChooseResult) -> String? {
        switch result {
        case .chosen, .alreadyChosen: nil
        case .stale: "This request was already answered."
        case .invalid: "This answer is unavailable. Open the terminal to continue."
        }
    }
}

/// The answer buttons of one request, for the approval peek and the full Up
/// next row: one primary answer, Deny, and the rest in a menu. Derived from
/// `request.options` only, so a button never offers an answer the request
/// does not permit.
nonisolated struct CompanionRequestActions: Equatable, Sendable {
    /// The `.accept` option.
    let primary: CanvasAgentRequest.Option?
    /// The `.decline` option.
    let deny: CanvasAgentRequest.Option?
    /// The other options (`.acceptForSession`, the remember choices,
    /// `.cancel`), in request order.
    let overflow: [CanvasAgentRequest.Option]
    /// The request is a command: its primary answer reads "Allow".
    let isCommand: Bool

    /// `policy` decides which remember choices show. They go to the menu,
    /// never to the primary button.
    init(request: CanvasAgentRequest, policy: CanvasAgentRequest.PersistPolicy = .current) {
        let options = request.options(policy: policy)
        primary = options.first { $0.decision == .accept }
        deny = options.first { $0.decision == .decline }
        overflow = options.filter { $0.decision != .accept && $0.decision != .decline }
        isCommand = request.kind == .command
    }

    private init(
        primary: CanvasAgentRequest.Option?, deny: CanvasAgentRequest.Option?,
        overflow: [CanvasAgentRequest.Option], isCommand: Bool
    ) {
        self.primary = primary
        self.deny = deny
        self.overflow = overflow
        self.isCommand = isCommand
    }

    /// The same actions with no accept answer, for a request the card cannot
    /// show whole.
    var withoutAccept: CompanionRequestActions {
        CompanionRequestActions(
            primary: nil, deny: deny,
            overflow: overflow.filter { !Self.isAccept($0.decision) },
            isCommand: isCommand)
    }

    /// An answer that allows. No card offers one before it shows the whole
    /// request.
    private static func isAccept(_ decision: CanvasAgentRequestDecision) -> Bool {
        switch decision {
        case .accept, .acceptForSession, .acceptAndRemember: true
        case .decline, .cancel, .answers: false
        }
    }

    /// The primary button's label: "Allow" for a command; otherwise the
    /// option's own label ("Allow for this turn").
    var primaryLabel: String? {
        guard let primary else { return nil }
        return isCommand ? "Allow" : primary.label
    }
}
