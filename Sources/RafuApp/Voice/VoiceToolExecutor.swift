import Foundation
import RafuCore

/// The window and board that voice acts on: the key workspace window and the
/// Ensemble it shows. `board` is nil when that window shows no Ensemble;
/// orchestrator tools still work then.
struct VoiceTarget {
    let session: WorkspaceSession
    let board: CanvasBoardState?
}

/// What `VoiceToolExecutor` needs from the running session.
@MainActor
protocol VoiceToolHost: AnyObject {
    var callerID: UUID { get }
    var personaName: String { get }
    var voicePreferences: VoicePreferences { get }
    var undoLedger: VoiceUndoLedger { get }
    func voiceTarget() -> VoiceTarget?
    /// Every live workspace window, front first.
    func voiceWorkspaces() -> [WorkspaceSession]
    func voiceStatus() -> VoiceJSON
    /// "Stay with me": latch the microphone.
    func latchFromTool()
    /// Shows the Confirm card for a sensitive call and waits for one answer.
    func confirm(_ request: VoiceConfirmRequest) async -> VoiceConfirmAnswer
    /// A spoken `voice_confirm` / `voice_cancel`.
    func resolveConfirm(_ answer: VoiceConfirmAnswer) -> VoiceConfirmResolution
    /// "Allow for This Session" was given for this tool on this Ensemble.
    func hasSessionGrant(_ key: String) -> Bool
    func grantForSession(_ key: String)
    /// A Board effects row on the timeline (counts only).
    func noteBoardEffect(_ title: String, detail: String)
    /// The generated-view card implementation; nil until one is installed.
    var generatedViewHost: (any GeneratedViewHost)? { get }
    /// The skeleton card a streaming `show_view` started for this call, if any.
    func viewStreamHandle(for callID: String) -> (any GeneratedViewStreamHandle)?
    /// Forgets that handle: the call finished or cancelled it.
    func takeViewStreamHandle(for callID: String)
}

/// One tool result: the JSON for the backend, and a counts-only line for the
/// timeline. Neither ever holds a key; the timeline line never holds text.
struct VoiceToolOutcome: Equatable {
    let output: String
    let summary: String
    var isError: Bool { output.hasPrefix("{\"error\"") }
}

/// Undo steps made by voice, per board: the board content right after each
/// step. Undo by voice runs only while the board still equals the newest
/// one, so voice never undoes the user's own later edit.
@MainActor
final class VoiceUndoLedger {
    static let depth = 20
    private var steps: [CanvasID: [CanvasAgentUndoGate]] = [:]

    func record(_ board: CanvasBoardState) {
        var list = steps[board.id, default: []]
        list.append(
            CanvasAgentUndoGate(
                boardID: board.id, cards: board.cards, connections: board.connections))
        if list.count > Self.depth { list.removeFirst(list.count - Self.depth) }
        steps[board.id] = list
    }

    /// Undoes the newest voice step when nothing changed after it.
    func undo(on board: CanvasBoardState) -> Bool {
        guard let gate = steps[board.id]?.last, board.canUndo,
            gate.allows(cards: board.cards, connections: board.connections)
        else { return false }
        board.performUndo()
        steps[board.id]?.removeLast()
        return true
    }

    func clear() { steps.removeAll() }
}

/// Runs one backend function call. Ensemble tools go through the existing
/// `CanvasAgentActions.perform` with the voice caller, so every change is the
/// same undoable board edit an agent makes, with "Rafu (voice)" provenance.
@MainActor
enum VoiceToolExecutor {
    static let needsPhaseTwoMessage =
        "Rafu voice does this in a later version. Tell the user in one sentence and do not retry."
    static let noBoardMessage =
        "No Ensemble is showing in the front Rafu window. Ask the user to open one, or call ensemble_open."
    static let undoRefusedMessage =
        "Nothing to undo by voice: the newest change on this Ensemble was not made by voice, or something changed after it."
    static let rateLimitedMessage = "Too many Ensemble changes. Wait one minute."
    static let cancelledMessage =
        "The user cancelled. It did not happen. Do not retry unless asked."
    static let timedOutMessage =
        "Nobody confirmed within a minute, so it did not happen. Do not retry unless asked."
    static let busyMessage =
        "Another action is waiting for the user's confirmation. Ask about that one first."
    static let nothingPendingMessage = "No action is waiting for confirmation."
    static let notHeardMessage =
        "Rafu did not hear the user answer. Wait for the user to say yes or no."
    static let noWindowMessage = "No Rafu window is open to show the confirmation."

    /// Keys that hold a node reference the resolver may turn into an id.
    private static let nodeKeys = ["node_id", "from", "to"]
    private static let placementTools: Set<CanvasAgentTool> = [
        .noteCreate, .nodeCreate, .terminalCreate, .diagramBuild,
    ]

    /// `callID` lets `show_view` find the skeleton card its streamed
    /// arguments started.
    static func run(
        name: String, argumentsJSON: String, callID: String? = nil, host: any VoiceToolHost
    ) async -> VoiceToolOutcome {
        let arguments: [String: Any]
        if argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            arguments = [:]
        } else {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))
                    as? [String: Any]
            else {
                return failure("invalid_arguments", "Arguments must be a JSON object.")
            }
            arguments = object
        }
        if VoiceToolSchema.phaseTwoNames.contains(name) {
            return VoiceToolOutcome(
                output: VoiceJSON.toolError("needs_phase_2", needsPhaseTwoMessage),
                summary: "later version")
        }
        if CanvasAgentTool(rawValue: name) != nil {
            return await ensembleTool(name, arguments: arguments, host: host)
        }
        switch name {
        case "voice_confirm":
            let always = arguments["always"] as? Bool ?? false
            return resolveConfirm(always ? .allowForSession : .allowOnce, host: host)
        case "voice_cancel": return resolveConfirm(.cancel, host: host)
        case "list_ensembles": return await listEnsembles(host: host)
        case "ensemble_open": return await ensembleOpen(arguments, host: host)
        case "ensemble_create": return await ensembleCreate(arguments, host: host)
        case "cross_board_summary": return crossBoardSummary(host: host)
        case "voice_status":
            return VoiceToolOutcome(output: host.voiceStatus().jsonString(), summary: "ok")
        case "voice_undo": return voiceUndo(host: host)
        case "voice_latch":
            host.latchFromTool()
            return VoiceToolOutcome(
                output: VoiceJSON.object(["status": "ok", "message": "The microphone stays open."])
                    .jsonString(),
                summary: "latched")
        case "view_zoom": return viewZoom(arguments, host: host)
        case "view_tidy": return viewTidy(host: host)
        case "show_view": return await showView(arguments, callID: callID, host: host)
        default:
            return failure("unknown_tool", "Rafu has no tool with that name.")
        }
    }

    static func failure(_ code: String, _ message: String) -> VoiceToolOutcome {
        VoiceToolOutcome(output: VoiceJSON.toolError(code, message), summary: code)
    }

    // MARK: Ensemble tools

    private static func ensembleTool(
        _ name: String, arguments original: [String: Any], host: any VoiceToolHost
    ) async -> VoiceToolOutcome {
        var arguments = original
        let requestedEnsemble = arguments.removeValue(forKey: "ensemble") as? String
        guard let target = host.voiceTarget() else { return failure("no_ensemble", noBoardMessage) }
        var session = target.session
        var board = target.board
        if name == CanvasAgentTool.ensembleDescribe.rawValue, let requestedEnsemble,
            !requestedEnsemble.isEmpty
        {
            switch findOpenBoard(requestedEnsemble, in: host.voiceWorkspaces()) {
            case .success(let found):
                session = found.session
                board = found.board
            case .failure(let error):
                return VoiceToolOutcome(output: error.agentJSON, summary: "ensemble not found")
            }
        }
        guard let board else { return failure("no_ensemble", noBoardMessage) }
        let caller = CanvasAgentCaller.voice(
            session: session, board: board, callerID: host.callerID)
        let tool = CanvasAgentTool(rawValue: name)
        let nodes = CanvasAgentActions.describe(caller).nodes ?? []
        let selection = board.cards.filter { board.selection.contains($0.id) }
            .map { $0.id.rawValue.uuidString }
        let focus = board.focusedCardID?.rawValue.uuidString
        // Resolve node references ("this", a title) to one id, or stop.
        for key in nodeKeys {
            guard let ref = arguments[key] as? String else { continue }
            switch VoiceTargetResolver.resolve(
                ref: ref, nodes: nodes, selection: selection, focus: focus)
            {
            case .success(let id): arguments[key] = id
            case .failure(let error):
                return VoiceToolOutcome(output: error.agentJSON, summary: "unresolved \(key)")
            }
        }
        if let members = arguments["member_ids"] as? [String] {
            var resolved: [String] = []
            for ref in members {
                switch VoiceTargetResolver.resolve(
                    ref: ref, nodes: nodes, selection: selection, focus: focus)
                {
                case .success(let id): resolved.append(id)
                case .failure(let error):
                    return VoiceToolOutcome(output: error.agentJSON, summary: "unresolved member")
                }
            }
            arguments["member_ids"] = resolved
        }
        if let ref = arguments["near"] as? String {
            if case .success(let id) = VoiceTargetResolver.resolve(
                ref: ref, nodes: nodes, selection: selection, focus: focus)
            {
                arguments["near"] = id
            } else {
                arguments.removeValue(forKey: "near")
            }
        }
        // The voice card is not on the board, so a new node goes beside what
        // the user is looking at instead of the board's default spot.
        if let tool, placementTools.contains(tool), arguments["near"] == nil,
            arguments["x"] == nil, arguments["y"] == nil,
            let anchor = selection.count == 1 ? selection.first : focus
        {
            arguments["near"] = anchor
        }
        let call: CanvasAgentToolCall
        do {
            call = try CanvasAgentToolCall.parse(tool: name, arguments: arguments)
            try call.validate()
        } catch {
            return failure("invalid_arguments", error.message)
        }
        if call.tool == .ensembleDescribe {
            return describe(caller: caller, host: host)
        }
        let decision = VoicePolicy.decide(mode: board.agentControlMode, risk: call.risk)
        switch decision {
        case .deny(let reason):
            CanvasAgentCenter.shared.record(
                board.id, agent: caller.agentName, action: call.tool.actionTitle,
                outcome: "Blocked: Agent control is Off")
            return failure("agent_control_off", reason)
        case .confirm, .run, .runWithNotice:
            break
        }
        // The same 30-per-minute limit as an agent (`CanvasAgentActions.handle`):
        // a looping backend cannot flood the board.
        if call.risk != .read, !CanvasAgentCenter.shared.admit(host.callerID) {
            return failure("rate_limited", rateLimitedMessage)
        }
        if case .confirm = decision {
            let request = VoiceConfirmRequest(call: call, board: board)
            if !host.hasSessionGrant(request.grantKey) {
                if let refused = await askConfirm(request, call: call, caller: caller, host: host) {
                    return refused
                }
            }
        }
        let before = CanvasAgentProvenanceStore.Before(board)
        let connectionsBefore = before.connections.count
        let response = await CanvasAgentActions.perform(call, caller: caller)
        let changed = board.cards != before.cards || board.connections != before.connections
        if response.error == nil, call.risk != .read, changed {
            noteEffect(
                on: board, before: before.cards, connectionsBefore: connectionsBefore, host: host)
            if board.canUndo {
                host.undoLedger.record(board)
                if CanvasAgentNoticeText.verb(for: call) == nil {
                    // Links and builds leave no card mark; the notice still offers Undo.
                    showUndoNotice("Rafu (voice): \(call.tool.actionTitle)", board: board)
                }
            }
        }
        return outcome(response, call: call)
    }

    /// Shows the Confirm card and waits. Returns the error outcome when the
    /// call must not run; nil when the user allowed it.
    private static func askConfirm(
        _ request: VoiceConfirmRequest, call: CanvasAgentToolCall, caller: CanvasAgentCaller,
        host: any VoiceToolHost
    ) async -> VoiceToolOutcome? {
        let answer = await host.confirm(request)
        let refusal: (code: String, message: String, log: String)
        switch answer {
        case .allowOnce: return nil
        case .allowForSession:
            host.grantForSession(request.grantKey)
            return nil
        case .cancel: refusal = ("cancelled", cancelledMessage, "Cancelled by the user")
        case .timedOut: refusal = ("confirm_timeout", timedOutMessage, "Not confirmed in time")
        case .busy: return failure("confirm_busy", busyMessage)
        case .noWindow: refusal = ("no_window", noWindowMessage, "No window for the confirmation")
        }
        CanvasAgentCenter.shared.record(
            caller.board.id, agent: caller.agentName, action: call.tool.actionTitle,
            outcome: refusal.log)
        return failure(refusal.code, refusal.message)
    }

    private static func resolveConfirm(_ answer: VoiceConfirmAnswer, host: any VoiceToolHost)
        -> VoiceToolOutcome
    {
        switch host.resolveConfirm(answer) {
        case .resolved: break
        case .nothingPending: return failure("nothing_pending", nothingPendingMessage)
        case .notHeard: return failure("not_heard", notHeardMessage)
        }
        let message = answer == .cancel ? "Cancelled." : "Confirmed."
        return VoiceToolOutcome(
            output: VoiceJSON.object(["status": "ok", "message": .string(message)]).jsonString(),
            summary: answer == .cancel ? "cancel" : "confirm")
    }

    /// The set-down ring on every card voice added or changed (no haptic for
    /// voice), and a counts-only Board effects row on the timeline.
    static func noteEffect(
        on board: CanvasBoardState, before: [CanvasCard], connectionsBefore: Int,
        host: any VoiceToolHost
    ) {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = board.cards.filter { old[$0.id] == nil }.map(\.id)
        let changed = board.cards.filter { card in old[card.id].map { $0 != card } ?? false }
            .map(\.id)
        let kept = Set(board.cards.map(\.id))
        let removed = before.count(where: { !kept.contains($0.id) })
        let touched = added + changed
        if !touched.isEmpty { board.landing = CanvasLanding(ids: touched) }
        var parts: [String] = []
        if !added.isEmpty { parts.append("\(added.count) added") }
        if !changed.isEmpty { parts.append("\(changed.count) changed") }
        if removed > 0 { parts.append("\(removed) removed") }
        let links = board.connections.count - connectionsBefore
        if links != 0 { parts.append("links \(links > 0 ? "+" : "")\(links)") }
        if parts.isEmpty { parts.append("links changed") }
        host.noteBoardEffect(
            CanvasAgentText.singleLine(board.title, limit: 40),
            detail: parts.joined(separator: ", "))
    }

    private static func outcome(_ response: CanvasBridgeResponse, call: CanvasAgentToolCall)
        -> VoiceToolOutcome
    {
        if let error = response.error {
            return VoiceToolOutcome(output: VoiceJSON.toolError("failed", error), summary: "error")
        }
        let result = response.toolResult?.bounded(maximumBytes: CanvasAgentActions.resultBytes)
        let output =
            result?.agentJSON().map { String(decoding: $0, as: UTF8.self) }
            ?? "{\"status\":\"ok\"}"
        if call.tool == .noteRead {
            let bytes = result?.text?.utf8.count ?? 0
            let node = String((call.nodeID ?? "").prefix(8))
            return VoiceToolOutcome(output: output, summary: "note \(node), \(bytes) bytes")
        }
        return VoiceToolOutcome(output: output, summary: "ok")
    }

    private static func describe(caller: CanvasAgentCaller, host: any VoiceToolHost)
        -> VoiceToolOutcome
    {
        let board = caller.board
        let described = CanvasAgentActions.describe(caller)
        let shares = VoicePolicy.sharesTerminalTail(
            mode: board.agentControlMode, setting: host.voicePreferences.sharesTerminalTail)
        let tails = shares ? VoiceTerminalTail.tails(for: board, session: caller.session) : nil
        let context = VoiceBoardContext(
            ensemble: board.title, ensembleID: board.id.rawValue.uuidString,
            mode: board.agentControlMode, nodes: described.nodes ?? [],
            edges: described.edges ?? [],
            selection: board.cards.filter { board.selection.contains($0.id) }
                .map { $0.id.rawValue.uuidString },
            focus: board.focusedCardID?.rawValue.uuidString, persona: host.personaName,
            terminalTails: tails
        ).bounded()
        let output =
            context.agentJSON().map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        let summary: String
        if context.terminalTails != nil {
            let measure = context.tailMeasure
            summary =
                "\(context.nodes.count) nodes; tail: \(measure.lines) lines, \(measure.bytes) bytes"
        } else {
            summary = "\(context.nodes.count) nodes"
        }
        return VoiceToolOutcome(output: output, summary: summary)
    }

    static func showUndoNotice(_ message: String, board: CanvasBoardState) {
        let gate = CanvasAgentUndoGate(
            boardID: board.id, cards: board.cards, connections: board.connections)
        board.showNotice(
            message, tone: .info,
            action: CanvasBoardNotice.Action(title: "Undo") { [weak board] in
                guard let board, board.canUndo,
                    gate.allows(cards: board.cards, connections: board.connections)
                else { return }
                board.performUndo()
            })
        if let notice = board.notice {
            CanvasAgentProvenanceStore.shared.registerUndo(noticeID: notice.id, gate: gate)
        }
    }

    // MARK: Meta and view

    private static func voiceUndo(host: any VoiceToolHost) -> VoiceToolOutcome {
        guard let board = host.voiceTarget()?.board else {
            return failure("no_ensemble", noBoardMessage)
        }
        guard host.undoLedger.undo(on: board) else {
            return failure("nothing_to_undo", undoRefusedMessage)
        }
        return VoiceToolOutcome(
            output: VoiceJSON.object(["status": "ok", "message": "Undone."]).jsonString(),
            summary: "undo")
    }

    private static func viewDecision(_ board: CanvasBoardState, risk: CanvasAgentRisk)
        -> VoiceToolOutcome?
    {
        if case .deny(let reason) = VoicePolicy.decide(mode: board.agentControlMode, risk: risk) {
            return failure("agent_control_off", reason)
        }
        return nil
    }

    private static func viewZoom(_ arguments: [String: Any], host: any VoiceToolHost)
        -> VoiceToolOutcome
    {
        guard let board = host.voiceTarget()?.board else {
            return failure("no_ensemble", noBoardMessage)
        }
        if let refused = viewDecision(board, risk: .edit) { return refused }
        switch arguments["mode"] as? String ?? "fit" {
        case "fit": board.fitAll()
        case "selection": board.zoomToSelection()
        case "in": board.zoom(1.2)
        case "out": board.zoom(1 / 1.2)
        default: return failure("invalid_arguments", "mode must be fit, selection, in or out.")
        }
        return VoiceToolOutcome(
            output: VoiceJSON.object(["status": "ok"]).jsonString(), summary: "zoom")
    }

    private static func viewTidy(host: any VoiceToolHost) -> VoiceToolOutcome {
        guard let board = host.voiceTarget()?.board else {
            return failure("no_ensemble", noBoardMessage)
        }
        if let refused = viewDecision(board, risk: .edit) { return refused }
        guard CanvasAgentCenter.shared.admit(host.callerID) else {
            return failure("rate_limited", rateLimitedMessage)
        }
        let before = CanvasAgentProvenanceStore.Before(board)
        do {
            try board.arrange()
        } catch {
            return failure("failed", error.localizedDescription)
        }
        if board.cards != before.cards {
            noteEffect(
                on: board, before: before.cards, connectionsBefore: board.connections.count,
                host: host)
            if board.canUndo {
                host.undoLedger.record(board)
                showUndoNotice("Rafu (voice) tidied up", board: board)
            }
        }
        return VoiceToolOutcome(
            output: VoiceJSON.object(["status": "ok", "message": "Tidied and fitted."])
                .jsonString(),
            summary: "tidy")
    }

    // MARK: Orchestrator

    struct OpenBoard {
        let session: WorkspaceSession
        let board: CanvasBoardState
    }

    /// Every open Ensemble across windows, front window first.
    static func openBoards(in sessions: [WorkspaceSession]) -> [OpenBoard] {
        sessions.flatMap { session in
            session.canvas.boards.values
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                .map { OpenBoard(session: session, board: $0) }
        }
    }

    /// An open Ensemble by id, exact title, or leading title; never a guess.
    static func findOpenBoard(_ ref: String, in sessions: [WorkspaceSession])
        -> Result<OpenBoard, VoiceTargetError>
    {
        let boards = openBoards(in: sessions)
        let summaries = boards.map {
            CanvasAgentNodeSummary(
                id: $0.board.id.rawValue.uuidString, kind: "ensemble", title: $0.board.title,
                x: 0, y: 0, width: 0, height: 0)
        }
        switch VoiceTargetResolver.resolve(ref: ref, nodes: summaries, selection: [], focus: nil) {
        case .success(let id):
            guard let match = boards.first(where: { $0.board.id.rawValue.uuidString == id })
            else { return .failure(.notFound) }
            return .success(match)
        case .failure(let error): return .failure(error)
        }
    }

    private static func listEnsembles(host: any VoiceToolHost) async -> VoiceToolOutcome {
        let sessions = host.voiceWorkspaces()
        let front = host.voiceTarget()
        let open: [VoiceJSON] = openBoards(in: sessions).map { entry in
            let board = entry.board
            return .object([
                "id": .string(board.id.rawValue.uuidString),
                "title": .string(CanvasAgentText.singleLine(board.title, limit: 80)),
                "workspace": .string(entry.session.rootURL?.lastPathComponent ?? ""),
                "nodes": .integer(board.cards.count),
                "agent_control": .string(board.agentControlMode.rawValue),
                "visible": .bool(front?.board === board),
            ])
        }
        var saved: [VoiceJSON] = []
        if let session = front?.session {
            await session.prepareCanvasLibrary()
            let openIDs = Set(session.canvas.boards.keys)
            saved = session.canvas.library.filter { !openIDs.contains($0.id) }.prefix(20).map {
                .object([
                    "id": .string($0.id.rawValue.uuidString),
                    "title": .string(CanvasAgentText.singleLine($0.title, limit: 80)),
                    "nodes": .integer($0.cardCount),
                ])
            }
        }
        let output = VoiceJSON.object(["open": .array(open), "saved": .array(saved)]).jsonString()
        return VoiceToolOutcome(output: output, summary: "\(open.count) open, \(saved.count) saved")
    }

    private static func ensembleOpen(_ arguments: [String: Any], host: any VoiceToolHost) async
        -> VoiceToolOutcome
    {
        guard let ref = arguments["ensemble"] as? String, !ref.isEmpty else {
            return failure("invalid_arguments", "ensemble is required.")
        }
        switch findOpenBoard(ref, in: host.voiceWorkspaces()) {
        case .success(let found):
            WorkspaceWindowRegistry.shared.focus(session: found.session)
            found.session.presentCanvasBoard(found.board)
            return VoiceToolOutcome(
                output: VoiceJSON.object([
                    "status": "ok", "id": .string(found.board.id.rawValue.uuidString),
                ]).jsonString(),
                summary: "open")
        case .failure(.ambiguous(let titles)):
            return VoiceToolOutcome(
                output: VoiceTargetError.ambiguous(titles).agentJSON, summary: "ambiguous")
        case .failure(.notFound):
            break
        }
        guard let session = host.voiceTarget()?.session else {
            return failure("no_window", "No Rafu workspace window is open.")
        }
        await session.prepareCanvasLibrary()
        let saved = session.canvas.library.map {
            CanvasAgentNodeSummary(
                id: $0.id.rawValue.uuidString, kind: "ensemble", title: $0.title, x: 0, y: 0,
                width: 0, height: 0)
        }
        switch VoiceTargetResolver.resolve(ref: ref, nodes: saved, selection: [], focus: nil) {
        case .success(let id):
            guard
                let summary = session.canvas.library.first(where: {
                    $0.id.rawValue.uuidString == id
                })
            else { return failure("not_found", "No Ensemble matches.") }
            await session.openCanvas(summary.id)
            return VoiceToolOutcome(
                output: VoiceJSON.object(["status": "ok", "id": .string(id)]).jsonString(),
                summary: "open saved")
        case .failure(let error):
            return VoiceToolOutcome(output: error.agentJSON, summary: "not found")
        }
    }

    private static func ensembleCreate(_ arguments: [String: Any], host: any VoiceToolHost) async
        -> VoiceToolOutcome
    {
        guard
            let title = (arguments["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            CanvasDocument.validTitle(title)
        else {
            return failure("invalid_arguments", "A title of at most 120 characters is required.")
        }
        guard let session = host.voiceTarget()?.session else {
            return failure("no_window", "No Rafu workspace window is open.")
        }
        guard await session.createCanvas(named: title) else {
            return failure("failed", "Rafu could not create the Ensemble.")
        }
        let created = session.selectedCanvas
        var result: [String: VoiceJSON] = [
            "status": "ok",
            "message": .string(
                "Created and showing \(CanvasAgentText.singleLine(title, limit: 80))."),
        ]
        if let created { result["id"] = .string(created.id.rawValue.uuidString) }
        if arguments["alias"] != nil {
            result["alias"] = "Aliases are saved in a later version; it was not stored."
        }
        return VoiceToolOutcome(output: VoiceJSON.object(result).jsonString(), summary: "create")
    }

    /// A short digest of every open Ensemble, at most 2 KiB.
    static func crossBoardSummary(host: any VoiceToolHost) -> VoiceToolOutcome {
        var rows: [VoiceJSON] = []
        for entry in openBoards(in: host.voiceWorkspaces()) {
            let board = entry.board
            var kinds: [String: Int] = [:]
            var running = 0
            for card in board.cards {
                kinds[CanvasAgentKinds.kind(of: card.content), default: 0] += 1
                if case .terminal(let groupID) = card.content,
                    entry.session.terminal.terminalGroup(groupID)?.panes.first?.status == .live
                {
                    running += 1
                }
            }
            rows.append(
                .object([
                    "title": .string(CanvasAgentText.singleLine(board.title, limit: 60)),
                    "agent_control": .string(board.agentControlMode.rawValue),
                    "kinds": .object(kinds.mapValues { .integer($0) }),
                    "running_terminals": .integer(running),
                    "links": .integer(board.connections.count),
                ]))
        }
        var payload = VoiceJSON.object(["ensembles": .array(rows)])
        while payload.jsonString().utf8.count > 2_048, !rows.isEmpty {
            rows.removeLast()
            payload = .object(["ensembles": .array(rows), "truncated": true])
        }
        return VoiceToolOutcome(output: payload.jsonString(), summary: "\(rows.count) ensembles")
    }
}
