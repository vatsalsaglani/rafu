import Foundation
import RafuCore

/// Terminal output for the voice backend: viewport only, scrubbed, at most 40
/// lines and 4 KiB per terminal. Used only by `ensemble_describe` in Allow
/// mode with Settings ▸ Voice ▸ "Share terminal output" on.
enum VoiceTerminalTail {
    /// Raw viewport lines of the card's first pane, or `nil` when the card is
    /// not a terminal or its view is not mounted.
    static func recentOutputLines(for card: CanvasCard, session: WorkspaceSession) -> [String]? {
        controller(for: card, session: session)?.recentOutputLines(maxLines: 40)
    }

    /// The terminal that runs in the card's first pane; `nil` for a card that
    /// is not a terminal.
    static func controller(
        for card: CanvasCard, session: WorkspaceSession
    ) -> WorkspaceTerminalController? {
        guard case .terminal(let groupID) = card.content,
            let sessionID = session.terminal.terminalGroup(groupID)?.panes.first?.sessionID
        else { return nil }
        return session.terminal.sessions.first(where: { $0.id == sessionID })
    }

    /// Node id → scrubbed text, for every terminal on the board that has a
    /// mounted view and some output.
    static func tails(for board: CanvasBoardState, session: WorkspaceSession) -> [String: String] {
        var result: [String: String] = [:]
        for card in board.cards {
            guard let lines = recentOutputLines(for: card, session: session) else { continue }
            let text = VoiceOutputScrubber.scrub(lines: lines)
            if !text.isEmpty { result[card.id.rawValue.uuidString] = text }
        }
        return result
    }
}
