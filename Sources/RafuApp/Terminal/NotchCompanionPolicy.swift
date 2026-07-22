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
    /// (terminal-notch-hud.md: "300ms dwell").
    static let dwellSeconds: Double = 0.3
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

    /// Escape always returns to `.resting`, regardless of pin state.
    static func onEscape(_ state: CompanionHoverState) -> CompanionHoverState {
        .resting
    }

    /// Feed-vs-drop-down arbitration (terminal-notch-hud.md, "Attention"
    /// section): while the companion panel is open (peeking or pinned), a
    /// new bell routes into the attention feed inside the panel instead of
    /// spawning the separate v1 event drop-down; while resting, the v1
    /// drop-down is what surfaces the event.
    static func companionArbitration(
        hoverState: CompanionHoverState
    ) -> (routeToFeed: Bool, showDropDown: Bool) {
        switch hoverState {
        case .peeking, .pinned: (true, false)
        case .resting: (false, true)
        }
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
/// `CompanionUsageStripView` (`NotchCompanionView.swift`) maps `Emphasis`
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
    static let highUsageThreshold: Double = 80
    static let criticalUsageThreshold: Double = 95

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
    static func renderedTile(for snapshot: UsageSnapshot, displayName: String) -> RenderedTile {
        if !snapshot.windows.isEmpty {
            let windows = snapshot.windows.map { window in
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

    /// `"<displayName> · <window> · <window>"` — the ONE join format the
    /// pre-W0 `CompanionUsageStripView.tileSummary` used
    /// (`"\(tile.agent) · " + windows.joined(" · ")`), preserved exactly so
    /// a no-emphasis line renders byte-identical to before (see
    /// `UsageCoreTests`' rendering-parity test).
    static func plainText(_ tile: RenderedTile) -> String {
        guard !tile.windows.isEmpty else { return tile.displayName }
        return "\(tile.displayName) · " + tile.windows.map(\.text).joined(separator: " · ")
    }

    /// The full front-line string — every tile's `plainText`, joined by
    /// four spaces, matching the pre-W0 strip's tile separator exactly.
    static func plainFrontLineText(_ tiles: [RenderedTile]) -> String {
        tiles.map(plainText).joined(separator: "    ")
    }

    /// A window's rendered text: `"<label> <percent>%"` (append `⚠` at
    /// `criticalUsageThreshold`+), `"<label> <compact tokens> tok"`, or the
    /// bare label when neither is set — identical shape to the pre-W0
    /// `CompanionUsageStripView.windowSummary`.
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
