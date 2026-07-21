import Foundation

/// One row in the terminals panel (terminal-manager.md T-B), derived from a
/// `WorkspaceTerminalController` plus whether it currently has a presented
/// tab. Pure data — no SwiftUI import — so it stays headless-testable.
/// `displayName` is `controller.title` for now; T-D changes only the SOURCE
/// (auto-name from OSC 0/2 title vs. a user-set name), not this shape.
nonisolated struct TerminalSessionRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let shellName: String
    let directoryLabel: String
    let status: TerminalSessionStatus
    let isParked: Bool
    let needsAttention: Bool
}

/// Pure presentation helpers for `TerminalSessionRow` — symbol/label/string
/// derivations only, no FileManager or process work, so they are safe to
/// call from a view body.
nonisolated enum TerminalSessionPresentation {
    /// Three SHAPE-distinct symbols (never color alone, AGENTS) so status is
    /// legible under Increase Contrast / Reduce Transparency / grayscale.
    static func symbol(_ status: TerminalSessionStatus) -> String {
        switch status {
        case .idle: "circle"
        case .running: "circle.fill"
        case .exited: "xmark.circle.fill"
        }
    }

    static func label(_ status: TerminalSessionStatus) -> String {
        switch status {
        case .idle: "Idle"
        case .running: "Running"
        case .exited(let code?): "Exited (\(code))"
        case .exited(nil): "Exited"
        }
    }

    /// `false` for every status this build knows about — T-E's `.bell` case
    /// is the first one that returns `true`; nothing else in this function
    /// changes when that lands.
    static func needsAttention(_ status: TerminalSessionStatus) -> Bool {
        switch status {
        case .idle, .running, .exited: false
        }
    }

    /// `path` relative to `workspaceRoot` when it is nested underneath it
    /// ("." at the root itself), tilde-abbreviated under the home directory
    /// otherwise, or the raw path as a last resort. Pure string math — no
    /// `FileManager` calls, so it is safe to call once per row per render.
    static func directoryLabel(path: String, workspaceRoot: String?) -> String {
        if let workspaceRoot, !workspaceRoot.isEmpty {
            let normalizedRoot =
                workspaceRoot.hasSuffix("/") ? String(workspaceRoot.dropLast()) : workspaceRoot
            if path == normalizedRoot {
                return "."
            }
            let prefix = normalizedRoot + "/"
            if path.hasPrefix(prefix) {
                return String(path.dropFirst(prefix.count))
            }
        }
        return tildeAbbreviated(path)
    }

    private static func tildeAbbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        let prefix = home + "/"
        if path.hasPrefix(prefix) {
            return "~/" + path.dropFirst(prefix.count)
        }
        return path
    }
}

/// Derives the terminals panel's rows and rail-badge count from live model
/// state (`WorkspaceTerminalManager`'s sessions plus the editor layout's
/// presented `.terminal` tabs). No new state store — the panel and rail
/// observe `session.terminal` directly.
nonisolated enum TerminalsPanelModel {
    /// One row per session, in creation order — reads `WorkspaceTerminalController`
    /// (a `@MainActor` class), so this is `@MainActor` too. Callers (views)
    /// must derive rows ONCE per body evaluation, never per-row inside a
    /// `ForEach` closure.
    @MainActor
    static func rows(
        sessions: [WorkspaceTerminalController],
        presentedIDs: Set<UUID>,
        workspaceRoot: String?
    ) -> [TerminalSessionRow] {
        sessions.map { controller in
            let directory = controller.currentDirectoryPath ?? controller.startingDirectory
            return TerminalSessionRow(
                id: controller.id,
                displayName: controller.title,
                shellName: controller.shellDisplayName,
                directoryLabel: TerminalSessionPresentation.directoryLabel(
                    path: directory, workspaceRoot: workspaceRoot),
                status: controller.status,
                isParked: !presentedIDs.contains(controller.id),
                needsAttention: TerminalSessionPresentation.needsAttention(controller.status)
            )
        }
    }

    /// Count of rows currently needing attention — always `0` until T-E
    /// introduces `.bell`, but this stays a pure model function so that
    /// stage's change is data-only.
    static func attentionCount(_ rows: [TerminalSessionRow]) -> Int {
        rows.count { $0.needsAttention }
    }

    /// Narrow rail-path variant that avoids deriving full rows (directory
    /// labels, parked flags) just to count attention-needing sessions.
    @MainActor
    static func attentionCount(sessions: [WorkspaceTerminalController]) -> Int {
        sessions.count { TerminalSessionPresentation.needsAttention($0.status) }
    }
}
