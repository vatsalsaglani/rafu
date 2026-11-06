import AppKit

/// The Dock tile's text for the app-wide agent attention count. Pure.
nonisolated enum DockAttentionBadgeLabel {
    static let cap = 99

    /// `nil` clears the badge. The sum of "needs you" and "failed" cards on
    /// every open Ensemble, capped at "99+". A count only: never a name.
    static func label(needsYou: Int, failed: Int) -> String? {
        let total = max(0, needsYou) + max(0, failed)
        guard total > 0 else { return nil }
        return total > cap ? "\(cap)+" : "\(total)"
    }
}

/// Writes the Dock badge from every open Ensemble in every visible workspace
/// window. It has no timer and no observation of its own: each Ensemble tab
/// calls `refresh()` when its own counts change and when it goes away, so the
/// badge follows the same `CanvasCardCommands.agentCardStatus` the tabs show.
@MainActor
enum DockAttentionBadge {
    /// The last label written; `.none` until the first write.
    private static var last: String??

    static func refresh() {
        var needsYou = 0
        var failed = 0
        for entry in WorkspaceWindowRegistry.shared.entries.values {
            // A closing window is ordered out before its views go away.
            guard let session = entry.session, entry.window?.isVisible == true else { continue }
            for board in session.canvas.boards.values {
                let summary = CanvasAgentSummaryItem(board: board, session: session)
                needsYou += summary.needsYou.count
                failed += summary.failed.count
            }
        }
        write(DockAttentionBadgeLabel.label(needsYou: needsYou, failed: failed))
    }

    /// One refresh after the current update, so a window that is closing has
    /// left the visible set before the count is read again.
    static func refreshSoon() {
        Task { @MainActor in
            await Task.yield()
            refresh()
        }
    }

    private static func write(_ label: String?) {
        if case .some(let previous) = last, previous == label { return }
        last = .some(label)
        NSApp?.dockTile.badgeLabel = label
    }
}
