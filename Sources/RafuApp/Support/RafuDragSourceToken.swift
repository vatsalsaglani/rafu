import Foundation

/// Identifies one of this window's own drag sources (a file row, a tab, an
/// Agent History row, or a Terminals-panel Terminal Group row) for the
/// dimmed "source ghost" while it is being dragged. A row creates exactly
/// one, in `@State`, and compares it against
/// `WorkspaceSession.dragInFlight`.
nonisolated struct RafuDragSourceToken: Hashable, Sendable {
    private let id = UUID()
}

/// Pure begin/end/cancel rules for `WorkspaceSession.dragInFlight`. Kept
/// `nonisolated` and free of AppKit so the lifecycle is testable without a
/// real `NSDraggingSession`. `WorkspaceSession` is one window, so two
/// sessions' `dragInFlight` values are independent by construction — this
/// type carries no shared or static state of its own.
nonisolated enum RafuDragSourceLifecycle {
    /// A drag from `token`'s source begins: it unconditionally becomes the
    /// in-flight token (only one drag can be in flight per window at a
    /// time — a single pointer can't drive two drags at once).
    static func begin(_ token: RafuDragSourceToken) -> RafuDragSourceToken? { token }

    /// A drag from `token`'s source ended (mouse-up, dropped or not).
    /// Clears `current` only if `token` is still the in-flight one — a late
    /// signal for a drag already superseded by a newer one is a no-op, and
    /// never clobbers that newer token.
    static func end(_ token: RafuDragSourceToken, clearing current: RafuDragSourceToken?)
        -> RafuDragSourceToken?
    {
        current == token ? nil : current
    }

    /// A drag from `token`'s source was cancelled (Escape). Same rule as
    /// `end` — once a drag concludes, Rafu has no separate "it was a
    /// cancel, not a drop" state, only "this source's drag is over now".
    static func cancel(_ token: RafuDragSourceToken, clearing current: RafuDragSourceToken?)
        -> RafuDragSourceToken?
    {
        end(token, clearing: current)
    }
}
