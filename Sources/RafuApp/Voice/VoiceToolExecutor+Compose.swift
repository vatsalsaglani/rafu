import Foundation
import JSONRenderCompose
import JSONRenderCore
import RafuCore

/// Voice `compose_view`: Rafu composes a view from the board data the backend
/// already has, with the OpenAI Decisions API picking and arranging Rafu's own
/// parts (`JSONRenderCompose`). It runs only when the backend calls it; Rafu
/// never runs it after a `show_view` failure. Off refuses; Ask runs at once
/// with an Undo notice; Allow runs. The preview card shows after the first
/// round, the final layout after the second, and the request is one undo
/// step when nothing else changed. Nothing here logs the prompt, the context,
/// the title, the key or a response; the timeline line is counts only.
extension VoiceToolExecutor {
    static let maximumComposePrompt = 400
    static let maximumComposeContext = 1_000
    static let composeUnavailableMessage =
        "Rafu could not compose a view for that. Ask for a specific view instead."
    static let composeServiceMessage =
        "The composer service did not answer. Ask for a specific view instead."

    struct ComposeViewRequest: Equatable {
        var prompt: String
        var context: String?
        var title: String
        var near: String?
    }

    enum ComposeViewParse: Equatable {
        case request(ComposeViewRequest)
        case refused(VoiceToolOutcome)
    }

    static func composeView(
        _ arguments: [String: Any], host: any VoiceToolHost,
        environment: GeneratedViewComposeEnvironment = .live
    ) async -> VoiceToolOutcome {
        guard let target = host.voiceTarget(), let board = target.board else {
            return failure("no_ensemble", noBoardMessage)
        }
        let caller = CanvasAgentCaller.voice(
            session: target.session, board: board, callerID: host.callerID)
        if case .deny(let reason) = VoicePolicy.decide(mode: board.agentControlMode, risk: .edit) {
            CanvasAgentCenter.shared.record(
                board.id, agent: caller.agentName,
                action: CanvasAgentTool.viewRender.actionTitle,
                outcome: "Blocked: Agent control is Off")
            return failure("agent_control_off", reason)
        }
        guard CanvasAgentCenter.shared.admit(host.callerID) else {
            return failure("rate_limited", rateLimitedMessage)
        }
        let request: ComposeViewRequest
        switch parseComposeView(arguments) {
        case .request(let parsed): request = parsed
        case .refused(let outcome): return outcome
        }
        guard let viewHost = host.generatedViewHost else {
            return failure("unavailable", GeneratedViewCopy.unavailable)
        }
        do {
            try await environment.checkKey()
        } catch {
            return failure("no_openai_key", VoiceError.noOpenAIKey.blobReason)
        }
        let nodes = CanvasAgentActions.describe(caller).nodes ?? []
        let shares = VoicePolicy.sharesTerminalTail(
            mode: board.agentControlMode, setting: host.voicePreferences.sharesTerminalTail)
        let facts = GeneratedViewComposeFacts.make(
            ensemble: board.title, links: board.connections.count,
            agentControl: board.agentControlMode.rawValue, nodes: nodes,
            tails: shares ? VoiceTerminalTail.tails(for: board, session: caller.session) : nil)
        let made: (composer: Composer, state: JSONRenderCore.JSONValue)
        do {
            made = try GeneratedViewComposer.composer(
                facts: facts, title: request.title, evaluator: environment.makeEvaluator())
        } catch {
            return failure("failed", "Rafu could not prepare the parts for a view.")
        }
        let context = GeneratedViewComposeContext.make(
            facts: facts, userContext: request.context)
        let rect = composePlacement(near: request.near, nodes: nodes, caller: caller)

        var steps: [ComposeStep] = []
        var tokens: Int?
        var stop: ComposeStopReason?
        var mark: GeneratedViewComposer.PreviewMark?
        var elements = 0
        var finalDropped = false
        do {
            let stream = made.composer.compose(
                prompt: request.prompt, context: context, initialState: made.state)
            for try await event in stream {
                let spec: Spec?
                switch event {
                case .step(let value, let step):
                    steps.append(step)
                    spec = value
                case .complete(let value, let all, _, let used, let reason):
                    steps = all
                    tokens = used
                    stop = reason
                    spec = value
                }
                guard let spec, !Task.isCancelled else { continue }
                guard let text = GeneratedViewComposer.text(spec) else { continue }
                if let current = mark {
                    let applied = await applyComposedFinal(
                        text: text, mark: current, steps: steps, board: board,
                        viewHost: viewHost, title: request.title, caller: caller, host: host)
                    switch applied {
                    case .collapsed, .updated: elements = spec.elements.count
                    case .unchanged: break
                    case .refused: finalDropped = true
                    case .removed:
                        // The user removed the preview between the rounds: say so, never "Showing".
                        return failure("removed", "The view was removed before it finished.")
                    }
                } else {
                    let before = board.cards
                    let connectionsBefore = board.connections.count
                    var provenance = viewProvenance(title: request.title)
                    provenance.journal = [GeneratedViewComposer.journalLine(steps)]
                    let card: CanvasCardID
                    do {
                        card = try viewHost.create(
                            specJSON: text, title: request.title, rect: rect,
                            provenance: provenance, on: board)
                    } catch {
                        return composeCreateFailure(error)
                    }
                    elements = spec.elements.count
                    noteEffect(
                        on: board, before: before, connectionsBefore: connectionsBefore,
                        host: host)
                    noteComposed(board: board, title: request.title, caller: caller, host: host)
                    mark = GeneratedViewComposer.mark(card, on: board)
                }
            }
        } catch {
            // Cancellation keeps a preview already shown (like a late MCP
            // approval) and drops the layout. `CompositionError` (for
            // example too many questions) ends like an unavailable answer.
            if !(error is CancellationError) { stop = .unavailable }
            finalDropped = mark != nil
        }
        let rounds = steps.count
        let questions = steps.reduce(0) { $0 + $1.answers.count }
        let summary =
            "\(elementsText(elements)); rounds \(rounds); questions \(questions); tokens "
            + (tokens.map(String.init) ?? "unknown")
        guard let mark else {
            let serviceFailed = steps.contains { $0.description.contains("; evaluator:") }
            let outcome = failure(
                "unavailable", serviceFailed ? composeServiceMessage : composeUnavailableMessage)
            return VoiceToolOutcome(output: outcome.output, summary: "unavailable; \(summary)")
        }
        let partial = finalDropped || stop != .finish
        var message = "Showing \(CanvasAgentText.singleLine(request.title, limit: 120))."
        if partial { message += " The layout is a first draft." }
        return VoiceToolOutcome(
            output: VoiceJSON.object([
                "status": .string(partial ? "partial" : "ok"),
                "node_id": .string(mark.cardID.rawValue.uuidString),
                "elements": .integer(elements), "rounds": .integer(rounds),
                "message": .string(message),
            ]).jsonString(),
            summary: summary)
    }

    /// The final layout, then the voice undo step and notice for it.
    private static func applyComposedFinal(
        text: String, mark: GeneratedViewComposer.PreviewMark, steps: [ComposeStep],
        board: CanvasBoardState, viewHost: any GeneratedViewHost, title: String,
        caller: CanvasAgentCaller, host: any VoiceToolHost
    ) async -> GeneratedViewComposer.FinalResult {
        let before = board.cards
        let connectionsBefore = board.connections.count
        let result = await GeneratedViewComposer.applyFinal(
            text: text, mark: mark, journal: [GeneratedViewComposer.journalLine(steps)],
            board: board, viewHost: viewHost)
        switch result {
        case .collapsed:
            // Still one change for the user: the ring, the step and the notice.
            board.landing = CanvasLanding(ids: [mark.cardID])
            noteComposed(board: board, title: title, caller: caller, host: host, log: false)
        case .updated:
            noteEffect(
                on: board, before: before, connectionsBefore: connectionsBefore, host: host)
            noteComposed(board: board, title: title, caller: caller, host: host, log: false)
        case .unchanged, .removed, .refused: break
        }
        return result
    }

    private static func noteComposed(
        board: CanvasBoardState, title: String, caller: CanvasAgentCaller,
        host: any VoiceToolHost, log: Bool = true
    ) {
        if board.canUndo {
            host.undoLedger.record(board)
            showUndoNotice(
                "Rafu (voice) composed \(CanvasAgentText.singleLine(title, limit: 60))",
                board: board)
        }
        if log {
            CanvasAgentCenter.shared.record(
                board.id, agent: caller.agentName,
                action: CanvasAgentTool.viewRender.actionTitle, outcome: "Done")
        }
    }

    private static func composeCreateFailure(_ error: any Error) -> VoiceToolOutcome {
        if let error = error as? GeneratedViewError { return viewFailure(error) }
        if let error = error as? CanvasError, error == .capacity { return viewFailure(.capacity) }
        return failure("failed", "Rafu could not show the view.")
    }

    /// Beside `near` when it resolves to one node, else beside the single
    /// selected node or the focused node, else the board's default spot.
    static func composePlacement(
        near: String?, nodes: [CanvasAgentNodeSummary], caller: CanvasAgentCaller
    ) -> CanvasRect {
        let board = caller.board
        let selection = board.cards.filter { board.selection.contains($0.id) }
            .map { $0.id.rawValue.uuidString }
        let focus = board.focusedCardID?.rawValue.uuidString
        var call = CanvasAgentToolCall(tool: .viewRender)
        if let near,
            case .success(let id) = VoiceTargetResolver.resolve(
                ref: near, nodes: nodes, selection: selection, focus: focus)
        {
            call.near = id
        } else {
            call.near = selection.count == 1 ? selection.first : focus
        }
        return CanvasAgentActions.placement(call, kind: "view", caller: caller)
    }

    // MARK: Arguments

    static func parseComposeView(_ arguments: [String: Any]) -> ComposeViewParse {
        func refused(_ message: String) -> ComposeViewParse {
            .refused(failure("invalid_arguments", message))
        }
        func optionalText(_ key: String) -> (String?, Bool) {
            guard let value = arguments[key] else { return (nil, true) }
            guard let text = value as? String else { return (nil, false) }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : trimmed, true)
        }
        let (promptValue, promptOK) = optionalText("prompt")
        guard promptOK, let prompt = promptValue else {
            return refused("prompt is required: what the user wants to see.")
        }
        guard prompt.count <= maximumComposePrompt else {
            return refused("prompt must be at most \(maximumComposePrompt) characters.")
        }
        let (context, contextOK) = optionalText("context")
        guard contextOK else { return refused("context must be a string.") }
        if let context, context.count > maximumComposeContext {
            return refused("context must be at most \(maximumComposeContext) characters.")
        }
        let (titleValue, titleOK) = optionalText("title")
        guard titleOK else { return refused("title must be a string.") }
        if let titleValue, !CanvasDocument.validTitle(titleValue) {
            return refused("title must be one line of at most 120 characters.")
        }
        let (near, nearOK) = optionalText("near")
        guard nearOK else { return refused("near must be a string.") }
        return .request(
            ComposeViewRequest(
                prompt: prompt, context: context,
                title: titleValue ?? defaultComposeTitle(prompt), near: near))
    }

    /// The first 60 characters of the prompt on one line, first letter upper case.
    static func defaultComposeTitle(_ prompt: String) -> String {
        let line = prompt.components(separatedBy: .newlines).joined(separator: " ")
        var title = String(line.prefix(60)).trimmingCharacters(in: .whitespaces)
        if let first = title.first {
            title = first.uppercased() + title.dropFirst()
        }
        return CanvasDocument.validTitle(title) ? title : defaultViewTitle
    }
}
