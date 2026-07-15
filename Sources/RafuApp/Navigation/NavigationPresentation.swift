import Foundation

/// What `NavigationPeekView` should show for a resolved (or not-yet-resolved)
/// navigation answer. Deliberately mirrors `NavigationAnswer.State` plus the
/// "no candidates" case rather than exposing `NavigationAnswer` directly, so
/// the view never has to re-derive presentation rules from raw ladder output.
nonisolated enum NavigationPeekContent: Equatable {
    case results(NavigationAnswer)
    case indexing
    case empty(NavigationTargetKind)
}

/// What `WorkspaceSession.navigate(kind:)` should do with a resolved answer:
/// jump straight to the sole candidate, or present a peek.
nonisolated enum NavigationOutcome: Equatable {
    case jump(SymbolCandidate)
    case peek(NavigationPeekContent)
}

/// Pure decision layer between a `NavigationLadder.resolve(_:)` result and
/// the UI: a single candidate jumps directly (no peek flash for the common
/// case), anything else — no answer, an indexing tier, or multiple
/// candidates — presents `NavigationPeekView`.
nonisolated enum NavigationPresentation {
    static func outcome(for answer: NavigationAnswer?, kind: NavigationTargetKind)
        -> NavigationOutcome
    {
        guard let answer else { return .peek(.empty(kind)) }
        switch answer.state {
        case .indexing:
            return .peek(.indexing)
        case .ready, .unavailable:
            switch answer.candidates.count {
            case 0: return .peek(.empty(kind))
            case 1: return .jump(answer.candidates[0])
            default: return .peek(.results(answer))
            }
        }
    }
}
