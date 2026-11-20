import Foundation

/// Ignores clicks on the answer buttons of the Up next approval rows for a
/// short time after the rows change. When a request closes or a new one moves
/// into place, the second click of a double-click must not land on a button
/// of a different request. Pure: the clock is injected.
struct ApprovalClickGuard {
    /// How long clicks are ignored after the rows change.
    static let quietInterval: TimeInterval = 0.5

    private let now: () -> Date
    private var rows: [UUID] = []
    private var changedAt = Date.distantPast

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Records the request keys in display order. A different list (a request
    /// added, removed or moved) starts the quiet interval.
    mutating func noteRows(_ keys: [UUID]) {
        guard keys != rows else { return }
        rows = keys
        changedAt = now()
    }

    /// False during the quiet interval after the last change.
    var allowsClick: Bool {
        now().timeIntervalSince(changedAt) >= Self.quietInterval
    }
}

/// Decides when the pinned companion panel takes key status for its approval
/// rows. A request that arrives must not take typing away from a terminal, so
/// the panel becomes key only after the person interacts with the approval
/// rows (a click or the pointer over them). The interaction ends when the
/// rows leave the panel or the panel stops being pinned.
struct ApprovalKeyEngagement: Equatable {
    private(set) var rowsVisible = false
    private(set) var interacted = false

    /// True when the panel should take key status for the approval rows.
    var wantsKey: Bool { rowsVisible && interacted }

    /// Approval rows are visible on a pinned panel, or not.
    mutating func setRowsVisible(_ visible: Bool) {
        rowsVisible = visible
        if !visible { interacted = false }
    }

    /// The person clicked in, or moved the pointer into, the approval rows.
    /// Has no effect while no rows are visible.
    mutating func noteInteraction() {
        guard rowsVisible else { return }
        interacted = true
    }

    /// The panel lost key status: a new interaction is needed. The rows stay
    /// visible.
    mutating func endInteraction() {
        interacted = false
    }
}
