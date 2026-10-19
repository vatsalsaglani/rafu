import AppKit

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

    /// What an app event seen while a drag is in flight means for it.
    enum Signal: Equatable, Sendable {
        case ended
        case cancelled
    }

    /// The pure rule behind the drag-end monitor. A left mouse-up ends the
    /// drag and Escape (key code 53) cancels it. A mouse-move or a new left
    /// mouse-down ALSO ends it: each can only arrive while no button is
    /// held, so no drag can still be in flight. Those two exist because
    /// AppKit's asynchronous, gesture-based drag session (what SwiftUI's
    /// `.onDrag` starts on macOS 26+) consumes the drag's own mouse-up, so a
    /// local monitor never sees it; without them the source ghost stayed
    /// dimmed until the 12 s fallback.
    static func signal(for type: NSEvent.EventType, keyCode: UInt16) -> Signal? {
        switch type {
        case .leftMouseUp, .leftMouseDown, .mouseMoved: .ended
        case .keyDown where keyCode == 53: .cancelled
        default: nil
        }
    }
}

/// When a drag source's `.onDrag` closure may write OBSERVED state. SwiftUI
/// calls that closure while its drag-lift gesture is still building the
/// `NSDraggingSession`. `WorkspaceSession.dragInFlight` is read by every
/// source row and tab (for the dimmed source ghost), so a synchronous write
/// there invalidates those views in the middle of drag initiation. The
/// ghost is cosmetic, so the write moves to a later main-queue turn, after
/// the session exists. `@ObservationIgnored` caches that a drop reads
/// synchronously (`activeEditorDrag`, `activeEnsembleDragHint`) stay
/// synchronous at the call site; they invalidate nothing.
enum RafuDragSourceStart {
    typealias Scheduler = @MainActor (@escaping @MainActor () -> Void) -> Void

    /// The production scheduler: the next turn of the main queue, which
    /// AppKit also services while a drag is tracking.
    static let nextMainTurn: Scheduler = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}
