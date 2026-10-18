import AppKit
import Foundation
import Observation
import RafuCore

/// The per-Ensemble "Agent control" setting. Saved with the board through one
/// optional `CanvasDocument.agentControl` property; a board without it uses
/// the default, Ask.
nonisolated struct CanvasAgentControl: Codable, Equatable, Sendable {
    var mode: CanvasAgentControlMode

    init(mode: CanvasAgentControlMode = .ask) { self.mode = mode }
}

/// The terminal node that called a tool. It never holds the bridge token.
struct CanvasAgentCaller {
    let session: WorkspaceSession
    let board: CanvasBoardState
    let card: CanvasCard
    /// The terminal controller (runtime session) behind the caller's node.
    let controllerID: UUID
    let provider: String
    /// Sends one message over the caller's live message link (like `send_message`).
    let sendMessage:
        @MainActor (_ destination: String, _ text: String) async -> CanvasBridgeResponse

    var agentName: String {
        let vendor = provider == "codex" ? "Codex" : "Claude"
        return "\(vendor) — \(CanvasAgentText.singleLine(card.title, limit: 40))"
    }
}

enum CanvasAgentApprovalChoice: Equatable {
    case once
    case always
    case deny
}

/// One pending question. The approval panel shows it; nothing runs until the
/// user chooses.
@MainActor
final class CanvasAgentApproval: Identifiable {
    let id = UUID()
    let boardID: CanvasID
    let agentName: String
    let call: CanvasAgentToolCall
    let created: Date
    let controllerID: UUID
    fileprivate(set) var choice: CanvasAgentApprovalChoice?
    fileprivate var continuation: CheckedContinuation<Void, Never>?
    fileprivate let perform: @MainActor () async -> CanvasBridgeResponse

    var summary: [String] { call.approvalSummary }
    var allowsAlways: Bool { call.risk == .edit }

    fileprivate init(
        boardID: CanvasID, agentName: String, call: CanvasAgentToolCall, created: Date,
        controllerID: UUID, perform: @escaping @MainActor () async -> CanvasBridgeResponse
    ) {
        self.boardID = boardID
        self.agentName = agentName
        self.call = call
        self.created = created
        self.controllerID = controllerID
        self.perform = perform
    }
}

/// One line in the Ensemble's agent activity log. It names the agent, the
/// action and node titles; never note text, message bodies or commands' output.
struct CanvasAgentLogEntry: Identifiable, Equatable {
    let id = UUID()
    let boardID: CanvasID
    let date: Date
    let agent: String
    let action: String
    let outcome: String
}

/// Window-independent runtime state for agent actions. Nothing here is saved.
@Observable @MainActor
final class CanvasAgentCenter {
    static let shared = CanvasAgentCenter()

    private(set) var approvals: [CanvasAgentApproval] = []
    private(set) var log: [CanvasAgentLogEntry] = []
    @ObservationIgnored private var always: Set<String> = []
    @ObservationIgnored private var limiters: [UUID: CanvasAgentRateLimiter] = [:]
    @ObservationIgnored private var results:
        [UUID: (controllerID: UUID, date: Date, response: CanvasBridgeResponse)] = [:]
    /// Terminal nodes an agent created, so it may type into them later.
    @ObservationIgnored private var created: [CanvasCardID: (caller: UUID, agent: String?)] = [:]
    @ObservationIgnored let now: @MainActor () -> Date

    static let approvalWait: Duration = .seconds(12)
    static let maximumPendingPerBoard = 4
    static let retention: TimeInterval = 600

    init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

    func approvals(for board: CanvasID) -> [CanvasAgentApproval] {
        approvals.filter { $0.boardID == board }
    }

    func log(for board: CanvasID) -> [CanvasAgentLogEntry] {
        log.filter { $0.boardID == board }
    }

    func isAlwaysAllowed(_ tool: CanvasAgentTool, on board: CanvasID) -> Bool {
        always.contains(Self.grantKey(tool, board))
    }

    func forgetGrants(on board: CanvasID) {
        always = always.filter { !$0.hasSuffix(board.rawValue.uuidString) }
    }

    func admit(_ controllerID: UUID) -> Bool {
        var limiter = limiters[controllerID] ?? CanvasAgentRateLimiter()
        let admitted = limiter.admit(at: now())
        limiters[controllerID] = limiter
        return admitted
    }

    func record(_ board: CanvasID, agent: String, action: String, outcome: String) {
        log.append(
            CanvasAgentLogEntry(
                boardID: board, date: now(), agent: agent,
                action: CanvasAgentText.singleLine(action, limit: 120),
                outcome: CanvasAgentText.singleLine(outcome, limit: 160)))
        if log.count > 100 { log.removeFirst(log.count - 100) }
    }

    func noteCreatedTerminal(_ card: CanvasCardID, caller: UUID, agent: String?) {
        if created.count > 200 { created.removeAll() }
        created[card] = (caller, agent)
    }

    func creator(of card: CanvasCardID) -> (caller: UUID, agent: String?)? { created[card] }

    /// Adds a question and waits briefly for the user. Returns the choice, or
    /// nil when the wait ended first; the question then stays open.
    func ask(
        board: CanvasID, caller: CanvasAgentCaller, call: CanvasAgentToolCall,
        perform: @escaping @MainActor () async -> CanvasBridgeResponse
    ) async -> (approval: CanvasAgentApproval?, choice: CanvasAgentApprovalChoice?) {
        prune()
        guard approvals(for: board).count < Self.maximumPendingPerBoard else {
            return (nil, nil)
        }
        let approval = CanvasAgentApproval(
            boardID: board, agentName: caller.agentName, call: call, created: now(),
            controllerID: caller.controllerID, perform: perform)
        approvals.append(approval)
        await withCheckedContinuation { continuation in
            approval.continuation = continuation
            Task { [weak approval] in
                try? await Task.sleep(for: Self.approvalWait)
                guard let approval, let waiting = approval.continuation else { return }
                approval.continuation = nil
                waiting.resume()
            }
        }
        return (approval, approval.choice)
    }

    /// The user's answer. A late answer runs the action now and keeps its
    /// result for `action_status`.
    func decide(_ id: UUID, _ choice: CanvasAgentApprovalChoice) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let approval = approvals.remove(at: index)
        approval.choice = choice
        if choice == .always, approval.allowsAlways {
            always.insert(Self.grantKey(approval.call.tool, approval.boardID))
        }
        if let waiting = approval.continuation {
            approval.continuation = nil
            waiting.resume()
            return
        }
        Task {
            let response =
                choice == .deny
                ? CanvasBridgeResponse(error: CanvasAgentActions.deniedMessage)
                : await approval.perform()
            store(response, for: approval.id, controllerID: approval.controllerID)
        }
    }

    func store(_ response: CanvasBridgeResponse, for id: UUID, controllerID: UUID) {
        results = results.filter { now().timeIntervalSince($0.value.date) < Self.retention }
        if results.count >= 32, let oldest = results.min(by: { $0.value.date < $1.value.date }) {
            results.removeValue(forKey: oldest.key)
        }
        results[id] = (controllerID, now(), response)
    }

    func status(of id: UUID, for controllerID: UUID) -> CanvasBridgeResponse {
        if let result = results[id], result.controllerID == controllerID {
            return result.response
        }
        if approvals.contains(where: { $0.id == id && $0.controllerID == controllerID }) {
            var pending = CanvasAgentToolResult(
                status: .pendingApproval, message: CanvasAgentActions.pendingMessage)
            pending.requestID = id.uuidString
            return CanvasBridgeResponse(toolResult: pending)
        }
        return CanvasBridgeResponse(error: "No action matches that request_id.")
    }

    /// Questions expire after ten minutes; an expired question is a denial.
    private func prune() {
        let current = now()
        let expired = approvals.filter {
            current.timeIntervalSince($0.created) > Self.retention
        }
        for approval in expired { decide(approval.id, .deny) }
    }

    private static func grantKey(_ tool: CanvasAgentTool, _ board: CanvasID) -> String {
        "\(tool.rawValue)|\(board.rawValue.uuidString)"
    }
}

/// The app side of the orchestration tools. Every mutation goes through the
/// board's undoable `edit`, the note's own undo, or the existing terminal
/// machinery, and appears on the visible Ensemble.
@MainActor
enum CanvasAgentActions {
    static let deniedMessage = "The user denied this action in Rafu. Do not retry it."
    static let pendingMessage =
        "Waiting for the user to approve this action in Rafu. Call action_status with this request_id later."
    static let hiddenMessage =
        "Open this Ensemble in Rafu to let agents change it. Reading still works."
    static let resultBytes = 24 * 1_024

    static func handle(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) async
        -> CanvasBridgeResponse
    {
        do { try call.validate() } catch { return .init(error: error.message) }
        let center = CanvasAgentCenter.shared
        if call.tool == .actionStatus, let id = call.requestID.flatMap(UUID.init(uuidString:)) {
            return center.status(of: id, for: caller.controllerID)
        }
        let board = caller.board
        var risk = call.risk
        let routedByLink: Bool =
            if call.tool == .terminalSend, call.text != nil, let node = call.nodeID {
                CanvasLiveBridge.shared.hasLiveRoute(
                    from: caller.controllerID, to: node)
            } else {
                false
            }
        if routedByLink { risk = .edit }
        if risk != .read {
            guard caller.session.canvasResources[board.id]?.isPresented == true else {
                return .init(error: hiddenMessage)
            }
            guard center.admit(caller.controllerID) else {
                return .init(error: "Too many Ensemble changes. Wait one minute.")
            }
        }
        var decision = CanvasAgentPolicy.decide(
            mode: board.agentControlMode, risk: risk,
            alwaysAllowed: center.isAlwaysAllowed(call.tool, on: board.id))
        // A Live message link is the user's consent for messages, like send_message.
        if routedByLink, decision == .ask { decision = .allow }
        switch decision {
        case .deny(let reason):
            center.record(
                board.id, agent: caller.agentName, action: call.tool.actionTitle,
                outcome: "Blocked: Agent control is Off")
            return .init(error: reason)
        case .allow:
            return await perform(call, caller: caller)
        case .ask:
            let (approval, choice) = await center.ask(board: board.id, caller: caller, call: call) {
                await perform(call, caller: caller)
            }
            guard let approval else {
                return .init(error: "Too many actions are waiting for approval in Rafu.")
            }
            switch choice {
            case .once, .always: return await approval.perform()
            case .deny:
                center.record(
                    board.id, agent: caller.agentName, action: call.tool.actionTitle,
                    outcome: "Denied by the user")
                return .init(error: deniedMessage)
            case nil:
                var pending = CanvasAgentToolResult(
                    status: .pendingApproval, message: pendingMessage)
                pending.requestID = approval.id.uuidString
                return .init(toolResult: pending)
            }
        }
    }

    /// Runs an allowed call and records it in the activity log.
    static func perform(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) async
        -> CanvasBridgeResponse
    {
        // A late approval can arrive after the user hid the board or turned
        // Agent control off. Check again right before the change.
        if call.risk != .read {
            guard caller.session.canvasResources[caller.board.id]?.isPresented == true else {
                return .init(error: hiddenMessage)
            }
            guard caller.board.agentControlMode != .off else {
                return .init(error: CanvasAgentPolicy.offMessage)
            }
        }
        let response: CanvasBridgeResponse
        do {
            response = try await execute(call, caller: caller)
        } catch let error as CanvasAgentToolError {
            response = .init(error: error.message)
        } catch {
            response = .init(
                error: (error as? LocalizedError)?.errorDescription
                    ?? "The Ensemble action failed.")
        }
        if call.risk != .read {
            CanvasAgentCenter.shared.record(
                caller.board.id, agent: caller.agentName, action: call.tool.actionTitle,
                outcome: response.error.map { "Failed: \($0)" } ?? response.toolResult?.message
                    ?? "Done")
        }
        return response
    }

    // MARK: Dispatch

    private static func execute(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        let board = caller.board
        switch call.tool {
        case .ensembleDescribe: return .init(toolResult: describe(caller))
        case .noteRead: return try noteRead(call, board: board)
        case .noteWrite: return try noteWrite(call, caller: caller)
        case .noteCreate:
            var create = call
            create.kind = "note"
            return try await nodeCreate(create, caller: caller)
        case .nodeCreate: return try await nodeCreate(call, caller: caller)
        case .nodeUpdate: return try nodeUpdate(call, board: board)
        case .nodeRemove: return try nodeRemove(call, caller: caller)
        case .terminalCreate: return try await terminalCreate(call, caller: caller)
        case .terminalStart: return try await terminalStart(call, caller: caller)
        case .terminalSend: return try await terminalSend(call, caller: caller)
        case .edgeCreate: return try edgeCreate(call, board: board)
        case .edgeRemove: return try edgeRemove(call, board: board)
        case .linkSetState: return try linkSetState(call, board: board)
        case .appOpen: return try await appOpen(call, caller: caller)
        case .appInspect: return try await appInspect(call, board: board)
        case .mermaidSet: return try mermaidSet(call, board: board)
        case .iconSearch: return iconSearch(call)
        case .frameCreate: return try frameCreate(call, caller: caller)
        case .export: return try await export(call, caller: caller)
        case .diagramBuild: return try diagramBuild(call, caller: caller)
        case .actionStatus: return .init(error: "No action matches that request_id.")
        }
    }

    private static func ok(_ message: String, node: CanvasCardID? = nil, edge: UUID? = nil)
        -> CanvasBridgeResponse
    {
        var result = CanvasAgentToolResult(message: message)
        result.nodeID = node?.rawValue.uuidString
        result.edgeID = edge?.uuidString
        return .init(toolResult: result)
    }

    private static func findCard(_ id: String?, in board: CanvasBoardState) throws -> CanvasCard {
        guard let id, let uuid = UUID(uuidString: id),
            let card = board.cards.first(where: { $0.id.rawValue == uuid })
        else { throw CanvasAgentToolError.invalidArgument("node_id") }
        return card
    }

    // MARK: Describe

    static func describe(_ caller: CanvasAgentCaller) -> CanvasAgentToolResult {
        let board = caller.board
        let session = caller.session
        let bridge = CanvasLiveBridge.shared
        var result = CanvasAgentToolResult()
        result.ensemble = board.title
        result.agentControl = board.agentControlMode.rawValue
        result.callerNodeID = caller.card.id.rawValue.uuidString
        result.nodes = board.cards.map { card in
            var state: String?
            var agent: String?
            var path: String?
            switch card.content {
            case .terminal(let groupID):
                let pane = session.terminal.terminalGroup(groupID)?.panes.first
                state = pane.map { terminalState($0.status) } ?? "unavailable"
                agent = pane?.sessionID.flatMap { bridge.connectedProvider(controllerID: $0) }
                if agent == nil, let creator = CanvasAgentCenter.shared.creator(of: card.id) {
                    agent = creator.agent
                }
            case .file(let value), .image(let value): path = value
            case .nativeApp(let bundleID): path = bundleID
            case .web(let destination): path = destination.address
            default: break
            }
            return CanvasAgentNodeSummary(
                id: card.id.rawValue.uuidString, kind: CanvasAgentKinds.kind(of: card.content),
                title: card.title, x: card.rect.x, y: card.rect.y, width: card.rect.width,
                height: card.rect.height, state: state, agent: agent, path: path)
        }
        let states = bridge.linkStates(in: board)
        result.edges = board.connections.map { edge in
            CanvasAgentEdgeSummary(
                id: edge.id.uuidString, from: edge.from.rawValue.uuidString,
                to: edge.to.rawValue.uuidString,
                kind: edge.isMessageLink ? "message" : "relationship", label: edge.customLabel,
                state: edge.isMessageLink
                    ? (states[edge.id]?.word.lowercased() ?? "paused") : "related")
        }
        return result.bounded(maximumBytes: resultBytes)
    }

    private static func terminalState(_ status: TerminalPaneStatus) -> String {
        switch status {
        case .idle: "idle"
        case .live: "running"
        case .exited: "exited"
        case .stopped: "stopped"
        case .unavailable: "unavailable"
        }
    }

    // MARK: Notes

    private static func noteText(_ card: CanvasCard, board: CanvasBoardState) throws -> String {
        guard case .note(let snapshot) = card.content else {
            throw CanvasAgentToolError.invalidArgument("node_id")
        }
        if let live = board.noteSnapshots[card.id] { return try live() }
        return snapshot
    }

    private static func noteRead(_ call: CanvasAgentToolCall, board: CanvasBoardState) throws
        -> CanvasBridgeResponse
    {
        let card = try findCard(call.nodeID, in: board)
        let text = try noteText(card, board: board)
        let slice = CanvasAgentNoteEditor.slice(
            text, offset: call.offset ?? 0,
            length: call.length ?? CanvasAgentToolCall.maximumNoteSliceScalars)
        var result = CanvasAgentToolResult()
        result.nodeID = card.id.rawValue.uuidString
        result.text = slice.text
        result.offset = call.offset ?? 0
        result.totalLength = slice.total
        result.truncated = slice.truncated
        return .init(toolResult: result.bounded(maximumBytes: resultBytes))
    }

    private static func noteWrite(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) throws
        -> CanvasBridgeResponse
    {
        let board = caller.board
        let card = try findCard(call.nodeID, in: board)
        guard let text = call.text,
            let mode = call.mode.flatMap(CanvasAgentNoteMode.init(rawValue:))
        else {
            throw CanvasAgentToolError.missingArgument("text")
        }
        let existing = try noteText(card, board: board)
        let edit = try CanvasAgentNoteEditor.edit(
            existing, mode: mode, text: text, heading: call.heading,
            limit: CanvasLimits.noteBytes)
        if let buffer = caller.session.canvasResources[board.id]?.note(for: card) {
            // The note's own undo manager records the change, like typing.
            guard
                buffer.replace(
                    NSRange(location: edit.location, length: edit.length), with: edit.replacement,
                    actionName: "Agent Note Edit")
            else { throw CanvasAgentToolError.noteTooLarge }
        } else {
            try board.edit { document in
                guard let index = document.cards.firstIndex(where: { $0.id == card.id }) else {
                    return
                }
                document.cards[index].content = .note(snapshot: edit.result)
            }
        }
        board.select([card.id])
        return ok(
            "Note \"\(card.title)\" updated (\(edit.result.utf8.count) bytes).", node: card.id)
    }

    // MARK: Nodes

    private static func defaultSize(for kind: String) -> (Double, Double) {
        switch kind {
        case "terminal", "web": (640, 420)
        case "service_icon": (160, 128)
        case "text": (200, 80)
        case "shape": (200, 140)
        case "frame": (520, 360)
        default: (380, 260)
        }
    }

    /// A free rect: at (x, y) when given, to the right of `near` (default: the
    /// caller's node), stepping down past other nodes.
    static func placement(
        _ call: CanvasAgentToolCall, kind: String, caller: CanvasAgentCaller
    ) -> CanvasRect {
        let board = caller.board
        let (width, height) = defaultSize(for: kind)
        var rect = CanvasRect(
            x: 40, y: 40, width: call.width ?? width, height: call.height ?? height)
        if let x = call.x, let y = call.y {
            rect.x = x - rect.width / 2
            rect.y = y - rect.height / 2
        } else {
            let anchor =
                call.near.flatMap(UUID.init(uuidString:)).flatMap { id in
                    board.cards.first { $0.id.rawValue == id }
                }
                ?? board.cards.first { $0.id == caller.card.id }
            if let anchor {
                rect.x = anchor.rect.x + anchor.rect.width + 48
                rect.y = anchor.rect.y
            }
            for _ in 0..<12 {
                let blocked = board.cards.contains { other in
                    rect.x < other.rect.x + other.rect.width && other.rect.x < rect.x + rect.width
                        && rect.y < other.rect.y + other.rect.height
                        && other.rect.y < rect.y + rect.height
                }
                guard blocked else { break }
                rect.y += 48 + min(rect.height, 400)
            }
        }
        rect.x = min(50_000 - rect.width, max(-50_000, rect.x.rounded()))
        rect.y = min(50_000 - rect.height, max(-50_000, rect.y.rounded()))
        return rect
    }

    private static func insert(_ card: CanvasCard, into board: CanvasBoardState) throws {
        guard board.cards.count < CanvasLimits.cards else { throw CanvasError.capacity }
        try board.edit { $0.cards.append(card) }
        board.select([card.id])
    }

    private static func nodeCreate(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        guard let kind = call.kind else { throw CanvasAgentToolError.missingArgument("kind") }
        let session = caller.session
        let content: CanvasCardContent
        var title = call.title
        switch kind {
        case "terminal":
            return try await terminalCreate(call, caller: caller)
        case "frame":
            return try frameCreate(call, caller: caller)
        case "note":
            content = .note(snapshot: call.text ?? "")
        case "file", "image":
            guard let root = session.rootURL,
                let path = call.path.flatMap({
                    CanvasAgentPaths.normalizedRelative($0, allowRoot: false)
                })
            else { throw CanvasAgentToolError.invalidArgument("path") }
            let checked = try await workspaceFile(path, root: root)
            content = kind == "file" ? .file(path: checked) : .image(path: checked)
            title = title ?? URL(fileURLWithPath: checked).lastPathComponent
        case "web":
            guard let url = call.url else { throw CanvasAgentToolError.missingArgument("url") }
            let destination = try CanvasWebDestination(url)
            content = .web(destination: destination)
            title = title ?? destination.address
        case "app":
            let app = try await resolveApp(bundleID: call.bundleID, name: call.appName)
            content = .nativeApp(bundleID: app.bundleID)
            title = title ?? app.name
        case "service_icon":
            guard let packID = call.packID, let iconID = call.iconID else {
                throw CanvasAgentToolError.missingArgument("icon_id")
            }
            let label = call.label ?? call.title ?? iconID
            content = CanvasAgentKinds.serviceIcon(packID: packID, iconID: iconID, label: label)
            title = title ?? label
        default:
            let text = call.text ?? call.title
            if let limit = CanvasAgentKinds.textLimit(kind: kind),
                let text, text.utf8.count > limit
            {
                throw CanvasAgentToolError.textTooLarge(kilobytes: limit / 1_024)
            }
            content = CanvasAgentKinds.whiteboard(kind: kind, text: text, shape: call.shape)
        }
        let name = String((title ?? defaultTitle(kind, board: caller.board)).prefix(120))
        let card = CanvasCard(
            title: name, rect: placement(call, kind: kind, caller: caller), content: content)
        try insert(card, into: caller.board)
        return ok("Added \(kind) \"\(name)\".", node: card.id)
    }

    private static func defaultTitle(_ kind: String, board: CanvasBoardState) -> String {
        let label =
            switch kind {
            case "mermaid": "Diagram"
            case "shape": "Shape"
            case "text": "Text"
            default: "Note"
            }
        return "\(label) \(board.cards.count + 1)"
    }

    @concurrent
    private static func workspaceFile(_ path: String, root: URL) async throws -> String {
        let checked = try await CanvasPreviewLoader.relativePath(
            for: root.appending(path: path), root: root)
        let values = try root.appending(path: checked).resourceValues(forKeys: [
            .isRegularFileKey
        ])
        guard values.isRegularFile == true else { throw CanvasError.invalidPath }
        return checked
    }

    private static func nodeUpdate(_ call: CanvasAgentToolCall, board: CanvasBoardState) throws
        -> CanvasBridgeResponse
    {
        let card = try findCard(call.nodeID, in: board)
        try board.edit { document in
            guard let index = document.cards.firstIndex(where: { $0.id == card.id }) else {
                return
            }
            if let title = call.title { document.cards[index].title = title }
            if let x = call.x { document.cards[index].rect.x = x }
            if let y = call.y { document.cards[index].rect.y = y }
            if let width = call.width { document.cards[index].rect.width = width }
            if let height = call.height { document.cards[index].rect.height = height }
            guard document.cards[index].rect.isValid else {
                throw CanvasAgentToolError.invalidArgument("width")
            }
        }
        board.select([card.id])
        return ok("Updated \"\(call.title ?? card.title)\".", node: card.id)
    }

    private static func nodeRemove(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) throws
        -> CanvasBridgeResponse
    {
        let board = caller.board
        let card = try findCard(call.nodeID, in: board)
        guard card.id != caller.card.id else {
            throw CanvasAgentToolError.invalidArgument("node_id")
        }
        board.select([card.id])
        if case .terminal = card.content {
            // The ordinary close path: a running process gets the usual confirmation.
            caller.session.closeCanvasTerminalCard(board.id)
        } else {
            caller.session.removeCanvasCards(board.id)
        }
        return ok("Removed \"\(card.title)\". Edit > Undo restores it.", node: card.id)
    }

    // MARK: Terminals

    private static func terminalCreate(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        let session = caller.session
        let board = caller.board
        guard board.cards.count < CanvasLimits.cards else { throw CanvasError.capacity }
        let folder = try await startingFolder(call.cwd, session: session)
        let vendor = call.agent.map { CanvasAgentKinds.displayName(agent: $0) }
        let requested = call.title ?? vendor ?? "Terminal"
        guard
            let name = TerminalGroupName(String(requested.prefix(80)))
                ?? TerminalGroupName("Terminal")
        else { throw CanvasAgentToolError.invalidArgument("title") }
        let paneID = SavedTerminalPaneID()
        let pane = try SavedTerminalPaneRecord(
            id: paneID, explicitUserName: nil, themeColor: nil, kind: .ordinaryShell,
            launchProfile: .init(shell: .preferredShell, startingFolder: folder))
        let record = try SavedTerminalGroupRecord(
            id: SavedTerminalGroupID(), name: name, root: .pane(paneID), focusedPaneID: paneID,
            panes: [pane])
        let snapshot = try session.terminal.insertStoppedSavedGroup(record)
        _ = try session.terminal.perform(.detachDeletedSavedLayout(record.id))
        _ = try session.terminal.perform(.parkGroup(snapshot.id))
        var placed = call
        placed.width = placed.width ?? 640
        placed.height = placed.height ?? 420
        let card = CanvasCard(
            title: snapshot.name.rawValue,
            rect: placement(placed, kind: "terminal", caller: caller),
            content: .terminal(groupID: snapshot.id))
        try insert(card, into: board)
        CanvasAgentCenter.shared.noteCreatedTerminal(
            card.id, caller: caller.controllerID, agent: call.agent)
        guard call.startsProcess else {
            return ok("Added a stopped terminal \"\(card.title)\".", node: card.id)
        }
        let argv =
            call.command
            ?? call.agent.flatMap { CanvasAgentLaunch.argv(agent: $0, prompt: call.prompt) }
        guard let argv, let line = CanvasAgentShell.commandLine(argv) else {
            throw CanvasAgentToolError.invalidArgument("command")
        }
        try start(card, line: line, caller: caller)
        let next =
            call.agent == "claude" || call.agent == "codex"
            ? " Next: edge_create kind message to it, then link_set_state live." : ""
        return ok(
            "Starting \"\(card.title)\". Rafu types this line when the shell is ready: \(line).\(next)",
            node: card.id)
    }

    /// Validates a starting folder inside the workspace after resolving links.
    private static func startingFolder(_ cwd: String?, session: WorkspaceSession) async throws
        -> TerminalWorkspaceRelativePath
    {
        guard let cwd, let path = CanvasAgentPaths.normalizedRelative(cwd, allowRoot: true),
            path != "."
        else { return .root }
        guard let root = session.rootURL else { throw CanvasError.invalidPath }
        let checked = try await workspaceDirectory(path, root: root)
        guard let folder = TerminalWorkspaceRelativePath(checked) else {
            throw CanvasAgentToolError.invalidArgument("cwd")
        }
        return folder
    }

    @concurrent
    private static func workspaceDirectory(_ path: String, root: URL) async throws -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = base.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw CanvasError.invalidPath }
        let values = try target.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw CanvasError.invalidPath }
        return String(target.path.dropFirst(base.path.count + 1))
    }

    private static func terminalStart(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        let card = try findCard(call.nodeID, in: caller.board)
        try start(card, line: nil, caller: caller)
        return ok("Started \"\(card.title)\".", node: card.id)
    }

    /// Starts the visible terminal node through its own Start path. A line is
    /// typed once the shell process exists; that wait runs after the reply so
    /// the agent's bridge call never outlasts its IPC timeout.
    private static func start(_ card: CanvasCard, line: String?, caller: CanvasAgentCaller)
        throws
    {
        guard case .terminal(let groupID) = card.content else {
            throw CanvasAgentToolError.invalidArgument("node_id")
        }
        let session = caller.session
        guard let pane = session.terminal.terminalGroup(groupID)?.panes.first else {
            throw CanvasError.unavailable
        }
        if pane.status == .stopped || pane.status == .exited {
            caller.board.terminalStartRequest = card.id
        }
        guard let line else { return }
        let boardID = caller.board.id
        let agent = caller.agentName
        let title = card.title
        Task(name: "Type agent line into Ensemble terminal") { [weak session] in
            guard let session else { return }
            let typed = await Self.typeLine(line, into: groupID, session: session)
            if !typed {
                CanvasAgentCenter.shared.record(
                    boardID, agent: agent, action: "Type into a terminal",
                    outcome: "Failed: \"\(title)\" did not start in time")
            }
        }
    }

    /// A bounded wait (at most ten seconds) for the card's shell, then one line.
    private static func typeLine(
        _ line: String, into groupID: TerminalGroupID, session: WorkspaceSession
    ) async -> Bool {
        for attempt in 0..<100 {
            if let current = session.terminal.terminalGroup(groupID)?.panes.first,
                let controller = session.terminal.terminalController(for: current.id),
                current.status == .live,
                CanvasLiveBridge.shared.hasBootstrap(controllerID: controller.id) || attempt >= 40
            {
                // The PTY buffers the line until the shell reads it.
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(300)) }
                if controller.sendReply(line) { return true }
            }
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return false }
        }
        return false
    }

    private static func terminalSend(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        let card = try findCard(call.nodeID, in: caller.board)
        guard case .terminal = card.content else {
            throw CanvasAgentToolError.invalidArgument("node_id")
        }
        if let text = call.text,
            CanvasLiveBridge.shared.hasLiveRoute(
                from: caller.controllerID, to: card.id.rawValue.uuidString)
        {
            let response = await caller.sendMessage(card.id.rawValue.uuidString, text)
            if let error = response.error { return .init(error: error) }
            return ok("Message sent over the Live link to \"\(card.title)\".", node: card.id)
        }
        guard let creator = CanvasAgentCenter.shared.creator(of: card.id),
            creator.caller == caller.controllerID
        else {
            return .init(
                error:
                    "Connect a Live message link to that terminal, or type only into terminals you created."
            )
        }
        let line: String
        if let command = call.command {
            guard let quoted = CanvasAgentShell.commandLine(command) else {
                throw CanvasAgentToolError.invalidArgument("command")
            }
            line = quoted
        } else {
            guard creator.agent != nil, let text = call.text else {
                return .init(
                    error: "This is a shell terminal. Send command as an argument array.")
            }
            line = CanvasAgentText.singleLine(text, limit: CanvasAgentToolCall.maximumPromptBytes)
        }
        try start(card, line: line, caller: caller)
        return ok("Typing into \"\(card.title)\".", node: card.id)
    }

    // MARK: Edges

    private static func edgeCreate(_ call: CanvasAgentToolCall, board: CanvasBoardState) throws
        -> CanvasBridgeResponse
    {
        let from = try findCard(call.from, in: board)
        let to = try findCard(call.to, in: board)
        let message = call.kind == "message"
        if message {
            guard case .terminal = from.content, case .terminal = to.content else {
                throw CanvasAgentToolError.invalidArgument("kind")
            }
        }
        if let existing = board.connections.first(where: {
            ($0.from == from.id && $0.to == to.id || $0.from == to.id && $0.to == from.id)
                && $0.isMessageLink == message
        }) {
            return ok("That link already exists.", edge: existing.id)
        }
        let behavior: CanvasConnectionBehavior = message ? .session : .related
        let connection = CanvasConnection(
            from: from.id, to: to.id,
            label: call.label ?? CanvasConnection.placeholderLabel(for: behavior),
            behavior: behavior)
        guard board.connections.count < CanvasLimits.connections else {
            throw CanvasError.capacity
        }
        try board.edit { $0.connections.append(connection) }
        return ok(
            message
                ? "Added a Paused message link. Call link_set_state live to deliver messages."
                : "Added a relationship link.", edge: connection.id)
    }

    private static func findEdge(_ id: String?, in board: CanvasBoardState) throws
        -> CanvasConnection
    {
        guard let id, let uuid = UUID(uuidString: id), let edge = board.connection(uuid) else {
            throw CanvasAgentToolError.invalidArgument("edge_id")
        }
        return edge
    }

    private static func edgeRemove(_ call: CanvasAgentToolCall, board: CanvasBoardState) throws
        -> CanvasBridgeResponse
    {
        let edge = try findEdge(call.edgeID, in: board)
        try board.edit { $0.connections.removeAll { $0.id == edge.id } }
        return ok("Removed the link. Edit > Undo restores it.", edge: edge.id)
    }

    private static func linkSetState(_ call: CanvasAgentToolCall, board: CanvasBoardState) throws
        -> CanvasBridgeResponse
    {
        let edge = try findEdge(call.edgeID, in: board)
        guard edge.isMessageLink else { throw CanvasAgentToolError.invalidArgument("edge_id") }
        if call.state == "live" {
            CanvasLiveBridge.shared.resume(edge.id, in: board)
        } else {
            CanvasLiveBridge.shared.pause(edge.id, in: board)
        }
        let state = CanvasLiveBridge.shared.linkState(of: edge, in: board)
        var message = "The link is \(state.word.lowercased())."
        if call.state == "live", state.kind != .live {
            message += " It turns Live when both terminals run claude or codex."
        }
        return ok(message, edge: edge.id)
    }

    // MARK: Apps

    private static func appOpen(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        let app = try await resolveApp(bundleID: call.bundleID, name: call.appName)
        let board = caller.board
        let card: CanvasCard
        if let existing = board.cards.first(where: {
            $0.content == .nativeApp(bundleID: app.bundleID)
        }) {
            card = existing
            board.select([card.id])
        } else {
            card = CanvasCard(
                title: String(app.name.prefix(120)),
                rect: placement(call, kind: "app", caller: caller),
                content: .nativeApp(bundleID: app.bundleID))
            try insert(card, into: board)
        }
        let docked = await CanvasAgentKinds.open(
            bundleID: app.bundleID, card: card.id, session: caller.session)
        return ok(
            docked
                ? "Opened \(app.name) and docked it in node \"\(card.title)\". Use app_inspect to read its window."
                : "Opened \(app.name). It is not docked in node \"\(card.title)\": the user must allow Rafu in System Settings > Privacy & Security > Accessibility, then choose Dock in the node.",
            node: card.id)
    }

    private struct ResolvedApp {
        let url: URL
        let name: String
        let bundleID: String
    }

    private static func resolveApp(bundleID: String?, name: String?) async throws -> ResolvedApp {
        var url: URL?
        if let bundleID {
            url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        } else if let name {
            let folders = [
                "/Applications", "/Applications/Utilities", "/System/Applications",
                "/System/Applications/Utilities",
                "/Applications/Xcode.app/Contents/Developer/Applications",
            ]
            url = folders.map { URL(fileURLWithPath: $0).appending(path: "\(name).app") }
                .first { FileManager.default.fileExists(atPath: $0.path) }
        }
        guard let url else { throw CanvasAgentToolError.invalidArgument("bundle_id") }
        let identity = try await CanvasPreviewLoader.appIdentity(url)
        return ResolvedApp(url: url, name: identity.name, bundleID: identity.bundleID)
    }

    private static func appInspect(_ call: CanvasAgentToolCall, board: CanvasBoardState)
        async throws -> CanvasBridgeResponse
    {
        let card = try findCard(call.nodeID, in: board)
        guard case .nativeApp = card.content else {
            throw CanvasAgentToolError.invalidArgument("node_id")
        }
        guard let summary = await CanvasAgentKinds.inspect(card.id) else {
            return .init(
                error:
                    "Rafu cannot read this app yet. The user must allow Rafu in System Settings > Privacy & Security > Accessibility, and the app window must be docked in the node."
            )
        }
        var result = CanvasAgentToolResult()
        result.nodeID = card.id.rawValue.uuidString
        result.text = summary
        return .init(toolResult: result.bounded(maximumBytes: resultBytes))
    }

    // MARK: Diagrams

    private static func mermaidSet(_ call: CanvasAgentToolCall, board: CanvasBoardState) throws
        -> CanvasBridgeResponse
    {
        let card = try findCard(call.nodeID, in: board)
        guard CanvasAgentKinds.isMermaid(card.content), let source = call.text else {
            throw CanvasAgentToolError.invalidArgument("node_id")
        }
        try board.edit { document in
            guard let index = document.cards.firstIndex(where: { $0.id == card.id }) else {
                return
            }
            document.cards[index].content = CanvasAgentKinds.mermaid(source)
        }
        board.select([card.id])
        return ok("Diagram \"\(card.title)\" updated.", node: card.id)
    }

    private static func iconSearch(_ call: CanvasAgentToolCall) -> CanvasBridgeResponse {
        var result = CanvasAgentToolResult()
        result.icons = CanvasAgentKinds.searchIcons(call.query ?? "", limit: call.limit ?? 20)
        if result.icons?.isEmpty != false {
            result.message =
                "No icon matches. Try a shorter word, or ask the user to import an icon pack."
        }
        return .init(toolResult: result.bounded(maximumBytes: resultBytes))
    }

    private static func frameCreate(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) throws
        -> CanvasBridgeResponse
    {
        let board = caller.board
        let members = try (call.memberIDs ?? []).map { try findCard($0, in: board).id }
        guard let title = call.title,
            let frame = CanvasAgentKinds.createFrame(
                title: title, members: members, board: board, session: caller.session)
        else { throw CanvasError.capacity }
        return ok("Added frame \"\(title)\".", node: frame)
    }

    private static func export(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        async throws -> CanvasBridgeResponse
    {
        let board = caller.board
        var frame: CanvasCardID?
        if call.target == "frame" { frame = try findCard(call.frameID, in: board).id }
        let url = try await CanvasAgentKinds.export(
            board: board.id, target: call.target ?? "board", frame: frame,
            format: call.format ?? "png", scale: call.scale ?? 2, seconds: call.seconds ?? 3,
            fps: call.fps ?? 12, session: caller.session)
        guard let root = caller.session.rootURL else { throw CanvasError.invalidPath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard target.hasPrefix(base) else { throw CanvasError.invalidPath }
        var result = CanvasAgentToolResult(message: "Exported.")
        result.path = String(target.dropFirst(base.count))
        return .init(toolResult: result)
    }

    /// Adds every node and link of the spec in one undoable edit. A frame,
    /// when requested, is a second step through the diagram service.
    private static func diagramBuild(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) throws
        -> CanvasBridgeResponse
    {
        guard let spec = call.diagram else { throw CanvasAgentToolError.missingArgument("spec") }
        let board = caller.board
        guard board.cards.count + spec.nodes.count <= CanvasLimits.cards,
            board.connections.count + spec.edges.count <= CanvasLimits.connections
        else { throw CanvasError.capacity }
        var anchor = call
        anchor.width = 160
        anchor.height = 128
        let origin = placement(anchor, kind: "service_icon", caller: caller)
        let rects = CanvasAgentDiagramLayout.rects(
            for: spec, originX: origin.x, originY: origin.y)
        var ids: [String: CanvasCardID] = [:]
        var cards: [CanvasCard] = []
        for node in spec.nodes {
            guard let rect = rects[node.id] else { continue }
            let content: CanvasCardContent =
                switch node.kind {
                case "service_icon":
                    CanvasAgentKinds.serviceIcon(
                        packID: node.packID ?? "common", iconID: node.iconID ?? "server",
                        label: node.label)
                case "note": .note(snapshot: node.label)
                default:
                    CanvasAgentKinds.whiteboard(
                        kind: node.kind, text: node.label, shape: node.shape)
                }
            let card = CanvasCard(
                title: node.label,
                rect: CanvasRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                content: content)
            ids[node.id] = card.id
            cards.append(card)
        }
        let connections = spec.edges.compactMap { edge -> CanvasConnection? in
            guard let from = ids[edge.from], let to = ids[edge.to] else { return nil }
            return CanvasConnection(
                from: from, to: to,
                label: edge.label ?? CanvasConnection.relationshipPlaceholderLabel,
                behavior: .related)
        }
        try board.edit { document in
            document.cards.append(contentsOf: cards)
            document.connections.append(contentsOf: connections)
        }
        board.select(Set(cards.map(\.id)))
        var result = CanvasAgentToolResult(
            message: "Built a diagram with \(cards.count) nodes and \(connections.count) links.")
        result.createdNodes = ids.mapValues { $0.rawValue.uuidString }
        if let title = spec.frame,
            let frame = CanvasAgentKinds.createFrame(
                title: title, members: cards.map(\.id), board: board, session: caller.session)
        {
            result.nodeID = frame.rawValue.uuidString
        }
        return .init(toolResult: result.bounded(maximumBytes: resultBytes))
    }
}

// MARK: Cross-workstream kinds (X5 whiteboard, X6 docking, X9 diagrams)

/// The only place that names card kinds and services from other workstreams.
/// If one of their contracts changes, only this enum changes.
@MainActor
enum CanvasAgentKinds {
    static func kind(of content: CanvasCardContent) -> String {
        if case .note = content { return "note" }
        if case .terminal = content { return "terminal" }
        if case .file = content { return "file" }
        if case .image = content { return "image" }
        if case .web = content { return "web" }
        if case .nativeApp = content { return "app" }
        if case .mermaid = content { return "mermaid" }
        if case .shape = content { return "shape" }
        if case .stroke = content { return "stroke" }
        if case .text = content { return "text" }
        if case .frame = content { return "frame" }
        if case .serviceIcon = content { return "service_icon" }
        return "other"
    }

    static func isMermaid(_ content: CanvasCardContent) -> Bool {
        if case .mermaid = content { return true }
        return false
    }

    static func mermaid(_ source: String) -> CanvasCardContent { .mermaid(source: source) }

    /// The board's own byte bound for the text of a whiteboard kind, so an
    /// agent gets a clear limit error instead of a generic "invalid data".
    static func textLimit(kind: String) -> Int? {
        switch kind {
        case "mermaid": CanvasLimits.mermaidSourceBytes
        case "text": CanvasLimits.whiteboardTextBytes
        default: nil
        }
    }

    static func whiteboard(kind: String, text: String?, shape: String?) -> CanvasCardContent {
        switch kind {
        case "mermaid": return .mermaid(source: text ?? "flowchart LR\n  A --> B")
        case "shape":
            return .shape(
                CanvasShape(
                    kind: CanvasShapeKind(rawValue: shape ?? "") ?? .rectangle,
                    label: text.map {
                        String($0.utf8.count <= CanvasLimits.shapeLabelBytes ? $0 : "")
                    }.flatMap { $0.isEmpty ? nil : $0 }))
        case "text": return .text(CanvasText(text: text ?? "Text"))
        default: return .note(snapshot: text ?? "")
        }
    }

    static func serviceIcon(packID: String, iconID: String, label: String) -> CanvasCardContent {
        .serviceIcon(CanvasServiceIcon(packID: packID, iconID: iconID, label: label))
    }

    static func searchIcons(_ query: String, limit: Int) -> [CanvasAgentIconSummary] {
        CanvasDiagramService.searchIcons(query: query, limit: limit).map {
            CanvasAgentIconSummary(packID: $0.packID, iconID: $0.iconID, label: $0.label)
        }
    }

    static func createFrame(
        title: String, members: [CanvasCardID], board: CanvasBoardState,
        session: WorkspaceSession
    ) -> CanvasCardID? {
        CanvasDiagramService.createFrame(
            title: title, memberIDs: members, in: board, session: session)
    }

    static func export(
        board: CanvasID, target: String, frame: CanvasCardID?, format: String, scale: Double,
        seconds: Double, fps: Int, session: WorkspaceSession
    ) async throws -> URL {
        switch (target, format) {
        case ("frame", "png"):
            guard let frame else { throw CanvasAgentToolError.missingArgument("frame_id") }
            return try await CanvasDiagramService.export(
                boardID: board, target: .frame(frame), format: .png(scale: .init(scale)),
                session: session)
        case ("frame", "pdf"):
            guard let frame else { throw CanvasAgentToolError.missingArgument("frame_id") }
            return try await CanvasDiagramService.export(
                boardID: board, target: .frame(frame), format: .pdf, session: session)
        case ("frame", _):
            guard let frame else { throw CanvasAgentToolError.missingArgument("frame_id") }
            return try await CanvasDiagramService.export(
                boardID: board, target: .frame(frame),
                format: .gif(seconds: .init(seconds), fps: .init(fps)), session: session)
        case ("selection", "png"):
            return try await CanvasDiagramService.export(
                boardID: board, target: .selection, format: .png(scale: .init(scale)),
                session: session)
        case ("selection", "pdf"):
            return try await CanvasDiagramService.export(
                boardID: board, target: .selection, format: .pdf, session: session)
        case ("selection", _):
            return try await CanvasDiagramService.export(
                boardID: board, target: .selection,
                format: .gif(seconds: .init(seconds), fps: .init(fps)), session: session)
        case (_, "png"):
            return try await CanvasDiagramService.export(
                boardID: board, target: .board, format: .png(scale: .init(scale)),
                session: session)
        case (_, "pdf"):
            return try await CanvasDiagramService.export(
                boardID: board, target: .board, format: .pdf, session: session)
        default:
            return try await CanvasDiagramService.export(
                boardID: board, target: .board,
                format: .gif(seconds: .init(seconds), fps: .init(fps)), session: session)
        }
    }

    static func inspect(_ card: CanvasCardID) async -> String? {
        await CanvasAppDocking.shared.inspect(cardID: card)
    }

    /// Launches the app and docks it in its card. Never prompts for
    /// permission; without it the app opens undocked.
    static func open(bundleID: String, card: CanvasCardID, session: WorkspaceSession) async
        -> Bool
    {
        await CanvasAppDocking.shared.open(bundleID: bundleID, in: card, session: session)
    }

    static func displayName(agent: String) -> String {
        switch agent {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "opencode": "OpenCode"
        case "gemini": "Gemini CLI"
        case "cursor", "cursor-agent": "Cursor CLI"
        case "kimi": "Kimi CLI"
        case "cline": "Cline"
        default: "Terminal"
        }
    }
}
