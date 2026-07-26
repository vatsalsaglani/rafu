import Foundation

/// One row in the terminals panel (terminal-manager.md T-B), derived from a
/// `WorkspaceTerminalController` plus whether it currently has a presented
/// tab. Pure data — no SwiftUI import — so it stays headless-testable.
/// `displayName` is `controller.displayName` (terminal-manager.md T-D:
/// user name, then auto title, then a generated fallback).
nonisolated struct TerminalSessionRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let displayName: String
    let shellName: String
    let directoryLabel: String
    let status: TerminalSessionStatus
    let isParked: Bool
    let needsAttention: Bool
    /// Whether `displayName` came from a user-set name rather than the auto
    /// title/fallback — drives the panel's "Reset to Automatic Name" menu
    /// item (terminal-manager.md T-D), shown only when this is `true`.
    let hasUserName: Bool
    /// Color TAG (terminal-manager.md T-D), or `nil` for no tag. Never the
    /// only signal for anything — always paired with `status`'s glyph/label.
    let sessionColor: TerminalSessionColor?
    /// Vendor identity for a tokenless Agent Terminal. `nil` for login
    /// shells and Ensemble run terminals.
    var agentProvider: ConductorCLIID? = nil
}

/// Pure presentation helpers for `TerminalSessionRow` — symbol/label/string
/// derivations only, no FileManager or process work, so they are safe to
/// call from a view body.
nonisolated enum TerminalSessionPresentation {
    /// Four SHAPE-distinct symbols (never color alone, AGENTS) so status is
    /// legible under Increase Contrast / Reduce Transparency / grayscale.
    static func symbol(_ status: TerminalSessionStatus) -> String {
        switch status {
        case .idle: "circle"
        case .running: "circle.fill"
        case .bell: "bell.fill"
        case .exited: "xmark.circle.fill"
        }
    }

    static func label(_ status: TerminalSessionStatus) -> String {
        switch status {
        case .idle: "Idle"
        case .running: "Running"
        case .bell: "Needs attention"
        case .exited(let code?): "Exited (\(code))"
        case .exited(nil): "Exited"
        }
    }

    /// `true` only for `.bell` (terminal-manager.md T-E) — this single
    /// change is what lights the rail badge and the panel row highlight;
    /// no view code changes when this landed.
    static func needsAttention(_ status: TerminalSessionStatus) -> Bool {
        switch status {
        case .bell: true
        case .idle, .running, .exited: false
        }
    }

    /// `true` only for `.exited` — the one state where "shell exited"
    /// chrome (the tab item's stopped dot, `EditorTerminalTabContent`'s
    /// overlay) should show. Deliberately its OWN predicate rather than
    /// `!isRunning`: `.bell` is neither running NOR exited, and testing
    /// `!isRunning` for "exited" was exactly the terminal-manager.md T-E
    /// regression this guards against — a belling session must not show
    /// "Shell exited".
    static func isExited(_ status: TerminalSessionStatus) -> Bool {
        if case .exited = status { return true }
        return false
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

    /// Middle-truncates a terminal tab label at `limit` CHARACTERS
    /// (grapheme clusters, not UTF-8 bytes — so a multibyte/emoji name never
    /// splits a scalar mid-truncation). Identity under/at `limit`.
    static func tabLabel(_ name: String, limit: Int = 20) -> String {
        guard name.count > limit, limit > 1 else { return name }
        let keep = limit - 1
        let headCount = (keep + 1) / 2
        let tailCount = keep - headCount
        let head = name.prefix(headCount)
        let tail = name.suffix(tailCount)
        return "\(head)…\(tail)"
    }
}

/// One provider row in the terminals panel's inline agent launcher (UX-03).
/// `probing` is a first-class state, not an absence: `AgentTerminalLaunchService
/// .options()` spawns real CLIs, so an empty list during the probe would read
/// as "no agents installed" — a lie while the answer is still unknown.
nonisolated enum AgentLauncherRowState: Equatable, Sendable {
    case probing
    case ready
    /// The textual reason from `AgentTerminalAvailability.reason`, carried
    /// verbatim: AT-01's honesty rule is that an unavailable CLI stays visible
    /// and says why, in text, never by dimming or color alone.
    case unavailable(String)
}

/// Pure presentation data for one launcher row — no SwiftUI, so the state
/// machine and its strings are headless-testable.
nonisolated struct AgentLauncherRow: Identifiable, Equatable, Sendable {
    let id: ConductorCLIID
    let displayName: String
    let icon: FileIconProvider.Icon
    let state: AgentLauncherRowState
    /// AT-01's verified-argv caveat (only Kimi carries one today). Shown as
    /// text on a ready row rather than suppressed.
    let verificationNote: String?

    var isLaunchable: Bool {
        state == .ready
    }

    /// The row's single secondary line. A ready row prefers its verification
    /// caveat over the bare "Ready" — the caveat is the more informative truth.
    var statusText: String {
        switch state {
        case .probing: "Checking…"
        case .ready: verificationNote ?? "Ready"
        case .unavailable(let reason): reason
        }
    }

    /// The card's tooltip. The launcher grid is icon-only (UX2-03), so this
    /// string — not a label — is the pointer user's carrier of the provider's
    /// NAME, and it must therefore always contain the name, in every state.
    /// Pairing it with `accessibilityLabel` is what makes an icon-only control
    /// legitimate under AGENTS' "never meaning by icon alone" rule.
    var tooltip: String {
        switch state {
        case .probing:
            "\(displayName) — checking whether it is installed…"
        case .ready:
            if let verificationNote {
                "Launch \(displayName) — \(verificationNote)"
            } else {
                "Launch \(displayName)"
            }
        case .unavailable(let reason):
            "\(displayName) — \(reason)"
        }
    }

    /// Name + state + reason in one string, per the UX-03 accessibility
    /// contract. VoiceOver must never have to infer state from styling.
    var accessibilityLabel: String {
        var parts = [displayName]
        switch state {
        case .probing:
            parts.append("checking whether it is installed")
        case .ready:
            parts.append("ready")
            if let verificationNote { parts.append(verificationNote) }
        case .unavailable(let reason):
            parts.append("unavailable")
            parts.append(reason)
        }
        return parts.joined(separator: ", ")
    }
}

/// Derives the inline agent launcher's rows. Deliberately separate from the
/// `Menu` this replaced: SwiftUI menu items are bridged to `NSMenuItem`, which
/// draws its image at the image's OWN size, so a vendored 1×1-pt `1em` SVG
/// rendered as a tiny dot there (see `docs/references/agent-terminals.md`).
nonisolated enum AgentLauncherModel {
    /// Rows to show while the probe runs: every known provider, in registry
    /// order, in the pending state. Never empty.
    static func probingRows(ids: [ConductorCLIID] = ConductorCLIID.allCases) -> [AgentLauncherRow] {
        ids.map { id in
            AgentLauncherRow(
                id: id,
                displayName: id.displayName,
                icon: ConductorCLIIcons.icon(for: id),
                state: .probing,
                verificationNote: nil)
        }
    }

    /// Rows for a resolved probe. Availability, display name, and icon all
    /// come from the launch service's option — this adds no second discovery
    /// authority.
    static func rows(options: [AgentTerminalOption]) -> [AgentLauncherRow] {
        options.map { option in
            AgentLauncherRow(
                id: option.id,
                displayName: option.displayName,
                icon: option.icon,
                state: option.isReady
                    ? .ready
                    : .unavailable(option.availability.reason ?? "Unavailable."),
                verificationNote: option.launchVerificationNote)
        }
    }

    static func readyCount(_ rows: [AgentLauncherRow]) -> Int {
        rows.count { $0.isLaunchable }
    }

    /// Section header text. The count appears only once the probe resolved;
    /// claiming "0 ready" mid-probe would be the same lie as an empty list.
    static func headerTitle(rows: [AgentLauncherRow], isProbing: Bool) -> String {
        isProbing ? "Agents (checking…)" : "Agents (\(readyCount(rows)) of \(rows.count) ready)"
    }

    /// The launch gate. Returns the option to launch, or `nil` when the row is
    /// not launchable — so an unavailable row cannot reach the launch service
    /// even if a click somehow arrives.
    static func launchableOption(
        for row: AgentLauncherRow,
        in options: [AgentTerminalOption]
    ) -> AgentTerminalOption? {
        guard row.isLaunchable else { return nil }
        guard let option = options.first(where: { $0.id == row.id }), option.isReady else {
            return nil
        }
        return option
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
                displayName: controller.displayName,
                shellName: controller.shellDisplayName,
                directoryLabel: TerminalSessionPresentation.directoryLabel(
                    path: directory, workspaceRoot: workspaceRoot),
                status: controller.status,
                isParked: !presentedIDs.contains(controller.id),
                needsAttention: TerminalSessionPresentation.needsAttention(controller.status),
                hasUserName: controller.userName != nil,
                sessionColor: controller.sessionColor,
                agentProvider: controller.agentProvider
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
