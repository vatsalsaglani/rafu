import JSONRenderSwiftUI
import SwiftUI

/// What a Rafu board component may read and do: board data through this
/// object, never a `WorkspaceSession` held by the component. The card view
/// sets it; outside a card (export, tests) it is `nil` and the components
/// show text only.
@MainActor
final class GeneratedViewBoardContext {
    private weak var board: CanvasBoardState?
    private weak var session: WorkspaceSession?
    private weak var actionHost: RafuViewActionHost?

    init(board: CanvasBoardState?, session: WorkspaceSession?, actionHost: RafuViewActionHost?) {
        self.board = board
        self.session = session
        self.actionHost = actionHost
    }

    func adopt(_ session: WorkspaceSession) {
        if self.session == nil { self.session = session }
    }

    /// The card with this id (any case) or exact title.
    func card(_ reference: String) -> CanvasCard? {
        guard let board else { return nil }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return board.cards.first {
            $0.id.rawValue.uuidString.caseInsensitiveCompare(trimmed) == .orderedSame
        } ?? board.cards.first { $0.title == trimmed }
    }

    @discardableResult
    func openFile(_ path: String, line: Int?) -> Bool {
        actionHost?.openFile(path, line: line) ?? false
    }

    @discardableResult
    func focusNode(_ reference: String) -> Bool {
        actionHost?.focusNode(reference) ?? false
    }

    /// The first pane of a terminal card, read only.
    func terminalPane(_ card: CanvasCard) -> TerminalPaneSnapshot? {
        guard case .terminal(let groupID) = card.content else { return nil }
        return session?.terminal.terminalGroup(groupID)?.panes.first
    }

    func agentStatus(_ card: CanvasCard) -> AgentCardStatus? {
        guard let session, let pane = terminalPane(card) else { return nil }
        return CanvasCardCommands.agentCardStatus(pane: pane, in: session)
    }

    /// The agent a terminal card runs or was made by, from Rafu's own records.
    func agentName(_ card: CanvasCard) -> String? {
        if let pane = terminalPane(card), let id = pane.sessionID,
            let provider = CanvasLiveBridge.shared.connectedProvider(controllerID: id)
        {
            return CanvasAgentNoticeText.vendor(provider: provider)
        }
        if let agent = CanvasAgentCenter.shared.creator(of: card.id)?.agent { return agent }
        return CanvasAgentCenter.shared.launchedAgent(of: card.id)
    }
}

/// `nonisolated` so the nonisolated component views can read it.
nonisolated extension EnvironmentValues {
    @Entry var generatedViewBoardContext: GeneratedViewBoardContext? = nil
}

/// The status words Rafu components accept for `intent`. Each one has a
/// symbol, so colour is never the only signal.
nonisolated enum GeneratedViewIntent: String, CaseIterable, Sendable {
    case neutral, info, good, warning, critical

    static let names = allCases.map(\.rawValue)

    init(_ text: String?) {
        self = text.flatMap(Self.init(rawValue:)) ?? .neutral
    }

    var symbol: String? {
        switch self {
        case .neutral: nil
        case .info: "info.circle.fill"
        case .good: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        }
    }

    var word: String {
        switch self {
        case .neutral: ""
        case .info: "Info"
        case .good: "Good"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

extension GeneratedViewIntent {
    func color(_ theme: JSONRenderTheme) -> Color {
        switch self {
        case .neutral: theme.color.textSecondary
        case .info: theme.color.info
        case .good: theme.color.good
        case .warning: theme.color.warning
        case .critical: theme.color.critical
        }
    }
}
