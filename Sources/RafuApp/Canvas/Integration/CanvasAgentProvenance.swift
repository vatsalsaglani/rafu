import Foundation
import Observation
import RafuCore

/// One agent edit on one card: who did it, with which tool, and when. It is a
/// mark, not a status (ADR 0029 amendment): it shows for `lifetime`, is never
/// saved, and holds names only — never note text, prompts or output.
nonisolated struct CanvasAgentProvenanceRecord: Equatable, Sendable {
    let boardID: CanvasID
    let cardID: CanvasCardID
    /// "Claude", "Codex" or "Rafu (voice)".
    let agentName: String
    /// The caller's provider id: "claude", "codex" or "voice".
    let provider: String
    /// `CanvasAgentTool.actionTitle`, as the activity log shows it.
    let action: String
    /// The past-tense verb: "added", "moved", "wrote".
    let verb: String
    let date: Date
    /// `board.changeStamp` right after the edit.
    let changeStamp: UInt64

    /// The same 8 s a board notice stays.
    static let lifetime: TimeInterval = {
        let parts = CanvasBoardNotice.lifetime.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }()

    func isVisible(now: Date) -> Bool {
        let age = now.timeIntervalSince(date)
        return age >= 0 && age < Self.lifetime
    }

    /// True only while nothing else changed the board after this edit.
    func canUndo(currentStamp: UInt64) -> Bool { currentStamp == changeStamp }

    /// The vendor mark for the badge; `nil` for a voice edit, which shows
    /// `symbol` instead.
    var cli: ConductorCLIID? {
        switch provider {
        case "voice": nil
        case "codex": .codex
        default: .claudeCode
        }
    }

    /// The SF Symbol for a badge without a vendor mark.
    var symbol: String? { provider == "voice" ? "waveform" : nil }

    /// "Added by Claude".
    var byline: String { "\(verb.prefix(1).uppercased())\(verb.dropFirst()) by \(agentName)" }
}

/// The words of an agent-edit notice. Names only.
nonisolated enum CanvasAgentNoticeText {
    /// "Claude", "Codex" or "Rafu (voice)", from the caller's provider id.
    static func vendor(provider: String) -> String {
        switch provider {
        case "voice": "Rafu (voice)"
        case "codex": "Codex"
        default: "Claude"
        }
    }

    /// The verb for a call that changed one card, or `nil` for a call that
    /// leaves no card to mark: a read, a removal, a link, typing, a start, an
    /// export, a multi-node build.
    static func verb(for call: CanvasAgentToolCall) -> String? {
        switch call.tool {
        case .noteCreate, .nodeCreate, .terminalCreate, .frameCreate: return "added"
        case .noteWrite: return "wrote"
        case .mermaidSet: return "changed"
        case .nodeUpdate: return updateVerb(call)
        case .ensembleDescribe, .noteRead, .nodeRemove, .terminalStart, .terminalSend,
            .edgeCreate, .edgeRemove, .linkSetState, .actionStatus, .iconSearch, .export,
            .diagramBuild:
            return nil
        }
    }

    /// "Claude added Note 3".
    static func line(agent: String, verb: String, cardTitle: String) -> String {
        "\(agent) \(verb) \(CanvasAgentText.singleLine(cardTitle, limit: 40))"
    }

    private static func updateVerb(_ call: CanvasAgentToolCall) -> String {
        let renamed = call.title != nil
        let moved = call.x != nil || call.y != nil
        let resized = call.width != nil || call.height != nil
        switch (renamed, moved, resized) {
        case (true, false, false): return "renamed"
        case (false, true, false): return "moved"
        case (false, _, true): return "resized"
        default: return "changed"
        }
    }
}

/// The board content right after an agent edit. The notice's Undo is honest
/// only while the board's cards and links still equal it: a later edit makes
/// Undo a no-op (and the button disabled), and undoing that later edit makes
/// the agent's step the newest undo step again. A pan or zoom changes neither,
/// so it does not take Undo away.
nonisolated struct CanvasAgentUndoGate: Equatable, Sendable {
    let boardID: CanvasID
    let cards: [CanvasCard]
    let connections: [CanvasConnection]

    func allows(cards current: [CanvasCard], connections currentConnections: [CanvasConnection])
        -> Bool
    {
        current == cards && currentConnections == connections
    }
}

/// Window-independent, like `CanvasAgentCenter`. Nothing here is saved.
@Observable
@MainActor
final class CanvasAgentProvenanceStore {
    static let shared = CanvasAgentProvenanceStore()
    static let cap = 200

    /// Newest last.
    private(set) var records: [CanvasAgentProvenanceRecord] = []
    /// Notice id → the content its Undo is valid for.
    @ObservationIgnored private var undoGates: [UUID: CanvasAgentUndoGate] = [:]

    init() {}

    func record(_ record: CanvasAgentProvenanceRecord) {
        records.append(record)
        if records.count > Self.cap { records.removeFirst(records.count - Self.cap) }
    }

    /// The newest visible record for the card.
    func record(for cardID: CanvasCardID, now: Date) -> CanvasAgentProvenanceRecord? {
        records.last { $0.cardID == cardID && $0.isVisible(now: now) }
    }

    /// Drops every record past its lifetime.
    func prune(now: Date) {
        if records.contains(where: { !$0.isVisible(now: now) }) {
            records.removeAll { !$0.isVisible(now: now) }
        }
    }

    /// A board shows one notice at a time, so a new gate replaces the board's
    /// older ones; the gates stay bounded by the number of boards.
    func registerUndo(noticeID: UUID, gate: CanvasAgentUndoGate) {
        undoGates = undoGates.filter { $0.value.boardID != gate.boardID }
        undoGates[noticeID] = gate
    }

    /// Whether a notice's action may run. Every notice without a gate is
    /// unaffected.
    func allowsAction(noticeID: UUID, board: CanvasBoardState) -> Bool {
        guard let gate = undoGates[noticeID] else { return true }
        return board.canUndo && gate.allows(cards: board.cards, connections: board.connections)
    }

    // MARK: Agent edits

    /// The board content before an agent call, to tell whether the call made
    /// a board undo step (a note typed through its live buffer does not).
    struct Before {
        let cards: [CanvasCard]
        let connections: [CanvasConnection]

        init(_ board: CanvasBoardState) {
            cards = board.cards
            connections = board.connections
        }
    }

    /// Records a successful agent edit on one card and posts the board notice
    /// "Claude added Note 3 · Undo". The card comes from the response's node
    /// id, else the call's; when neither names a card on the board, nothing
    /// is recorded — no guess. Undo is offered only when the call made a board
    /// undo step.
    func noteEdit(
        _ call: CanvasAgentToolCall, response: CanvasBridgeResponse, caller: CanvasAgentCaller,
        before: Before, now: Date = Date()
    ) {
        guard response.error == nil, let verb = CanvasAgentNoticeText.verb(for: call),
            let idString = response.toolResult?.nodeID ?? call.nodeID,
            let uuid = UUID(uuidString: idString)
        else { return }
        let board = caller.board
        guard let card = board.cards.first(where: { $0.id.rawValue == uuid }) else { return }
        let agent = CanvasAgentNoticeText.vendor(provider: caller.provider)
        prune(now: now)
        record(
            CanvasAgentProvenanceRecord(
                boardID: board.id, cardID: card.id, agentName: agent, provider: caller.provider,
                action: call.tool.actionTitle, verb: verb, date: now,
                changeStamp: board.changeStamp))
        let message = CanvasAgentNoticeText.line(agent: agent, verb: verb, cardTitle: card.title)
        let madeUndoStep =
            board.canUndo
            && (board.cards != before.cards || board.connections != before.connections)
        guard madeUndoStep else {
            board.showNotice(message, tone: .info)
            return
        }
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
        if let notice = board.notice { registerUndo(noticeID: notice.id, gate: gate) }
    }
}
