import Foundation
import RafuCore

/// Why a terminal session asked for attention. The attention pipeline has two
/// sources that look identical downstream (`.bell`), but they mean different
/// things to the person looking at the notch:
///
/// - `.signal`: BEL, OSC 9 or OSC 777 from the program. An agent CLI sends
///   these when it wants input or permission.
/// - `.completion`: a qualified burst of output followed by silence
///   (`TerminalQuiescencePolicy`). An agent CLI went quiet after working, so a
///   reply is probably waiting.
///
/// Set by `WorkspaceTerminalController`; read only by the notch.
nonisolated enum TerminalAttentionCause: Equatable, Sendable {
    case signal
    case completion
}

/// Where one agent terminal is, in the words the notch uses. Derived purely
/// from state that already exists on the terminal controller; nothing here
/// reads terminal output.
nonisolated enum NotchAgentPhase: Equatable, Sendable {
    case working
    case needsYou
    case replyReady
    case idle
    case stopped

    static func resolve(
        status: TerminalSessionStatus,
        isProducingOutput: Bool,
        cause: TerminalAttentionCause?
    ) -> NotchAgentPhase {
        switch status {
        case .idle, .exited:
            return .stopped
        case .bell:
            return cause == .completion ? .replyReady : .needsYou
        case .running:
            return isProducingOutput ? .working : .idle
        }
    }

    /// The state word shown next to an agent and spoken by VoiceOver.
    var label: String {
        switch self {
        case .working: "Running"
        case .needsYou: "Needs you"
        case .replyReady: "Reply ready"
        case .idle: "Waiting"
        case .stopped: "Stopped"
        }
    }

    /// The SF Symbol shown beside the label, so the state never rests on
    /// colour alone.
    var symbol: String {
        switch self {
        case .working: "play.circle.fill"
        case .needsYou: "exclamationmark.bubble.fill"
        case .replyReady: "checkmark.bubble.fill"
        case .idle: "pause.circle"
        case .stopped: "stop.circle"
        }
    }

    /// A live agent has a running process. A `.stopped` terminal has not been
    /// started or has exited.
    var isLive: Bool { self != .stopped }

    /// The two phases that ask the person to look.
    var needsAttention: Bool { self == .needsYou || self == .replyReady }

    /// Sort key: what to look at first.
    var urgency: Int {
        switch self {
        case .needsYou: 0
        case .replyReady: 1
        case .working: 2
        case .idle: 3
        case .stopped: 4
        }
    }
}

/// Everything the notch needs to know about one terminal, as plain values.
/// `cli` is `nil` for an ordinary shell, which the notch does not list as an
/// agent. `boardID`/`cardID` are the raw ids of the Ensemble and node that
/// host the terminal, `nil` for a terminal that lives outside any open
/// Ensemble.
nonisolated struct NotchTerminalInput: Equatable, Sendable {
    let id: UUID
    let title: String
    let cli: ConductorCLIID?
    let status: TerminalSessionStatus
    let isProducingOutput: Bool
    let cause: TerminalAttentionCause?
    let boardID: UUID?
    let cardID: UUID?
    /// The notch's id for the workspace window that owns the terminal.
    let windowID: UUID?
    /// The phase from agent hooks (`AgentActivityStore`), when a hook
    /// session matches this terminal. Wins over the output-based phase.
    let trackedPhase: NotchAgentPhase?
    /// The matched hook session's active sub-agents.
    let subagents: [NotchSubagentEntry]
    /// Rafu started or switched this terminal's Codex to full access
    /// (`CanvasFullAccessTerminals`).
    let fullAccess: Bool

    init(
        id: UUID,
        title: String,
        cli: ConductorCLIID?,
        status: TerminalSessionStatus,
        isProducingOutput: Bool = false,
        cause: TerminalAttentionCause? = nil,
        boardID: UUID? = nil,
        cardID: UUID? = nil,
        windowID: UUID? = nil,
        trackedPhase: NotchAgentPhase? = nil,
        subagents: [NotchSubagentEntry] = [],
        fullAccess: Bool = false
    ) {
        self.id = id
        self.title = title
        self.cli = cli
        self.status = status
        self.isProducingOutput = isProducingOutput
        self.cause = cause
        self.boardID = boardID
        self.cardID = cardID
        self.windowID = windowID
        self.trackedPhase = trackedPhase
        self.subagents = subagents
        self.fullAccess = fullAccess
    }
}

/// One active sub-agent as the notch and menu bar card list it: type,
/// model, and short task description, each optional. In memory only.
nonisolated struct NotchSubagentEntry: Identifiable, Equatable, Sendable {
    let id: String
    let type: String?
    let model: String?
    let taskDescription: String?

    init(id: String, type: String? = nil, model: String? = nil, taskDescription: String? = nil) {
        self.id = id
        self.type = type
        self.model = model
        self.taskDescription = taskDescription
    }

    /// The type, or "Sub-agent" when the installed helper does not report
    /// it.
    var displayType: String { type ?? "Sub-agent" }

    /// `"implementor · opus · Build the menu card"`, skipping what is
    /// missing.
    var line: String {
        [displayType, model, taskDescription].compactMap { $0 }.joined(separator: " · ")
    }

    /// `"3 sub-agents"`.
    static func chipText(count: Int) -> String {
        "\(count) sub-agent\(count == 1 ? "" : "s")"
    }

    /// `"3 sub-agents running: implementor, implementor, Explore"`.
    static func spokenSummary(_ entries: [NotchSubagentEntry]) -> String {
        chipText(count: entries.count) + " running: "
            + entries.map(\.displayType).joined(separator: ", ")
    }

    /// Whether any entry lacks its type, so the list can say that names
    /// appear after reconnecting Activity tracking.
    static func needsReconnectNote(_ entries: [NotchSubagentEntry]) -> Bool {
        entries.contains { $0.type == nil }
    }
}

/// One agent in the notch lists.
nonisolated struct NotchAgentRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let cli: ConductorCLIID
    let phase: NotchAgentPhase
    let boardID: UUID?
    let cardID: UUID?
    let windowID: UUID?
    /// Active sub-agents from hooks, in start order.
    let subagents: [NotchSubagentEntry]
    /// Card details for an agent seen through hooks (`CompanionAgentCardView`),
    /// `nil` when Rafu does not have them: the folder path, the time of the
    /// newest hook event, the bounded last-message preview the helper kept
    /// (at most 600 characters, in memory only), and a short session suffix
    /// to tell two cards with the same title apart.
    let detail: String?
    let updatedAt: Date?
    let lastMessage: String?
    let sessionSuffix: String?
    /// The agent runs with full access: the row shows a "Full access" badge.
    let fullAccess: Bool

    init(
        id: UUID, title: String, cli: ConductorCLIID, phase: NotchAgentPhase,
        boardID: UUID? = nil, cardID: UUID? = nil, windowID: UUID? = nil,
        subagents: [NotchSubagentEntry] = [], detail: String? = nil, updatedAt: Date? = nil,
        lastMessage: String? = nil, sessionSuffix: String? = nil, fullAccess: Bool = false
    ) {
        self.id = id
        self.title = title
        self.cli = cli
        self.phase = phase
        self.boardID = boardID
        self.cardID = cardID
        self.windowID = windowID
        self.subagents = subagents
        self.detail = detail
        self.updatedAt = updatedAt
        self.lastMessage = lastMessage
        self.sessionSuffix = sessionSuffix
        self.fullAccess = fullAccess
    }

    /// What VoiceOver reads for the row: title, agent, state, and full
    /// access when it applies.
    var accessibilityLabel: String {
        var parts = [title, cli.displayName, phase.label]
        if fullAccess { parts.append(CanvasAgentFullAccess.accessibilityLabel) }
        return parts.joined(separator: ", ")
    }

    /// Agent rows for every terminal that runs a recognised agent CLI, in the
    /// input order. Ordinary shells are dropped.
    static func rows(from terminals: [NotchTerminalInput]) -> [NotchAgentRow] {
        terminals.compactMap { terminal in
            guard let cli = terminal.cli else { return nil }
            return NotchAgentRow(
                id: terminal.id,
                title: terminal.title,
                cli: cli,
                phase: terminal.trackedPhase
                    ?? NotchAgentPhase.resolve(
                        status: terminal.status,
                        isProducingOutput: terminal.isProducingOutput,
                        cause: terminal.cause),
                boardID: terminal.boardID,
                cardID: terminal.cardID,
                windowID: terminal.windowID,
                subagents: terminal.subagents,
                fullAccess: terminal.fullAccess)
        }
    }

    /// Most urgent first. Equal urgency keeps the input order.
    static func byUrgency(_ rows: [NotchAgentRow]) -> [NotchAgentRow] {
        rows.enumerated()
            .sorted { lhs, rhs in
                lhs.element.phase.urgency != rhs.element.phase.urgency
                    ? lhs.element.phase.urgency < rhs.element.phase.urgency
                    : lhs.offset < rhs.offset
            }
            .map(\.element)
    }
}

/// Counts for the collapsed notch and the Ensemble headers.
nonisolated struct NotchAgentSummary: Equatable, Sendable {
    let live: Int
    let working: Int
    let needsYou: Int
    let replyReady: Int

    init(live: Int = 0, working: Int = 0, needsYou: Int = 0, replyReady: Int = 0) {
        self.live = live
        self.working = working
        self.needsYou = needsYou
        self.replyReady = replyReady
    }

    /// Agents that ask the person to look.
    var attention: Int { needsYou + replyReady }

    static func summarize(_ rows: [NotchAgentRow]) -> NotchAgentSummary {
        var live = 0
        var working = 0
        var needsYou = 0
        var replyReady = 0
        for row in rows {
            switch row.phase {
            case .working:
                working += 1
                live += 1
            case .needsYou:
                needsYou += 1
                live += 1
            case .replyReady:
                replyReady += 1
                live += 1
            case .idle:
                live += 1
            case .stopped:
                break
            }
        }
        return NotchAgentSummary(
            live: live, working: working, needsYou: needsYou, replyReady: replyReady)
    }

    /// One accessibility sentence: "3 agents, 1 needs you".
    var spokenSummary: String {
        guard live > 0 else { return "No agents running" }
        var parts = ["\(live) agent\(live == 1 ? "" : "s")"]
        if needsYou > 0 { parts.append("\(needsYou) need\(needsYou == 1 ? "s" : "") you") }
        if replyReady > 0 { parts.append("\(replyReady) reply ready") }
        if working > 0 { parts.append("\(working) running") }
        return parts.joined(separator: ", ")
    }
}

/// An open Ensemble as the notch lists it.
nonisolated struct NotchBoardInput: Equatable, Sendable {
    let id: UUID
    let title: String
    let cardCount: Int
}

nonisolated struct NotchEnsembleRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let cardCount: Int
    let agents: [NotchAgentRow]

    var summary: NotchAgentSummary { NotchAgentSummary.summarize(agents) }
}

/// One window's Ensembles and agents.
nonisolated struct NotchWindowAgents: Equatable, Sendable {
    /// Open Ensembles in the input order, each with its agents.
    let ensembles: [NotchEnsembleRow]
    /// Agents in terminals that are not part of any open Ensemble.
    let looseAgents: [NotchAgentRow]

    static let empty = NotchWindowAgents(ensembles: [], looseAgents: [])

    var isEmpty: Bool { ensembles.isEmpty && looseAgents.isEmpty }

    var allAgents: [NotchAgentRow] { ensembles.flatMap(\.agents) + looseAgents }

    static func build(boards: [NotchBoardInput], terminals: [NotchTerminalInput])
        -> NotchWindowAgents
    {
        let rows = NotchAgentRow.rows(from: terminals)
        let boardIDs = Set(boards.map(\.id))
        let ensembles = boards.map { board in
            NotchEnsembleRow(
                id: board.id,
                title: board.title,
                cardCount: board.cardCount,
                agents: NotchAgentRow.byUrgency(rows.filter { $0.boardID == board.id }))
        }
        let loose = rows.filter { row in
            guard let boardID = row.boardID else { return true }
            return !boardIDs.contains(boardID)
        }
        return NotchWindowAgents(
            ensembles: ensembles, looseAgents: NotchAgentRow.byUrgency(loose))
    }
}

/// Up next's compact rows. Pure.
nonisolated enum CompanionUpNextContent {
    /// `upNext` without the sessions that already show a feed card, in the
    /// given (urgency) order.
    static func waitingRows(_ upNext: [NotchAgentRow], feedSessionIDs: Set<UUID>)
        -> [NotchAgentRow]
    {
        upNext.filter { !feedSessionIDs.contains($0.id) }
    }
}

/// What the Agents tab shows: the list, or one empty-state line. Pure.
nonisolated enum CompanionAgentsContent: Equatable, Sendable {
    case list
    case empty(String)

    /// The list when a window matches, or when agents outside Rafu run and
    /// no filter is typed (outside agents are not filtered). Otherwise the
    /// filter's no-match line, or the host's empty line.
    static func resolve(editorCount: Int, outsideCount: Int, query: String, host: CompanionHost)
        -> CompanionAgentsContent
    {
        let filtering = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if editorCount > 0 || (outsideCount > 0 && !filtering) { return .list }
        if filtering { return .empty("No editors match “\(query)”") }
        return host == .menuBar
            ? .empty("No agents running. Start one in a terminal or an Ensemble.")
            : .empty("No open editors")
    }
}
