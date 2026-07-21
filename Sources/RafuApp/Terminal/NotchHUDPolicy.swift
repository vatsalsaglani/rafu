import Foundation

/// Where a bell-worthy terminal attention event surfaces
/// (terminal-notch-hud.md, product decision 1): the system notification
/// (ADR 0016), the notch HUD, both, or neither. ONE arbitration enum rather
/// than two booleans — HUD + banner both firing for one bell is noise the
/// user has to configure away; the enum makes the arbitration explicit and
/// testable. Persisted by `TerminalAttentionSurfaceStore`; default `.both`.
nonisolated enum TerminalAttentionSurface: String, CaseIterable, Sendable {
    case notification
    case hud
    case both
    case none

    /// Settings-picker label (terminal-notch-hud.md N-5).
    var displayName: String {
        switch self {
        case .notification: "Notification"
        case .hud: "Notch HUD"
        case .both: "Both"
        case .none: "Off"
        }
    }
}

/// One bell-worthy session as shown by the HUD (terminal-notch-hud.md N-3).
/// VALUE type carrying only already-bounded, already-sanitized data from the
/// existing seams (`WorkspaceTerminalController.recentOutputSnippet()`,
/// `.displayName`, `.sessionColor`) — the HUD re-presents these; it never
/// reads the terminal itself. The snippet is dropped on dismissal: never
/// logged, persisted, or transmitted (ADR 0016's privacy rules carry over).
nonisolated struct NotchHUDEvent: Equatable, Sendable {
    let sessionID: UUID
    let title: String
    let snippet: String
    let color: TerminalSessionColor?
}

/// Pure decision functions for the notch HUD (terminal-notch-hud.md N-3) —
/// no `AppKit`, no window access, so every rule is headless-testable. The
/// `@MainActor` `NotchHUDController` gathers the live inputs and passes them
/// in, mirroring `TerminalAttentionPolicy`'s shape.
nonisolated enum NotchHUDPolicy {
    /// Auto-dismiss delay without interaction (product decision 5).
    /// Hovering pauses this timer — see `shouldDismiss`.
    static let autoDismissSeconds: Double = 12

    /// Queue-of-one (product decision 4): the NEWEST event always wins the
    /// HUD. A different session superseding the currently shown one
    /// increments `pendingCount` (the "+N more" chip's number); a re-bell
    /// from the SAME session only refreshes the shown event (new snippet),
    /// leaving the count alone. When nothing is currently shown the count
    /// passes through unchanged (a fresh show starts from 0 at the call
    /// site).
    static func merge(
        current: NotchHUDEvent?,
        incoming: NotchHUDEvent,
        pendingCount: Int
    ) -> (shown: NotchHUDEvent, pendingCount: Int) {
        guard let current, current.sessionID != incoming.sessionID else {
            return (incoming, pendingCount)
        }
        return (incoming, pendingCount + 1)
    }

    /// Product decision 5: dismiss immediately on reply send or Escape, and
    /// the moment the session's `.bell` clears for any reason; otherwise
    /// dismiss once `autoDismissSeconds` have passed without interaction —
    /// unless the pointer is hovering, which pauses the timer indefinitely.
    static func shouldDismiss(
        didReply: Bool,
        escapePressed: Bool,
        secondsSinceInteraction: Double,
        stillNeedsAttention: Bool,
        isHovered: Bool
    ) -> Bool {
        if didReply || escapePressed { return true }
        if !stillNeedsAttention { return true }
        if isHovered { return false }
        return secondsSinceInteraction >= autoDismissSeconds
    }

    /// The arbitration truth table behind `WorkspaceSession
    /// .notifyIfNeeded(for:)` (terminal-notch-hud.md N-3): the system
    /// notification additionally requires OS authorization; the HUD never
    /// does — it is our own window, not a `UserNotifications` surface.
    static func surfaces(
        for preference: TerminalAttentionSurface,
        authorized: Bool
    ) -> (notification: Bool, hud: Bool) {
        switch preference {
        case .notification: (authorized, false)
        case .hud: (false, true)
        case .both: (authorized, true)
        case .none: (false, false)
        }
    }
}
