import Foundation

/// The notch companion's three presentations (terminal-notch-hud.md NC-A,
/// "The three states"): the always-present slim strip, hover-expanded (or
/// click-pinned) panel, and dismissed-back-to-resting. Distinct from
/// `NotchHUDState` (compact/expanded), which describes the EVENT-DRIVEN
/// attention drop-down, not this hover/pin state machine.
nonisolated enum CompanionHoverState: Equatable, Sendable {
    case resting
    case peeking
    case pinned
}

/// Pure event → state transitions for the companion strip's hover/pin
/// behavior (terminal-notch-hud.md NC-A, "Peek" section) — no timers, no
/// `NSTrackingArea`, so every rule is headless-testable. The `dwellSeconds`
/// /`graceSeconds` durations are named here so the model that owns the
/// actual timers (NC-B's `NotchCompanionModel`) reads them from one place;
/// this enum only maps already-elapsed events (hover entered, grace expired,
/// click, Escape) to the next state — it does not run the clock itself.
nonisolated enum CompanionHoverPolicy {
    /// Hover must dwell this long before a bare hover becomes a peek
    /// (coordinator decision: shortened from the original 300ms — peeking is
    /// now a cheap width pop to the wings pill, not a downward panel, so a
    /// snappier dwell reads as responsive rather than accidental).
    static let dwellSeconds: Double = 0.15
    /// Mouse-out grace before an un-pinned peek collapses
    /// (terminal-notch-hud.md: "400ms grace").
    static let graceSeconds: Double = 0.4

    /// Hover enters a wing after the dwell has elapsed: `.resting` opens to
    /// `.peeking`; an already-open state (`.peeking`/`.pinned`) is
    /// unchanged.
    static func onHoverEnter(_ state: CompanionHoverState) -> CompanionHoverState {
        state == .resting ? .peeking : state
    }

    /// The mouse left and the grace period has elapsed: `.peeking` closes
    /// back to `.resting`. `.pinned` stays `.pinned` — the pin overrides the
    /// grace timer entirely (that is the point of clicking to pin).
    static func onHoverExitAfterGrace(_ state: CompanionHoverState) -> CompanionHoverState {
        state == .peeking ? .resting : state
    }

    /// A click on a wing/strip: `.resting`/`.peeking` both PIN open;
    /// clicking again while pinned TOGGLES back to `.peeking` (still open,
    /// just no longer pinned — a mouse-out grace can now close it).
    static func onClick(_ state: CompanionHoverState) -> CompanionHoverState {
        state == .pinned ? .peeking : .pinned
    }

    /// A click or a touch-screen tap on the Dynamic Island capsule: a plain
    /// open/close toggle. `.pinned` closes to `.resting`; anything else
    /// opens (pins) the card. Unlike `onClick`, there is no unpinned-but-open
    /// middle state, because hover never opens the card on an island and a
    /// tap has no hover to leave.
    static func onIslandTap(_ state: CompanionHoverState) -> CompanionHoverState {
        state == .pinned ? .resting : .pinned
    }

    /// Whether hover opens the panel on `surface`. On an island hover only
    /// widens the capsule: the card covers the system island's zone, so it
    /// opens only on an explicit click or tap. Elsewhere the person's
    /// preference holds.
    static func effectiveOpensOnHover(preference: Bool, surface: NotchCompanionSurface?)
        -> Bool
    {
        surface == .island ? false : preference
    }

    /// Escape always returns to `.resting`, regardless of pin state.
    static func onEscape(_ state: CompanionHoverState) -> CompanionHoverState {
        .resting
    }

    /// Feed-vs-drop-down arbitration (terminal-notch-hud.md, "Attention"
    /// section, amended by the RESTING/HOVER redesign): the panel only ever
    /// shows content while `.pinned` — `.peeking` is now just the wings pill
    /// with no downward panel to route a card into — so a new bell routes
    /// into the attention feed ONLY while pinned; both `.resting` and
    /// `.peeking` surface the event through the v1 drop-down.
    ///
    /// `peekShowsPanel` is true while hover-to-open is on: a peek then IS the
    /// open panel, so a bell routes into its feed instead of drawing a second
    /// drop-down over the panel. Default `false` keeps the original table.
    ///
    /// `feedAvailable` is false where the open panel has no attention feed
    /// to show (an island offers Usage only): every bell then takes the
    /// drop-down. Default `true` keeps the original table.
    ///
    /// `menuPopoverShown` is true while the menu bar card (the usage status
    /// item's popover) is open: it is then the open companion surface, so a
    /// bell lands in its Up next feed like a pinned panel. Closed, bells
    /// take the drop-down as before. Default `false` keeps the table.
    static func companionArbitration(
        hoverState: CompanionHoverState,
        peekShowsPanel: Bool = false,
        feedAvailable: Bool = true,
        menuPopoverShown: Bool = false
    ) -> (routeToFeed: Bool, showDropDown: Bool) {
        guard feedAvailable else { return (false, true) }
        if menuPopoverShown { return (true, false) }
        return switch hoverState {
        case .pinned: (true, false)
        case .peeking: peekShowsPanel ? (true, false) : (false, true)
        case .resting: (false, true)
        }
    }
}

/// The companion panel's window level and hover reach on its screen.
///
/// On macOS 27 MenuBarAgent draws the menu bar's status items, including the
/// "»" overflow items, in a window at level 25 — the same level as
/// `NSWindow.Level.statusBar`, where `NotchHUDPanel` sits — above the
/// level-24 menu bar. A resting companion strip at `.statusBar` therefore
/// covers overflow items that expand beside the notch or island. While the
/// strip is collapsed, it orders one level below the menu bar instead
/// (`.belowMenuBar`, `mainMenu - 1`), and the leading wing, which is where
/// the pointer travels to reach an overflow item, does not start hover. Any
/// hover on the housing or the trailing wing raises the panel back to
/// `.statusBar` before the expand, so every expanded control works as
/// before. macOS 26 and earlier keep `.statusBar` and the full hover area:
/// below the menu bar there, the menu bar's material tints the black strip.
/// The plain-display pill hangs below the menu bar and never changes.
///
/// Detecting the expanded overflow directly would need the window list or
/// an Accessibility prompt, so the rule uses only Rafu's own state. Every
/// member lives in the primary declaration — see `CompanionEditorRow`.
nonisolated struct CompanionPanelLayering: Equatable, Sendable {
    nonisolated enum Level: Equatable, Sendable {
        /// `NSWindow.Level.statusBar` (25) — `NotchHUDPanel`'s default.
        case statusBar
        /// `NSWindow.Level.mainMenu - 1` (23): one level below the system
        /// menu-bar window.
        case belowMenuBar
    }

    /// The first macOS major version whose status items share level 25.
    static let firstLoweringOSMajorVersion = 27

    let level: Level
    /// Whether the pointer entering the leading (left) wing starts the hover
    /// dwell. The housing and the trailing wing always do.
    let leadingWingStartsHover: Bool

    /// `.statusBar` with the full hover area — the layering of every state
    /// except a collapsed notch strip on macOS 27 or later. The island
    /// surface is never lowered: its pill hangs BELOW the menu bar, so it
    /// covers no menu-bar item, and a lowered window would lose its hover.
    static let standard = CompanionPanelLayering(level: .statusBar, leadingWingStartsHover: true)

    /// - Parameters:
    ///   - osMajorVersion: `ProcessInfo.operatingSystemVersion.majorVersion`.
    ///   - surface: the companion's surface; `nil` means no companion.
    ///   - hoverState: the hover/pin state.
    ///   - isPanelOpen: whether the panel shows its content.
    ///   - isHoverPending: the hover dwell has started but not fired yet —
    ///     the panel rises before it expands.
    static func resolve(
        osMajorVersion: Int, surface: NotchCompanionSurface?, hoverState: CompanionHoverState,
        isPanelOpen: Bool, isHoverPending: Bool
    ) -> CompanionPanelLayering {
        guard osMajorVersion >= firstLoweringOSMajorVersion,
            surface == .notch,
            hoverState == .resting, !isPanelOpen, !isHoverPending
        else { return standard }
        return CompanionPanelLayering(level: .belowMenuBar, leadingWingStartsHover: false)
    }
}

/// Which companion surfaces exist: the panel (notch strip, island pill or
/// plain-display pill) and the usage status item in the menu bar. Only a
/// Dynamic Island screen reads `UsageGlancePosition`; a notched or plain
/// screen keeps the panel and never gets a status item.
nonisolated struct CompanionPresence: Equatable, Sendable {
    let showsPanel: Bool
    let showsMenuBarItem: Bool

    static let none = CompanionPresence(showsPanel: false, showsMenuBarItem: false)

    /// - Parameters:
    ///   - surface: the companion's surface on its screen; `nil` means no
    ///     companion there (a plain screen with the pill off, or no screen).
    ///   - position: the stored usage glance position.
    ///   - isEnabled: Settings ▸ "Show notch companion".
    static func resolve(
        surface: NotchCompanionSurface?, position: UsageGlancePosition, isEnabled: Bool
    ) -> CompanionPresence {
        guard isEnabled, let surface else { return .none }
        switch (surface, position) {
        case (.island, .menuBar):
            return CompanionPresence(showsPanel: false, showsMenuBarItem: true)
        case (.island, .belowIsland), (.notch, _), (.pill, _):
            return CompanionPresence(showsPanel: true, showsMenuBarItem: false)
        }
    }
}

/// The text the usage status item shows and speaks for one
/// `NotchIslandUsageGlance`. Critical is never colour alone: the title gets
/// a "!" (as the island pill draws one in its ring).
nonisolated enum UsageMenuBarItemText {
    /// `"83%"`, `"97%!"` when critical, or `""` with no usage data (the
    /// item then shows the ring track only).
    static func title(for glance: NotchIslandUsageGlance?) -> String {
        guard let glance else { return "" }
        return glance.level == .critical ? glance.percentText + "!" : glance.percentText
    }

    /// VoiceOver label and tooltip: `"Rafu usage. Usage: Claude, 5-hour
    /// session 83%"`, or `"Rafu usage. No usage data"`.
    static func accessibilityLabel(for glance: NotchIslandUsageGlance?) -> String {
        "Rafu usage. " + (glance?.spokenLabel ?? "No usage data")
    }

    /// The ring's side in points for a menu bar `thickness` points tall:
    /// 16 on the 45 pt Dynamic Island menu bar, smaller on a thin bar so the
    /// ring keeps a margin.
    static func ringSize(forBarThickness thickness: CGFloat) -> CGFloat {
        min(16, max(12, (thickness * 0.6).rounded()))
    }
}

/// The usage status item's text when the menu bar card also carries the
/// attention queue. The attention count joins the percent as text
/// (`"42% · 2"`), and the ring image gets a dot shape, so it never rests on
/// colour alone. Pure.
nonisolated enum CompanionMenuBarItemText {
    /// `"42%"` with nothing waiting; `"42% · 2"` when two agents need the
    /// person; `"2"` with no usage data. Counts above 99 read `"99+"`.
    static func title(glance: NotchIslandUsageGlance?, attention: Int) -> String {
        let usage = UsageMenuBarItemText.title(for: glance)
        guard attention > 0 else { return usage }
        let count = attention > 99 ? "99+" : String(attention)
        return usage.isEmpty ? count : usage + " · " + count
    }

    /// `"Rafu usage. Usage: Claude, 5-hour session 42%. 2 agents need you"`.
    static func accessibilityLabel(glance: NotchIslandUsageGlance?, attention: Int) -> String {
        let usage = UsageMenuBarItemText.accessibilityLabel(for: glance)
        guard attention > 0 else { return usage }
        let noun = attention == 1 ? "agent needs" : "agents need"
        return usage + ". \(attention) \(noun) you"
    }
}

/// The git facts `CompanionEditorRow.gitSummary(_:)` needs, independent of
/// `GitSnapshot`'s shape so this file never has to import/track the full
/// git model — callers (NC-B) map `GitSnapshot`/`GitBranchSnapshot` into
/// this.
nonisolated struct CompanionGitInput: Equatable, Sendable {
    let branch: String
    let ahead: Int
    let behind: Int
    let dirtyCount: Int
    let isDetached: Bool
    let isUnborn: Bool
}

/// The already-live inputs `CompanionEditorRow.editorRows(from:)` derives a
/// row from: one per open `WorkspaceSession` (name/window number), its git
/// snapshot if a repository is open, and its terminal sessions' statuses
/// (chip counts). A plain value type so the derivation is pure and
/// headless-testable; the `@MainActor` aggregation model (NC-B) is the only
/// place that builds these from live sessions.
nonisolated struct CompanionEditorInput: Equatable, Sendable {
    let id: UUID
    let name: String
    let windowNumber: Int
    let git: CompanionGitInput?
    let statuses: [TerminalSessionStatus]
}

/// One open workspace window's row in the companion panel's editors list
/// (terminal-notch-hud.md NC-A, "Editors list") — already-derived display
/// data, never a live reference to the session.
///
/// `editorRows(from:)` and `gitSummary(_:)` live DIRECTLY in this type's
/// primary declaration (not a separate `extension`): the `RafuApp` target
/// sets `.defaultIsolation(MainActor.self)`, and a plain `nonisolated`
/// struct's isolation does NOT propagate to members added in a later
/// `extension` block — those members silently default back to `MainActor`
/// and trap (`SIGTRAP`/`EXC_BREAKPOINT` via `_swift_task_checkIsolatedSwift`)
/// the first time a closure built from them runs off the main thread (as
/// every headless `Tests/` invocation does). Verified via a crash-report
/// backtrace during this stage's implementation (terminal-notch-hud.md
/// NC-A) — the fix is putting these members in the primary declaration,
/// matching `TerminalShellCatalog`/`NotchHUDPolicy`'s existing convention.
nonisolated struct CompanionEditorRow: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let windowNumber: Int
    /// `nil` means no repository open in that window (the git one-liner is
    /// hidden entirely, never shown as a placeholder).
    let gitSummary: String?
    let runningCount: Int
    let attentionCount: Int
    let exitedCount: Int
    /// The raw branch name (`CompanionGitInput.branch`, `nil` when no
    /// repository is open) — kept separate from `gitSummary`'s formatted
    /// one-liner (`⎇ detached`, `⎇ main (unborn)`, `⎇ main · 3± · ↑2`) so
    /// `filteredEditorRows(_:query:)` can match a plain branch name without
    /// having to parse it back out of that display string.
    let branch: String?

    /// Derives one row per input, in the given order (callers sort/filter
    /// `WorkspaceWindowRegistry` entries before calling this). Chip counts
    /// come from `statuses`: `.running` → running, `.bell` → attention,
    /// `.exited` (any code) → exited; `.idle` contributes to none of the
    /// three chips (an idle-but-open terminal is not shown as a count).
    static func editorRows(from inputs: [CompanionEditorInput]) -> [CompanionEditorRow] {
        inputs.map { input in
            var runningCount = 0
            var attentionCount = 0
            var exitedCount = 0
            for status in input.statuses {
                switch status {
                case .running: runningCount += 1
                case .bell: attentionCount += 1
                case .exited: exitedCount += 1
                case .idle: break
                }
            }
            return CompanionEditorRow(
                id: input.id,
                name: input.name,
                windowNumber: input.windowNumber,
                gitSummary: input.git.map(gitSummary),
                runningCount: runningCount,
                attentionCount: attentionCount,
                exitedCount: exitedCount,
                branch: input.git?.branch
            )
        }
    }

    /// The editors-list filter (terminal-notch-hud.md NC-B, "Search/filter"):
    /// a plain, un-tokenized substring match against `name` OR `branch`,
    /// case- and diacritic-insensitive — deliberately NOT
    /// `RafuDropdownFilter`'s whitespace-tokenized AND semantics, since this
    /// narrows a short, already-visible list as the user types rather than
    /// searching fielded data. An empty (after trimming whitespace) query
    /// returns `rows` unchanged, in their original order. Lives directly in
    /// this type's primary declaration for the same isolation reason
    /// `editorRows(from:)`/`gitSummary(_:)` do — see this type's doc comment.
    static func filteredEditorRows(_ rows: [CompanionEditorRow], query: String)
        -> [CompanionEditorRow]
    {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return rows }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return rows.filter { row in
            if row.name.range(of: trimmed, options: options) != nil { return true }
            if let branch = row.branch, branch.range(of: trimmed, options: options) != nil {
                return true
            }
            return false
        }
    }

    /// The one-line git summary (terminal-notch-hud.md: "`⎇ main · 3± ·
    /// ↑2`" — branch, dirty count, ahead/behind):
    ///
    /// - Detached HEAD → exactly `⎇ detached` (branch/dirty/ahead/behind
    ///   are not meaningful for a commit-ish HEAD, so nothing else is
    ///   shown).
    /// - Unborn branch (no commits yet) → `⎇ <branch> (unborn)`, also
    ///   omitting dirty/ahead/behind — ahead/behind has no upstream meaning
    ///   pre-first-commit and a fresh worktree's "dirty" count is normally
    ///   every file, which would read as alarming rather than informative.
    /// - Otherwise: `⎇ <branch>`, then `· <dirty>±` only when
    ///   `dirtyCount != 0`, then `· ↑<ahead> ↓<behind>` with EACH of
    ///   `↑`/`↓` individually omitted when its count is 0, and the whole
    ///   clause omitted when both are 0. A clean repo on `main` therefore
    ///   renders as exactly `⎇ main`.
    static func gitSummary(_ git: CompanionGitInput) -> String {
        if git.isDetached { return "⎇ detached" }
        if git.isUnborn { return "⎇ \(git.branch) (unborn)" }

        var summary = "⎇ \(git.branch)"
        if git.dirtyCount != 0 {
            summary += " · \(git.dirtyCount)±"
        }
        var aheadBehind: [String] = []
        if git.ahead != 0 { aheadBehind.append("↑\(git.ahead)") }
        if git.behind != 0 { aheadBehind.append("↓\(git.behind)") }
        if !aheadBehind.isEmpty {
            summary += " · " + aheadBehind.joined(separator: " ")
        }
        return summary
    }
}

/// Pure display derivations for the companion peek panel's usage area
/// (agent-usage-providers.md, "Multi-provider display in the notch"):
/// front-line selection (up to 4, user-ordered, from `UsageStripOrderStore`)
/// vs. the overflow partition, near-exhaustion emphasis (≥80%/≥95%), and
/// the tile TEXT each renders to — `Name · 5h 82% · 7d 41%` (cost-only:
/// `Name · $41.20`). `Emphasis` is a plain `Sendable` enum, never a
/// `Color`, so this type stays UI-agnostic and headless-testable —
/// the usage views (`NotchSectionViews.swift`) map `Emphasis`
/// to a theme color/weight when building its `AttributedString`.
///
/// Landed in W0's S2 stage (ahead of the S4 companion-model/view wiring)
/// because `UsageCoreTests`' Claude/Codex rendering-parity assertion
/// needs it to exist; see the W0 implementor handoff for this staging
/// note. Every member lives directly in this type's primary declaration —
/// see `CompanionEditorRow`'s doc comment above for why.
nonisolated enum UsageDisplayPolicy {
    /// The peek panel's usage front line shows at most this many tiles
    /// (agent-usage-providers.md: "up to 4 tiles the user picks and orders
    /// in Settings").
    static let frontLineCap = 4
    static let highUsageThreshold: Double = UsageLevelThresholds.high
    static let criticalUsageThreshold: Double = UsageLevelThresholds.critical
    /// A front-line tile's window count caps at this many
    /// (agent-usage-providers.md, "Multi-provider display in the notch",
    /// amended 2026-07-23: per-row front line). Each front-line provider
    /// now gets its own row rather than sharing one joined line, so a
    /// provider carrying 3+ windows (e.g. a per-model Claude breakdown:
    /// `5h 33% · 7d 37% · Fable 7d 48%`) would still overflow that row's
    /// width — capping to the first two windows keeps every row one line.
    /// Providers already order the primary window first, so the surviving
    /// windows are the most relevant ones. `frontLineWindowCap(providerCount:)`
    /// below is the one exception: a SOLE front-line provider has the
    /// whole row's width, so it renders uncapped. The overflow grid's
    /// half-width tiles always apply this cap, regardless of provider
    /// count.
    static let tileWindowCap = 2

    /// Near-exhaustion emphasis for one rendered window — text/weight only,
    /// never color alone (AGENTS: "never communicate ... state using color
    /// alone"). `.critical` also adds a `⚠` glyph directly into the
    /// rendered text (see `windowText(_:)`), so the SIGNAL survives even
    /// where the view applies no color at all.
    nonisolated enum Emphasis: Equatable, Sendable {
        case normal, high, critical
    }

    /// One window's already-formatted text plus the emphasis level a
    /// renderer should apply to just that chunk.
    nonisolated struct RenderedWindow: Equatable, Sendable {
        let text: String
        let emphasis: Emphasis
    }

    /// One provider's fully rendered tile: a display name and its ordered
    /// window chunks (or a single cost-only chunk when the snapshot has no
    /// windows but does have a `costLine`).
    nonisolated struct RenderedTile: Equatable, Sendable {
        let providerID: UsageProviderID
        let displayName: String
        let windows: [RenderedWindow]
    }

    /// Up to `cap` snapshots for the front line: the user's `order` first
    /// (in that exact sequence), then any remaining renderable snapshot
    /// NOT named in `order`, in `snapshots`' own (registry) order — so a
    /// newly enabled provider the user has not yet arranged still appears
    /// somewhere rather than silently vanishing into overflow forever.
    static func frontLine(
        from snapshots: [UsageSnapshot], order: [UsageProviderID], cap: Int = frontLineCap
    ) -> [UsageSnapshot] {
        let byID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.providerID, $0) })
        var picked = order.compactMap { byID[$0] }
        let pickedIDs = Set(picked.map(\.providerID))
        picked.append(contentsOf: snapshots.filter { !pickedIDs.contains($0.providerID) })
        return Array(picked.prefix(cap))
    }

    /// Every snapshot not selected into `frontLine`, preserving
    /// `snapshots`' original order.
    static func overflow(from snapshots: [UsageSnapshot], frontLine: [UsageSnapshot])
        -> [UsageSnapshot]
    {
        let frontLineIDs = Set(frontLine.map(\.providerID))
        return snapshots.filter { !frontLineIDs.contains($0.providerID) }
    }

    /// A two-column grid's row count for `count` overflow tiles — `0` for
    /// no tiles, otherwise `ceil(count / 2)`.
    static func gridRows(for count: Int) -> Int {
        count <= 0 ? 0 : Int((Double(count) / 2).rounded(.up))
    }

    /// One tile's rendering: one `RenderedWindow` per window (percent OR
    /// token form — never both, matching the shipped strip verbatim), or a
    /// single cost-only chunk when `windows` is empty but `costLine` is
    /// set, or a bare name when the snapshot carries neither (should not
    /// happen for a `renderable` snapshot, but never crashes).
    ///
    /// `windowCap` (default `nil` = uncapped, keeping every existing
    /// callsite source-compatible) drops `snapshot.windows` to its first
    /// `windowCap` entries BEFORE mapping — a cost-only tile (no
    /// `windows`) is unaffected by the cap either way. Pass
    /// `UsageDisplayPolicy.tileWindowCap` (via `frontLineWindowCap(providerCount:)`
    /// for the front line, or directly for the overflow grid) to keep a
    /// tile's row to one line; see `tileWindowCap`'s doc comment.
    static func renderedTile(
        for snapshot: UsageSnapshot, displayName: String, windowCap: Int? = nil
    ) -> RenderedTile {
        if !snapshot.windows.isEmpty {
            let cappedWindows =
                windowCap.map { Array(snapshot.windows.prefix($0)) } ?? snapshot.windows
            let windows = cappedWindows.map { window in
                RenderedWindow(
                    text: windowText(window), emphasis: emphasis(forPercent: window.percent))
            }
            return RenderedTile(
                providerID: snapshot.providerID, displayName: displayName, windows: windows)
        }
        if let costLine = snapshot.costLine {
            return RenderedTile(
                providerID: snapshot.providerID, displayName: displayName,
                windows: [RenderedWindow(text: costLine, emphasis: .normal)])
        }
        return RenderedTile(providerID: snapshot.providerID, displayName: displayName, windows: [])
    }

    /// The window cap to apply to EVERY front-line tile, given how many
    /// providers occupy the front line: `nil` (uncapped) for exactly one
    /// provider — a sole row has the width for every window — and
    /// `tileWindowCap` for two or more. A pure helper so
    /// the former text strip's cap-selection logic is headless-testable
    /// without a live `NotchCompanionModel`/screen.
    static func frontLineWindowCap(providerCount: Int) -> Int? {
        providerCount > 1 ? tileWindowCap : nil
    }

    /// `"<displayName> · <window> · <window>"` — the ONE join format the
    /// pre-W0 the pre-W0 `tileSummary` used
    /// (`"\(tile.agent) · " + windows.joined(" · ")`), preserved exactly so
    /// a no-emphasis line renders byte-identical to before (see
    /// `UsageCoreTests`' rendering-parity test). Also each front-line/
    /// overflow row's `.accessibilityLabel` in the per-row redesign
    /// (2026-07-23) — see `NotchUsageMeter` for the meter rendering that replaced the text strip.
    static func plainText(_ tile: RenderedTile) -> String {
        guard !tile.windows.isEmpty else { return tile.displayName }
        return "\(tile.displayName) · " + tile.windows.map(\.text).joined(separator: " · ")
    }

    /// The full front-line string — every tile's `plainText`, joined by
    /// four spaces, matching the pre-W0 strip's tile separator exactly.
    /// The notch stopped using this for its own rendering
    /// once the front line moved to one row per provider (2026-07-23) —
    /// each row now carries its own `plainText` accessibility label
    /// instead of one combined, 4-space-joined line — but it stays a pure,
    /// directly-tested function (`UsageCoreTests`' rendering-parity test)
    /// since nothing about the JOIN FORMAT itself changed.
    static func plainFrontLineText(_ tiles: [RenderedTile]) -> String {
        tiles.map(plainText).joined(separator: "    ")
    }

    /// A window's rendered text: `"<label> <percent>%"` (append `⚠` at
    /// `criticalUsageThreshold`+), `"<label> <compact tokens> tok"`, or the
    /// bare label when neither is set — identical shape to the pre-W0
    /// `windowSummary`.
    private static func windowText(_ window: UsageWindow) -> String {
        if let percent = window.percent {
            var text = "\(window.label) \(Int(percent.rounded()))%"
            if percent >= criticalUsageThreshold {
                text += " ⚠"
            }
            return text
        }
        if let tokens = window.tokens {
            return "\(window.label) \(UsageFormat.compactTokenCount(tokens)) tok"
        }
        return window.label
    }

    private static func emphasis(forPercent percent: Double?) -> Emphasis {
        guard let percent else { return .normal }
        if percent >= criticalUsageThreshold { return .critical }
        if percent >= highUsageThreshold { return .high }
        return .normal
    }
}

/// The one usage figure the Dynamic Island capsule's right lobe shows: the
/// most constrained front-line window, as a single ring. A small, pure,
/// `Sendable` value with no clock, theme, or view in it, so the same
/// value can later become Live Activity content state.
///
/// `resolve` lives in this type's primary declaration — see
/// `CompanionEditorRow`'s doc comment for why.
nonisolated struct NotchIslandUsageGlance: Equatable, Sendable {
    /// `0...1` in the active display mode (used or remaining).
    let fraction: Double?
    /// `"83%"`, from the same `fraction`.
    let percentText: String
    let level: UsageRingLevel
    let tone: UsageRingTone
    /// `"Usage: Claude, 5-hour session 83%"` — VoiceOver's reading.
    let spokenLabel: String

    /// Picks the window with the worst `UsageRingLevel` across every
    /// front-line provider's ring windows; a tie goes to the window closest
    /// to its limit (the highest used fraction, which is the LOWEST fraction
    /// in Remaining mode), then to the earlier window. `nil` when no
    /// front-line provider has a window with a percentage.
    static func resolve(
        frontLine: [UsageSnapshot], observedAt: [UsageProviderID: Date],
        mode: UsageDisplayMode, displayName: (UsageProviderID) -> String, now: Date
    ) -> NotchIslandUsageGlance? {
        var best: (arc: UsageRingArc, name: String)?
        for snapshot in frontLine {
            let name = displayName(snapshot.providerID)
            guard
                let cluster = UsageRingClusterBuilder.make(
                    snapshot: snapshot, observedAt: observedAt[snapshot.providerID], mode: mode,
                    displayName: name, now: now)
            else { continue }
            for arc in cluster.legend {
                guard let current = best else {
                    best = (arc, name)
                    continue
                }
                if isMoreConstrained(arc, than: current.arc, mode: mode) {
                    best = (arc, name)
                }
            }
        }
        guard let (arc, name) = best else { return nil }
        let spokenName = mode == .remaining ? "\(name) remaining" : name
        var spoken = "Usage: \(spokenName), \(arc.title) \(arc.percentText)"
        switch arc.level {
        case .normal: break
        case .warning: spoken += ", warning"
        case .critical: spoken += ", critical"
        }
        return NotchIslandUsageGlance(
            fraction: arc.fraction, percentText: arc.percentText, level: arc.level,
            tone: arc.tone, spokenLabel: spoken)
    }

    private static func isMoreConstrained(
        _ candidate: UsageRingArc, than current: UsageRingArc, mode: UsageDisplayMode
    ) -> Bool {
        let candidateRank = rank(candidate.level)
        let currentRank = rank(current.level)
        if candidateRank != currentRank { return candidateRank > currentRank }
        return usedFraction(candidate, mode: mode) > usedFraction(current, mode: mode)
    }

    private static func rank(_ level: UsageRingLevel) -> Int {
        switch level {
        case .normal: 0
        case .warning: 1
        case .critical: 2
        }
    }

    /// The used share regardless of display mode; `-1` (never chosen over a
    /// real value) when the window has none.
    private static func usedFraction(_ arc: UsageRingArc, mode: UsageDisplayMode) -> Double {
        guard let fraction = arc.fraction else { return -1 }
        return mode == .used ? fraction : 1 - fraction
    }
}

/// One session currently needing attention, as the companion panel's
/// attention feed shows it (terminal-notch-hud.md NC-A, "Attention feed") —
/// the same already-bounded/sanitized shape as `NotchHUDEvent`, plus the
/// owning editor's name and a timestamp for feed ordering (the feed spans
/// ALL windows, so "which editor" must travel with each item).
///
/// `attentionFeed(from:)` lives directly in this type's primary
/// declaration for the same reason `CompanionEditorRow`'s derivations do —
/// see that type's doc comment.
nonisolated struct CompanionFeedItem: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID
    let title: String
    let editorName: String
    let snippet: String
    let timestamp: Date
    let color: TerminalSessionColor?

    /// Newest-first, deduplicated by `sessionID` (a session can only be
    /// `.bell` once at a time, but callers may pass stale/duplicate
    /// snapshots — keep the newest by `timestamp`). Equal timestamps are
    /// broken by the items' ORIGINAL input order (stable: the first-seen
    /// item for that instant sorts first), never by `id`, so the feed's
    /// order does not depend on `UUID` randomness.
    static func attentionFeed(from items: [CompanionFeedItem]) -> [CompanionFeedItem] {
        var newestBySession: [UUID: (item: CompanionFeedItem, firstIndex: Int)] = [:]
        for (index, item) in items.enumerated() {
            if let existing = newestBySession[item.sessionID] {
                if item.timestamp > existing.item.timestamp {
                    newestBySession[item.sessionID] = (item, index)
                }
            } else {
                newestBySession[item.sessionID] = (item, index)
            }
        }
        return newestBySession.values
            .sorted { lhs, rhs in
                lhs.item.timestamp != rhs.item.timestamp
                    ? lhs.item.timestamp > rhs.item.timestamp
                    : lhs.firstIndex < rhs.firstIndex
            }
            .map(\.item)
    }
}
