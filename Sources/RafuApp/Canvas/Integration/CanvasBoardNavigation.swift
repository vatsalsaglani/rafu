import Foundation

/// Ensemble card-navigation shortcuts (⌃⌘←↑→↓, ⌃⌘], ⌃⌘[ in
/// `CanvasCommands`). Every entry point resolves its starting card the same
/// way and does nothing when there is no board or no card to move from —
/// there is no implicit "pick the first card" behavior here, unlike
/// `CanvasLayoutMath.neighbour`'s Tab-key fallback.
extension WorkspaceSession {
    /// Moves focus to `target` on `board`: always reveals it, then either
    /// enters it (a terminal card, so SwiftTerm becomes first responder via
    /// `CanvasTerminalCard`'s own `onChange(of: active)` — this never focuses
    /// the pane a second time) or just selects it (every other card kind, so
    /// Return still decides whether to start editing/animate). Either way
    /// `focusedCardID` tracks `target`: without this, a direction key
    /// pressed twice in a row after landing on a non-terminal card would
    /// recompute from the *first* card's stale `focusedCardID` instead of
    /// where the board actually is now (`board.leaveContent()` only clears
    /// `contentIsActive`, never `focusedCardID`). `board.select` already
    /// gives a non-active target the same visual treatment `focusedCardID`
    /// would (see `showsActions` in `CanvasCardViews`), so this introduces
    /// no new highlight.
    func focusCanvasCard(_ target: CanvasCardID, in board: CanvasBoardState) {
        guard let card = board.cards.first(where: { $0.id == target }) else { return }
        board.revealCard(target)
        if case .terminal = card.content {
            board.focus(target)
        } else {
            board.leaveContent()
            board.focusedCardID = target
            board.select([target])
        }
    }

    /// The card spatially left/right/up/down of the current one. Disabled
    /// (see `CanvasCommands`) whenever `TerminalGroupPresentationAction
    /// .focus` for the same direction would also be live, so ⌃⌘←↑→↓ is never
    /// a shared key equivalent between "Focus Card" and "Focus Terminal
    /// Pane" at once.
    func focusCanvasCard(direction: CanvasCardDirection) {
        guard let board = selectedCanvas else { return }
        let current = board.focusedCardID ?? board.selection.first
        guard
            let target = CanvasLayoutMath.directionalNeighbour(
                of: current, in: board.cards, direction: direction)
        else { return }
        focusCanvasCard(target, in: board)
    }

    /// The next (or previous) card in reading order, wrapping around.
    func focusNextCanvasCard(forward: Bool) {
        guard let board = selectedCanvas else { return }
        let current = board.focusedCardID ?? board.selection.first
        guard
            let target = CanvasLayoutMath.neighbour(of: current, in: board.cards, forward: forward)
        else { return }
        focusCanvasCard(target, in: board)
    }
}
