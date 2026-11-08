import Foundation
import JSONRenderCompose
import JSONRenderCore

/// How a composition reaches its evaluator. `live` reads the user's OpenAI
/// key from Settings ▸ AI (`KeychainAISecretStore` through
/// `VoiceKeyResolver`) once per request, inside the evaluator's key provider;
/// the key goes into that request's `Authorization` header and nowhere else.
/// Tests inject an evaluator double, so no test reaches the network.
struct GeneratedViewComposeEnvironment {
    /// Throws when no OpenAI key is set. The key it reads is dropped at once.
    var checkKey: () async throws -> Void
    var makeEvaluator: () -> any DecisionEvaluator

    static var live: GeneratedViewComposeEnvironment {
        GeneratedViewComposeEnvironment(
            checkKey: { _ = try await VoiceKeyResolver.openAIKey() },
            makeEvaluator: {
                OpenAIDecisionsEvaluator(keyProvider: { try await VoiceKeyResolver.openAIKey() })
            })
    }
}

/// The card side of `compose_view`: the composer for a board's facts, and
/// the preview-then-final card rule.
///
/// Undo rule: the preview card is one board undo step. When the final layout
/// arrives and nothing else changed the board since the preview (cards,
/// links, change stamp, no active card content), Rafu undoes the preview step
/// and adds the final card with the same id, so the whole request is one
/// undo step (the rule `GeneratedViewStreamSession.finish` uses). Otherwise
/// the final spec is a normal `GeneratedViewHost.update` (two honest steps).
enum GeneratedViewComposer {
    /// The board right after the preview step.
    struct PreviewMark {
        let cardID: CanvasCardID
        let stamp: UInt64
        let gate: CanvasAgentUndoGate
    }

    enum FinalResult: Equatable {
        /// One undo step for the whole request.
        case collapsed(GeneratedViewSummary)
        /// A second undo step: the board changed after the preview.
        case updated(GeneratedViewSummary)
        /// The final spec equals the preview.
        case unchanged
        /// The user removed the preview card first.
        case removed
        case refused(GeneratedViewError)
    }

    static func composer(
        facts: GeneratedViewComposeFacts, title: String, evaluator: any DecisionEvaluator
    ) throws(CompositionError) -> (composer: Composer, state: JSONRenderCore.JSONValue) {
        let made = GeneratedViewCandidates.make(facts: facts, title: title)
        let composer = try Composer(
            catalog: .rafu, candidates: made.candidates, evaluator: evaluator,
            limits: GeneratedViewCandidates.limits,
            instructions: GeneratedViewCandidates.instructions)
        return (composer, made.state)
    }

    /// The canonical text the card stores (sorted keys, no escaped slashes).
    static func text(_ spec: Spec) -> String? {
        GeneratedViewStatePersistence.canonicalText(spec)
    }

    static func mark(_ cardID: CanvasCardID, on board: CanvasBoardState) -> PreviewMark {
        PreviewMark(
            cardID: cardID, stamp: board.changeStamp,
            gate: CanvasAgentUndoGate(
                boardID: board.id, cards: board.cards, connections: board.connections))
    }

    static func canCollapse(_ mark: PreviewMark, on board: CanvasBoardState) -> Bool {
        board.canUndo && !board.contentIsActive && board.changeStamp == mark.stamp
            && mark.gate.allows(cards: board.cards, connections: board.connections)
    }

    /// Writes the final layout over the preview card.
    static func applyFinal(
        text: String, mark: PreviewMark, journal: [String], board: CanvasBoardState,
        viewHost: any GeneratedViewHost
    ) async -> FinalResult {
        guard let card = board.cards.first(where: { $0.id == mark.cardID }),
            case .generatedView(var view) = card.content
        else { return .removed }
        guard view.specJSON != text else { return .unchanged }
        let summary: GeneratedViewSummary
        switch viewHost.validate(specJSON: text) {
        case .failure(let error): return .refused(error)
        case .success(let value): summary = value
        }
        guard canCollapse(mark, on: board) else {
            do {
                let updated = try await viewHost.update(
                    card.id, change: .spec(text),
                    provenance: VoiceToolExecutor.viewProvenance(title: card.title), on: board)
                return .updated(updated)
            } catch let error as GeneratedViewError {
                return .refused(error)
            } catch {
                return .refused(.invalidSpec("The view could not be changed."))
            }
        }
        if let refusal = GeneratedViewBudget.refusal(
            specJSON: text, cards: board.cards, replacing: card.id)
        {
            return .refused(refusal)
        }
        view.specJSON = text
        view.catalogVersion = RafuCatalog.version
        view.state = nil
        view.provenance.updatedAt = Date()
        view.provenance.journal = Array(
            journal.suffix(CanvasLimits.generatedViewJournalEntries))
        var finished = card
        finished.content = .generatedView(view)
        board.performUndo()
        do {
            try board.edit { $0.cards.append(finished) }
        } catch {
            return .refused(.invalidSpec("The view could not be added."))
        }
        board.select([card.id])
        return .collapsed(summary)
    }

    /// "composed: rounds R, questions Q, refusals F, fallbacks B": counts only.
    static func journalLine(_ steps: [ComposeStep]) -> String {
        "composed: rounds \(steps.count), questions \(steps.reduce(0) { $0 + $1.answers.count }), "
            + "refusals \(steps.reduce(0) { $0 + $1.refused.count }), "
            + "fallbacks \(steps.reduce(0) { $0 + $1.fallbacks.count })"
    }
}
