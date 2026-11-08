import Foundation
import RafuCore

/// Voice `show_view` (wave 3): one tool that shows a generated view, replaces
/// a view's spec, or resets its state. Ask runs at once with an Undo notice
/// (ADR 0035 §5); Off refuses. When GPT-Live streams the arguments, the
/// session starts a skeleton card through `beginShowView` and this call
/// finishes it. Nothing here logs the spec, the title or the state.
extension VoiceToolExecutor {
    static let defaultViewTitle = "View"
    /// The bytes of one voice spec. Voice is in-process, not an MCP frame, so
    /// it uses the card's own bound, not the 48 KiB per-call MCP bound.
    static var maximumVoiceViewBytes: Int { CanvasLimits.generatedViewSpecBytes }

    /// What a `show_view` call asks for, after its arguments were checked.
    struct ShowViewRequest: Equatable {
        var title: String
        var node: String?
        var reset: Bool
        /// Canonical spec JSON. Nil only for a reset.
        var specJSON: String?
    }

    enum ShowViewParse: Equatable {
        case request(ShowViewRequest)
        case refused(VoiceToolOutcome)
    }

    // MARK: Streaming start

    /// Starts a skeleton view card for a streaming `show_view`. Returns nil
    /// (and the final call then creates the card without streaming) when no
    /// Ensemble shows, Agent control is Off, no view host is installed, the
    /// rate limit refuses, or the host refuses. The admission counted here is
    /// not counted again when the call finishes.
    static func beginShowView(title: String, host: any VoiceToolHost)
        -> (any GeneratedViewStreamHandle)?
    {
        guard let target = host.voiceTarget(), let board = target.board,
            let viewHost = host.generatedViewHost
        else { return nil }
        if case .deny = VoicePolicy.decide(mode: board.agentControlMode, risk: .edit) {
            return nil
        }
        guard CanvasAgentCenter.shared.admit(host.callerID) else { return nil }
        let caller = CanvasAgentCaller.voice(
            session: target.session, board: board, callerID: host.callerID)
        let title = CanvasDocument.validTitle(title) ? title : defaultViewTitle
        return try? viewHost.beginStreaming(
            title: title, rect: viewPlacement(caller: caller),
            provenance: viewProvenance(title: title), on: board)
    }

    // MARK: The call

    /// Runs `show_view`. `callID` finds a skeleton card started while the
    /// arguments streamed; every refusal cancels it, so no skeleton is left.
    static func showView(_ arguments: [String: Any], callID: String?, host: any VoiceToolHost)
        async -> VoiceToolOutcome
    {
        var stream = callID.flatMap { host.viewStreamHandle(for: $0) }
        if let callID, stream != nil { host.takeViewStreamHandle(for: callID) }
        func refuse(_ outcome: VoiceToolOutcome) -> VoiceToolOutcome {
            stream?.cancel()
            stream = nil
            return outcome
        }
        guard let target = host.voiceTarget(), let board = target.board else {
            return refuse(failure("no_ensemble", noBoardMessage))
        }
        let caller = CanvasAgentCaller.voice(
            session: target.session, board: board, callerID: host.callerID)
        if case .deny(let reason) = VoicePolicy.decide(mode: board.agentControlMode, risk: .edit) {
            CanvasAgentCenter.shared.record(
                board.id, agent: caller.agentName,
                action: CanvasAgentTool.viewRender.actionTitle,
                outcome: "Blocked: Agent control is Off")
            return refuse(failure("agent_control_off", reason))
        }
        if stream == nil, !CanvasAgentCenter.shared.admit(host.callerID) {
            return refuse(failure("rate_limited", rateLimitedMessage))
        }
        let request: ShowViewRequest
        switch parseShowView(arguments) {
        case .request(let parsed): request = parsed
        case .refused(let outcome): return refuse(outcome)
        }
        guard let viewHost = host.generatedViewHost else {
            return refuse(failure("unavailable", GeneratedViewCopy.unavailable))
        }
        if let node = request.node {
            // An update never uses the skeleton card.
            stream?.cancel()
            stream = nil
            return await updateView(
                node, request: request, viewHost: viewHost, caller: caller, host: host)
        }
        guard let specJSON = request.specJSON else {
            return refuse(failure("invalid_arguments", "Give root and elements to show a view."))
        }
        let connectionsBefore = board.connections.count
        let before: [CanvasCard]
        let card: CanvasCardID
        let summary: GeneratedViewSummary
        if let handle = stream {
            stream = nil
            before = board.cards.filter { $0.id != handle.cardID }
            switch await handle.finish(specJSON: specJSON) {
            case .failure(let error): return viewFailure(error)
            case .success(let value): (card, summary) = (handle.cardID, value)
            }
        } else {
            before = board.cards
            // Validate first: the summary carries the element count for the
            // answer, and an invalid spec never makes an undo step.
            switch viewHost.validate(specJSON: specJSON) {
            case .failure(let error): return viewFailure(error)
            case .success(let value): summary = value
            }
            do {
                card = try viewHost.create(
                    specJSON: specJSON, title: request.title, rect: viewPlacement(caller: caller),
                    provenance: viewProvenance(title: request.title), on: board)
            } catch {
                return createFailure(error)
            }
        }
        noteViewChange(
            on: board, before: before, connectionsBefore: connectionsBefore,
            notice: "Rafu (voice) showed \(CanvasAgentText.singleLine(request.title, limit: 60))",
            caller: caller, host: host)
        return viewSuccess(card: card, summary: summary, title: request.title)
    }

    private static func createFailure(_ error: any Error) -> VoiceToolOutcome {
        if let error = error as? GeneratedViewError { return viewFailure(error) }
        if let error = error as? CanvasError, error == .capacity { return viewFailure(.capacity) }
        return failure(
            "failed",
            (error as? LocalizedError)?.errorDescription ?? "Rafu could not show the view.")
    }

    private static func updateView(
        _ ref: String, request: ShowViewRequest, viewHost: any GeneratedViewHost,
        caller: CanvasAgentCaller, host: any VoiceToolHost
    ) async -> VoiceToolOutcome {
        let board = caller.board
        let views = (CanvasAgentActions.describe(caller).nodes ?? []).filter { $0.kind == "view" }
        let selection = board.cards.filter { board.selection.contains($0.id) }
            .map { $0.id.rawValue.uuidString }
        let id: String
        switch VoiceTargetResolver.resolve(
            ref: ref, nodes: views, selection: selection,
            focus: board.focusedCardID?.rawValue.uuidString)
        {
        case .success(let value): id = value
        case .failure(let error):
            return VoiceToolOutcome(output: error.agentJSON, summary: "unresolved node")
        }
        guard let uuid = UUID(uuidString: id),
            let card = board.cards.first(where: { $0.id.rawValue == uuid })
        else { return failure("not_found", "No view matches.") }
        let change: GeneratedViewChange
        if request.reset {
            change = .reset
        } else if let specJSON = request.specJSON {
            change = .spec(specJSON)
        } else {
            return failure("invalid_arguments", "Give root and elements, or reset true.")
        }
        let before = board.cards
        let connectionsBefore = board.connections.count
        let summary: GeneratedViewSummary
        do {
            summary = try await viewHost.update(
                card.id, change: change, provenance: viewProvenance(title: request.title),
                on: board)
        } catch {
            return createFailure(error)
        }
        let verb = request.reset ? "reset" : "changed"
        if board.cards != before {
            noteViewChange(
                on: board, before: before, connectionsBefore: connectionsBefore,
                notice: "Rafu (voice) \(verb) \(CanvasAgentText.singleLine(card.title, limit: 60))",
                caller: caller, host: host)
        }
        let message = request.reset ? "Reset \(card.title)." : "Showing \(card.title)."
        return VoiceToolOutcome(
            output: VoiceJSON.object([
                "status": "ok", "node_id": .string(id),
                "elements": .integer(summary.elementCount),
                "message": .string(CanvasAgentText.singleLine(message, limit: 140)),
            ]).jsonString(),
            summary: request.reset ? "reset" : elementsText(summary.elementCount))
    }

    /// The set-down ring, a Board effects row, one voice undo step, the
    /// Undo notice and the activity log, like every voice board change.
    private static func noteViewChange(
        on board: CanvasBoardState, before: [CanvasCard], connectionsBefore: Int,
        notice: String, caller: CanvasAgentCaller, host: any VoiceToolHost
    ) {
        noteEffect(on: board, before: before, connectionsBefore: connectionsBefore, host: host)
        if board.canUndo {
            host.undoLedger.record(board)
            showUndoNotice(notice, board: board)
        }
        CanvasAgentCenter.shared.record(
            board.id, agent: caller.agentName, action: CanvasAgentTool.viewRender.actionTitle,
            outcome: "Done")
    }

    private static func viewSuccess(
        card: CanvasCardID, summary: GeneratedViewSummary, title: String
    ) -> VoiceToolOutcome {
        VoiceToolOutcome(
            output: VoiceJSON.object([
                "status": "ok", "node_id": .string(card.rawValue.uuidString),
                "elements": .integer(summary.elementCount),
                "message": .string(
                    "Showing \(CanvasAgentText.singleLine(title, limit: 120))."),
            ]).jsonString(),
            summary: elementsText(summary.elementCount))
    }

    /// "1 element", "3 elements": the timeline's counts-only summary.
    static func elementsText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "element" : "elements")"
    }

    /// The model sees the validator's text (codes, element ids and types,
    /// never prop values), so it can fix the spec and try once more. The
    /// timeline sees only the code.
    static func viewFailure(_ error: GeneratedViewError) -> VoiceToolOutcome {
        switch error {
        case .invalidSpec(let text):
            failure("invalid_spec", CanvasAgentText.singleLine(text, limit: 1_000))
        case .tooLarge(let bytes):
            failure(
                "too_large",
                "The view is \(bytes) bytes; at most \(maximumVoiceViewBytes / 1_024) KiB.")
        case .capacity:
            failure(
                "capacity",
                "This Ensemble holds the most views it can. Ask the user to remove one.")
        case .notAView: failure("not_a_view", "That node is not a view.")
        case .unavailable: failure("unavailable", GeneratedViewCopy.unavailable)
        }
    }

    // MARK: Arguments

    /// Checks the arguments: title (default "View"), node, reset, and the
    /// flat spec keys. A `spec` object is accepted too, because a model may
    /// nest the spec by habit; that call does not stream.
    static func parseShowView(_ arguments: [String: Any]) -> ShowViewParse {
        var title = defaultViewTitle
        if let value = arguments["title"] {
            guard let text = value as? String else {
                return .refused(failure("invalid_arguments", "title must be a string."))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                guard CanvasDocument.validTitle(trimmed) else {
                    return .refused(
                        failure(
                            "invalid_arguments", "title must be one line of at most 120 characters."
                        ))
                }
                title = trimmed
            }
        }
        var node: String?
        if let value = arguments["node"] {
            guard let text = value as? String else {
                return .refused(failure("invalid_arguments", "node must be a string."))
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            node = trimmed.isEmpty ? nil : trimmed
        }
        var reset = false
        if let value = arguments["reset"] {
            guard let flag = value as? Bool else {
                return .refused(failure("invalid_arguments", "reset must be true or false."))
            }
            reset = flag
        }
        var spec = arguments
        if let nested = arguments["spec"] as? [String: Any] {
            spec = nested
        } else {
            for key in ["title", "node", "reset"] { spec.removeValue(forKey: key) }
        }
        let root = spec["root"] as? String ?? ""
        let elements = spec["elements"] as? [String: Any] ?? [:]
        let isEmptySpec = root.isEmpty && elements.isEmpty && spec["state"] == nil
        if reset {
            guard node != nil else {
                return .refused(
                    failure("invalid_arguments", "reset needs node: the view to reset."))
            }
            guard isEmptySpec else {
                return .refused(
                    failure("invalid_arguments", "Give reset true or a spec, not both."))
            }
            return .request(ShowViewRequest(title: title, node: node, reset: true, specJSON: nil))
        }
        switch canonicalSpec(spec) {
        case .request(var request):
            request.title = title
            request.node = node
            return .request(request)
        case .refused(let outcome): return .refused(outcome)
        }
    }

    /// Sorted keys and no escaped slashes, like the MCP path's canonical text,
    /// within the card's byte bound. Reasons are fixed text and numbers.
    static func canonicalSpec(_ object: [String: Any]) -> ShowViewParse {
        func refused(_ message: String) -> ShowViewParse {
            .refused(failure("invalid_spec", message))
        }
        guard let root = object["root"] as? String, !root.isEmpty,
            let elements = object["elements"] as? [String: Any], !elements.isEmpty
        else { return refused("Give root (an element id) and elements (id → element).") }
        if let state = object["state"], !(state is [String: Any]) {
            return refused("state must be an object.")
        }
        let unknown = Set(object.keys).subtracting(["root", "elements", "state"])
        guard unknown.isEmpty else {
            return refused("Unknown keys: \(unknown.sorted().prefix(4).joined(separator: ", ")).")
        }
        guard elements.count <= CanvasAgentToolCall.maximumViewElements else {
            return refused(
                "The spec has \(elements.count) elements; at most "
                    + "\(CanvasAgentToolCall.maximumViewElements).")
        }
        guard !containsForbiddenKey(object, depth: 0) else {
            return refused("The spec contains a forbidden key or nests too deep.")
        }
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return refused("The spec is not valid JSON.") }
        guard data.count <= maximumVoiceViewBytes else {
            return .refused(viewFailure(.tooLarge(bytes: data.count)))
        }
        return .request(
            ShowViewRequest(title: defaultViewTitle, node: nil, reset: false, specJSON: text))
    }

    private static func containsForbiddenKey(_ value: Any, depth: Int) -> Bool {
        if depth > 64 { return true }
        if let object = value as? [String: Any] {
            return object.contains { key, item in
                key == "__proto__" || containsForbiddenKey(item, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsForbiddenKey($0, depth: depth + 1) }
        }
        return false
    }

    // MARK: Placement and provenance

    /// Beside the single selected node, else the focused node, else the
    /// board's default spot: the same anchor rule as the other voice creates.
    static func viewPlacement(caller: CanvasAgentCaller) -> CanvasRect {
        let board = caller.board
        let selection = board.cards.filter { board.selection.contains($0.id) }
            .map { $0.id.rawValue.uuidString }
        var call = CanvasAgentToolCall(tool: .viewRender)
        call.near =
            selection.count == 1 ? selection.first : board.focusedCardID?.rawValue.uuidString
        return CanvasAgentActions.placement(call, kind: "view", caller: caller)
    }

    static func viewProvenance(title: String) -> CanvasGeneratedViewProvenance {
        CanvasGeneratedViewProvenance(
            creator: "Rafu (voice)", provider: CanvasAgentCaller.voiceProvider, createdAt: Date(),
            updatedAt: nil, promptSummary: boundedSummary(title), admission: "voice", journal: [])
    }

    /// At most 200 UTF-8 bytes, cut on a character boundary.
    private static func boundedSummary(_ text: String) -> String {
        var result = ""
        for character in text {
            guard result.utf8.count + String(character).utf8.count <= 200 else { break }
            result.append(character)
        }
        return result
    }
}

/// Reads the `title` of a streaming `show_view` from the first argument text,
/// so the skeleton card carries its real title. Only the text before the spec
/// keys counts: a `title` prop inside an element is never the card title.
nonisolated enum VoiceViewStreamTitle {
    private static let specKeys = ["\"root\"", "\"elements\"", "\"state\""]

    /// True once a spec key began: a title, if any, comes after the spec.
    static func isPastTitle(_ text: String) -> Bool {
        specKeys.contains { text.contains($0) }
    }

    /// The complete, valid title string, or nil while it is still arriving.
    static func title(in text: String) -> String? {
        let head =
            specKeys.compactMap { text.range(of: $0)?.lowerBound }.min()
            .map { text[..<$0] } ?? text[...]
        guard let key = head.range(of: "\"title\"") else { return nil }
        var index = key.upperBound
        func skipSpace() {
            while index < head.endIndex, head[index].isWhitespace {
                index = head.index(after: index)
            }
        }
        skipSpace()
        guard index < head.endIndex, head[index] == ":" else { return nil }
        index = head.index(after: index)
        skipSpace()
        guard index < head.endIndex, head[index] == "\"" else { return nil }
        let start = index
        index = head.index(after: index)
        var escaped = false
        while index < head.endIndex {
            let character = head[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let literal = "[" + head[start...index] + "]"
                guard
                    let array = try? JSONSerialization.jsonObject(with: Data(literal.utf8))
                        as? [String],
                    let value = array.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                    CanvasDocument.validTitle(value)
                else { return nil }
                return value
            }
            index = head.index(after: index)
        }
        return nil
    }
}
