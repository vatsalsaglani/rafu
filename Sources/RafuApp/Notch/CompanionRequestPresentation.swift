import RafuCore

struct CompanionRequestPresentation {
    let request: CanvasAgentRequest
    let decision: CanvasAgentRequestDecision?

    enum Controls: Equatable {
        case terminal
        case options([CanvasAgentRequest.Option])
        case questions([CanvasAgentRequest.Question])
        case sending
    }

    var controls: Controls {
        if request.terminalOnly { return .terminal }
        if decision != nil { return .sending }
        if request.kind == .userInput { return .questions(request.questions) }
        return .options(request.options)
    }

    var title: String {
        switch request.kind {
        case .command: "Run command"
        case .fileChange: "Apply file changes"
        case .permissions: "Grant permissions"
        case .userInput: "Answer questions"
        }
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
    /// The other options (`.acceptForSession`, `.cancel`), in request order.
    let overflow: [CanvasAgentRequest.Option]
    /// The request is a command: its primary answer reads "Allow".
    let isCommand: Bool

    init(request: CanvasAgentRequest) {
        let options = request.options
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
            overflow: overflow.filter { $0.decision != .acceptForSession },
            isCommand: isCommand)
    }

    /// The primary button's label: "Allow" for a command; otherwise the
    /// option's own label ("Allow for this turn").
    var primaryLabel: String? {
        guard let primary else { return nil }
        return isCommand ? "Allow" : primary.label
    }
}
