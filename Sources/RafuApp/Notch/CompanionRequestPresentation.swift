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
