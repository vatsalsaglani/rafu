import Foundation

/// Registry of live `WorkspaceSession`s (one per open workspace window),
/// used only to route a notification reply back to the terminal session it
/// targets (terminal-manager.md T-E) — a `UNUserNotificationCenterDelegate`
/// callback arrives with no window context, so this is the seam that finds
/// the right window. WEAK references only: a strong reference here would
/// leak every window for the app's lifetime.
@MainActor
final class TerminalAttentionCenter {
    static let shared = TerminalAttentionCenter()
    private init() {}

    private struct Entry {
        weak var session: WorkspaceSession?
    }

    private var entries: [Entry] = []

    /// Registers a workspace so replies can find it. Called lazily from
    /// `WorkspaceSession.installTerminalHandlersIfNeeded()` — a workspace
    /// that never opens a terminal never registers. Safe to call more than
    /// once for the same session.
    func register(_ session: WorkspaceSession) {
        entries.removeAll { $0.session == nil }
        guard !entries.contains(where: { $0.session === session }) else { return }
        entries.append(Entry(session: session))
    }

    /// Called from `WorkspaceSession.deinit` — not strictly required since
    /// entries are weak and self-prune, but keeps the list from growing
    /// across a long session of opening/closing many workspace windows.
    func unregister(_ session: WorkspaceSession) {
        entries.removeAll { $0.session == nil || $0.session === session }
    }

    /// Routes a sanitized reply to the session it targets, searching every
    /// registered window. Drops silently — no respawn, no queue, no
    /// fallback — when the session is unknown to every live window (e.g.
    /// its workspace closed, or it was closed/exited before the reply
    /// arrived).
    func deliverReply(_ text: String, to sessionID: UUID) {
        entries.removeAll { $0.session == nil }
        for entry in entries {
            guard let session = entry.session else { continue }
            if session.deliverTerminalReply(text, to: sessionID) { return }
        }
    }

    // MARK: - Notch HUD presentation routes (terminal-notch-hud.md)

    // The HUD is app-global, but a click on it must land in the window that
    // OWNS the session. These are presentation-only routes through the same
    // weak registry the reply path uses — they never touch a pty or a
    // buffer; they select tabs/panels and focus windows.

    /// Reveals the session's tab in the owning workspace window and focuses
    /// that window (the HUD's compact/name click). Revealing clears the
    /// session's `.bell`, which dismisses the HUD via the attention-cleared
    /// hook. A no-op when no live window owns the session.
    func revealTerminalSession(_ sessionID: UUID) {
        guard let session = owningSession(of: sessionID) else { return }
        session.revealTerminalSession(sessionID)
        WorkspaceWindowRegistry.shared.focus(session: session)
    }

    /// Reveals the Terminals panel in the owning workspace window (the
    /// HUD's "+N more" chip — the panel is the many-sessions surface). A
    /// no-op when no live window owns the session.
    func showTerminalsPanel(for sessionID: UUID) {
        guard let session = owningSession(of: sessionID) else { return }
        session.navigatorMode = .terminals
        WorkspaceWindowRegistry.shared.focus(session: session)
    }

    /// Whether the session is still in `.bell` anywhere — the HUD dismiss
    /// timer's `stillNeedsAttention` input. `false` when no live window
    /// owns the session (its window closed), so the HUD dismisses rather
    /// than lingering over a dead session.
    func sessionNeedsAttention(_ sessionID: UUID) -> Bool {
        guard let session = owningSession(of: sessionID) else { return false }
        return session.terminal.sessions.first(where: { $0.id == sessionID })?.status == .bell
    }

    private func owningSession(of sessionID: UUID) -> WorkspaceSession? {
        entries.removeAll { $0.session == nil }
        for entry in entries {
            guard let session = entry.session else { continue }
            if session.terminal.sessions.contains(where: { $0.id == sessionID }) {
                return session
            }
        }
        return nil
    }
}
