import AppKit
import Observation
import RafuCore
import SwiftUI

/// Persists whether the notch companion strip exists at all
/// (terminal-notch-hud.md, "Resting": "A Settings toggle... default ON on
/// notched displays, OFF on non-notch displays"). NC-E wires the real
/// Settings toggle and the per-display default; this stage only reads
/// whatever is already in defaults — default ON, mirroring every other
/// suite-injectable store here (`TerminalAttentionSurfaceStore`): the SUITE
/// NAME is stored, not a `UserDefaults` instance (`UserDefaults` is not
/// `Sendable` on this toolchain), so tests inject an isolated suite instead
/// of polluting the developer's real defaults.
nonisolated struct NotchCompanionPreferenceStore: Sendable {
    static let defaultsKey = "notchCompanionEnabled"

    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func isEnabled() -> Bool {
        defaults.object(forKey: Self.defaultsKey) == nil
            ? true : defaults.bool(forKey: Self.defaultsKey)
    }

    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: Self.defaultsKey)
    }
}

/// App-global owner of the notch companion's resting strip and peek panel
/// (terminal-notch-hud.md NC-B) — a singleton beside `NotchHUDController`
/// and `TerminalAttentionCenter`, since the strip is one-per-Mac, not
/// one-per-window.
///
/// Holds a WEAK multi-session registry (mirroring `TerminalAttentionCenter`
/// exactly — see that type's doc comment) so it never keeps a closed
/// workspace window alive, derives `editorRows`/`attentionCount` through the
/// pure `CompanionEditorRow`/`CompanionEditorInput` seam from NC-A, and runs
/// the hover-dwell/mouse-out-grace TIMERS `CompanionHoverPolicy` only maps
/// (pure, no clock) — the same `Timer.scheduledTimer` +
/// `MainActor.assumeIsolated` discipline
/// `WorkspaceTerminalController`'s quiescence timer uses, since `Timer`
/// fires on the main run loop, not through a Swift Concurrency executor hop.
@MainActor
@Observable
final class NotchCompanionModel: NSObject {
    static let shared = NotchCompanionModel()

    // MARK: - View-visible state

    private(set) var hoverState: CompanionHoverState = .resting
    private(set) var editorRows: [CompanionEditorRow] = []
    private(set) var attentionCount: Int = 0
    /// The live filter over `editorRows` (terminal-notch-hud.md NC-B,
    /// "Search/filter") — workspace name OR git branch, never the usage
    /// strip or attention feed. `private(set)`: the view mutates it only
    /// through `setSearchQuery(_:)`, which also keeps the panel's geometry
    /// in sync.
    private(set) var searchQuery = ""
    /// The cross-window attention feed (terminal-notch-hud.md NC-C, "Peek",
    /// item 3) — newest-first, deduplicated by `sessionID`, capped at
    /// `maxFeedItems`. Populated by `WorkspaceSession.notifyIfNeeded(for:)`'s
    /// feed-vs-drop-down arbitration when the peek panel is open; cleared by
    /// `clearFeedItem(sessionID:)` when that session's `.bell` clears for
    /// any reason (reveal, reply, tab selection).
    private(set) var feedItems: [CompanionFeedItem] = []
    /// Whether a feed card's reply field is engaged — one of TWO inputs
    /// (alongside `isSearchEngaged`) to `updateKeyStatus()`'s arbiter, which
    /// is the ONE place that flips the panel's `canBecomeKey`
    /// (`engageReply()`/`disengageReply()` below).
    private(set) var isReplyEngaged = false
    /// Whether the search field is engaged — the other input to
    /// `updateKeyStatus()`'s arbiter (`engageSearch()`/`disengageSearch()`
    /// below). A second focusable field means neither one can flip
    /// `allowsKeyStatus` unilaterally: focusing the search field while a
    /// feed reply field is *also* still counted as engaged (a stale
    /// `onChange` ordering edge case) must not drop key status out from
    /// under the user mid-edit.
    private(set) var isSearchEngaged = false
    /// Refreshed (not read from an environment) every time `editorRows` is
    /// recomputed — the strip belongs to no scene, mirroring how
    /// `NotchHUDController.theme` is captured by value rather than read from
    /// `@Environment`.
    private(set) var theme: RafuTheme = RafuThemeCatalog.indigo
    /// Height of the notch/menu-bar band the strip overlaps on a notched
    /// screen — mirrors `NotchHUDController.bandInset` exactly, including
    /// the reason it exists as VIEW-visible state rather than a constant:
    /// `CompanionWingsView` pads/sizes itself to this so the wings row lines
    /// up with the physical housing without hardcoding a pixel value that
    /// could drift from a real screen's `safeAreaInsets.top`.
    private(set) var bandInset: CGFloat = 0
    /// Height of the always-visible strip row: the notch band on a notched
    /// screen (equal to `bandInset`), the pill's own height on a plain
    /// display, where `bandInset` is 0 and the panel hangs below the menu bar.
    private(set) var stripHeight: CGFloat = 0
    /// Whether the strip hugs a physical notch. `false` for the floating pill
    /// on a display without one: both sides are visible, so the wings can
    /// carry more.
    private(set) var hasPhysicalNotch = true
    /// The companion's shape on its screen: the notch strip, the capsule
    /// behind a system Dynamic Island, or the plain-display pill. Set from
    /// the companion's screen in `activateIfEnabled()` and
    /// `updateStripMetrics`, and drives `applySurfacePolicy()`.
    private(set) var surface: NotchCompanionSurface = .notch
    /// The island card's corner radius on the companion's screen
    /// (`NotchIslandGeometry.openCornerRadius(for:)`), recorded with the
    /// other strip metrics so a view never reads the screen.
    private(set) var islandOpenCornerRadius: CGFloat = NotchIslandGeometry.openCornerRadius

    // MARK: - What the notch shows (Settings ▸ General ▸ Notch)

    /// Sections offered as tabs in the open panel, in tab order. Reloaded by
    /// `reloadDisplayPreferences()` — never read from `UserDefaults` in a view
    /// body.
    private(set) var visibleSections: [NotchSection] = NotchSection.allCases
    private(set) var selectedSection: NotchSection = .ensembles
    /// The menu bar card's tabs (`NotchSection.offered(_:host: .menuBar)`)
    /// and its own selected tab, apart from the notch panel's.
    private(set) var menuBarSections: [NotchSection] = NotchSection.offered(
        NotchSection.allCases, host: .menuBar)
    private(set) var menuBarSelection: NotchSection = .usage
    /// The usage status item's popover is open. Set by `UsageMenuBarItem`.
    private(set) var isMenuPopoverShown = false
    /// The mascot replaces the plain Rafu mark in the collapsed strip.
    private(set) var isMascotEnabled = true
    /// Hovering opens the panel (Cider's behaviour); off, hover only widens
    /// the strip and a click opens the panel.
    private(set) var opensOnHover = true
    /// Show a floating pill on a display with no notch.
    private(set) var allowsPill = false
    /// Where the companion shows: its own surface (the notch strip, the
    /// pill below the island, or the plain-display pill), or a status item
    /// in the menu bar on any Mac (`CompanionPresence`).
    private(set) var usageGlancePosition: UsageGlancePosition = .belowIsland
    /// Now Playing, read through public API only (`NotchNowPlaying`).
    let nowPlaying = NotchNowPlaying()
    @ObservationIgnored
    var displayPreferences = NotchDisplayPreferenceStore()
    @ObservationIgnored
    private var bounceLedger = MascotBounceLedger()
    /// Every enabled provider's usage snapshot (agent-usage-providers.md,
    /// "Multi-provider display in the notch") — empty hides the whole
    /// usage area. Computed off-main by `refreshUsage()`; never populated
    /// synchronously, so panel presentation never blocks on file I/O (or,
    /// once network strategies land, a network round-trip).
    private(set) var usageSnapshots: [UsageSnapshot] = []
    /// When each snapshot in `usageSnapshots` was read. A stale (retained)
    /// snapshot keeps its original time. See `UsageSnapshotRetention`.
    private(set) var usageObservedAt: [UsageProviderID: Date] = [:]
    /// Providers whose last refresh failed and that show their last
    /// successful snapshot instead.
    private(set) var usageStaleProviderIDs: Set<UsageProviderID> = []
    /// Providers with network consent at the last refresh — decides whether
    /// a local-only card offers "Connect" or "Reconnect".
    private(set) var usageNetworkConsentIDs: Set<UsageProviderID> = []
    /// `true` while a refresh runs; cards show a spinner.
    private(set) var isUsageRefreshing = false
    /// Used/Remaining for every usage ring (Settings ▸ Usage).
    private(set) var usageDisplayMode: UsageDisplayMode = UsageDisplayModeStore().mode()
    @ObservationIgnored
    var usageDisplayModeStore = UsageDisplayModeStore()
    /// Color/Monochrome for every usage ring (Settings ▸ Usage).
    private(set) var usageRingPalette: UsageRingPalette = UsageRingPaletteStore().palette()
    @ObservationIgnored
    var usageRingPaletteStore = UsageRingPaletteStore()
    /// The user's front-line ordering (agent-usage-providers.md: "up to 4
    /// tiles the user picks and orders in Settings"). Not a test seam —
    /// every headless test either asserts `usageSnapshots` directly or
    /// constructs its own `UsageDisplayPolicy` inputs.
    @ObservationIgnored
    private var usageStripOrderStore = UsageStripOrderStore()

    /// Up to `UsageDisplayPolicy.frontLineCap` snapshots, in the user's
    /// order — listed first in the Usage section.
    var usageFrontLine: [UsageSnapshot] {
        UsageDisplayPolicy.frontLine(from: usageSnapshots, order: usageStripOrderStore.order())
    }

    /// Every enabled snapshot NOT selected into `usageFrontLine`. The Usage
    /// section lists these after the front line.
    var usageOverflow: [UsageSnapshot] {
        UsageDisplayPolicy.overflow(from: usageSnapshots, frontLine: usageFrontLine)
    }

    // MARK: - Weak session registry (mirrors `TerminalAttentionCenter`)

    private struct Entry {
        /// Stable per-registration id, independent of `WorkspaceWindowRegistry`'s
        /// own `windowID` — this is `CompanionEditorRow.id` and the input
        /// `focusEditor(_:)` looks up, so a row can be focused even the one
        /// tick a session is registered here before `WorkspaceWindowRegistry`
        /// has (or after it has already been pruned).
        let id: UUID
        weak var session: WorkspaceSession?
    }

    @ObservationIgnored
    private var entries: [Entry] = []

    // MARK: - Panel + timers

    @ObservationIgnored
    private var panel: NotchHUDPanel?
    @ObservationIgnored
    private var dwellTimer: Timer?
    @ObservationIgnored
    private var graceTimer: Timer?
    /// A global left-mouse-down monitor that exists only while the island
    /// card is open: a click the system Dynamic Island takes (inside
    /// `NotchIslandGeometry.systemZone`) closes Rafu's card, so the two
    /// surfaces never sit open on top of each other.
    @ObservationIgnored
    private var islandYieldMonitor: Any?
    /// The pointer is inside the hover region and has started (or tried to
    /// start) the dwell — so continuous hover reports start it only once.
    @ObservationIgnored
    private var isPointerInside = false
    @ObservationIgnored
    var preferenceStore = NotchCompanionPreferenceStore()
    /// The usage status item, present only while `CompanionPresence` asks
    /// for it (`.menuBar`, on any Mac). Created only by
    /// `activateIfEnabled()`, so a headless test never makes one.
    @ObservationIgnored
    private var usageMenuBarItem: UsageMenuBarItem?

    // MARK: - Usage (terminal-notch-hud.md NC-D)

    /// The reader test seam — production default resolves the real
    /// registry (`UsageProviderRegistry.all`, real files/network/Keychain);
    /// tests substitute a `UsageRegistryReader` built from fixture
    /// descriptors, mirroring `deliverReply`/`revealSession` above.
    @ObservationIgnored
    var usageReader = UsageRegistryReader()
    @ObservationIgnored
    private var usageRefreshTask: Task<Void, Never>?
    /// When usage is read: after agent turns, on open when old, and on a slow
    /// fallback. Pure; this model owns the one wake-up that follows it.
    @ObservationIgnored
    private(set) var usageSchedule = UsageRefreshSchedule()
    /// Sleeps until the schedule's next read. Lives while a status item or the
    /// panel exists — not only while the panel is pinned.
    @ObservationIgnored
    private var usageWakeTask: Task<Void, Never>?
    /// The clock for the usage schedule and the observed-at times; tests
    /// substitute a fake.
    @ObservationIgnored
    var usageNow: @MainActor () -> Date = { Date() }
    /// Test seam: pretend a status item exists, so a headless test exercises
    /// the schedule without creating a real `NSStatusItem`.
    @ObservationIgnored
    var usageSurfaceOverrideForTesting = false
    /// While the screen is locked or asleep, nobody can see usage and a read
    /// could raise a Keychain prompt behind the lock: check again this often.
    private static let usageInactiveRecheck: TimeInterval = 60
    /// Writes the widget snapshot after each usage refresh.
    @ObservationIgnored
    private let widgetSnapshotPublisher = WidgetSnapshotPublisher()

    // MARK: - Test seams (mirroring NotchHUDController's reply/reveal routes)

    /// The reply route. Production default: the existing,
    /// security-reviewed `TerminalAttentionCenter.deliverReply` — the ONLY
    /// delivery path (matches `NotchHUDController.deliverReply` verbatim).
    @ObservationIgnored
    var deliverReply: (String, UUID) -> Void = { text, sessionID in
        TerminalAttentionCenter.shared.deliverReply(text, to: sessionID)
    }
    /// Reveal route (presentation only). Production default: the center's
    /// weak-registry lookup; tests substitute a spy.
    @ObservationIgnored
    var revealSession: (UUID) -> Void = { sessionID in
        TerminalAttentionCenter.shared.revealTerminalSession(sessionID)
    }

    // MARK: - Limits

    /// Feed items are ephemeral attention state, not history — capped so a
    /// long-running session with many transient bells never grows this
    /// unbounded (terminal-notch-hud.md NC-C).
    private static let maxFeedItems = 20
    /// `isSearchFieldVisible` shows the field once the editors list is at
    /// least this long — below it, the list is already short enough that
    /// scanning it beats typing (a query already in progress stays visible
    /// regardless of count, see `isSearchFieldVisible`).
    private static let searchFieldThreshold = 6

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.screenParametersDidChange),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Dock/undock, resolution change, display (dis)connect: a screen can
    /// gain or lose its notch, so this both repositions an existing strip
    /// and re-evaluates whether one should exist at all.
    @objc
    private func screenParametersDidChange() {
        activateIfEnabled()
    }

    // MARK: - Registry

    /// Registers a workspace so its editor row appears in the strip/panel.
    /// Called from `WorkspaceSceneRoot`'s window-lifecycle `.task` — every
    /// open workspace WINDOW, independent of whether it has ever opened a
    /// terminal — because the resting strip's left-wing count is "open
    /// editor windows", not "windows with a terminal" (unlike
    /// `TerminalAttentionCenter`, which only needs to route notification
    /// replies and so registers lazily from
    /// `installTerminalHandlersIfNeeded()`). Safe to call more than once for
    /// the same session.
    func register(_ session: WorkspaceSession) {
        entries.removeAll { $0.session == nil }
        guard !entries.contains(where: { $0.session === session }) else { return }
        entries.append(Entry(id: UUID(), session: session))
        refreshEditorRows()
    }

    func unregister(_ session: WorkspaceSession) {
        // Drop any attention-feed cards belonging to this closing window's
        // sessions while the session object is still alive to enumerate —
        // window teardown never fires `terminalSessionDidClearAttention`, so
        // without this a card could linger until Open/Send or the 20-item
        // cap evicted it.
        for controller in session.terminal.sessions {
            clearFeedItem(sessionID: controller.id)
        }
        entries.removeAll { $0.session == nil || $0.session === session }
        refreshEditorRows()
    }

    /// Recomputes `editorRows`/`attentionCount` from the live weak sessions
    /// and repositions/resizes the panel if one is showing. Called on
    /// register/unregister and from `WorkspaceSession`'s bell/clear/exit
    /// hooks — NOT on a timer or per-frame: the derivation is O(open
    /// windows × their terminal sessions), cheap, but there is no reason to
    /// poll when every input already has a call site that changes it.
    ///
    /// Deliberately does NOT touch `theme` — `refreshTheme()` reads
    /// `NSApp.effectiveAppearance`, which is `nil` (a crashing
    /// implicitly-unwrapped optional) in a headless `swift test` process
    /// with no `NSApplication` instance, and this method is exactly the one
    /// every headless registry test calls directly. Theme refresh instead
    /// happens only at the points that actually present something on
    /// screen (`presentPanel`, opening the peek panel) — see
    /// `refreshTheme()`'s doc comment.
    func refreshEditorRows(animated: Bool = false) {
        entries.removeAll { $0.session == nil }
        let inputs = entries.compactMap { entry -> CompanionEditorInput? in
            guard let session = entry.session else { return nil }
            return Self.companionInput(
                for: session, id: entry.id, windowNumber: Self.windowNumber(for: session))
        }
        editorRows = CompanionEditorRow.editorRows(from: inputs)
        attentionCount = editorRows.reduce(0) { $0 + $1.attentionCount }
        reposition(animated: animated)
    }

    /// What the Ensembles section lists — `editorRows`
    /// narrowed by `searchQuery` through the pure `CompanionEditorRow`
    /// filter (NC-A). The usage strip and attention feed are never filtered
    /// (terminal-notch-hud.md NC-B, "Search/filter": scope is the editors
    /// list only).
    var visibleEditorRows: [CompanionEditorRow] {
        CompanionEditorRow.filteredEditorRows(editorRows, query: searchQuery)
    }

    /// The field only earns its place once the list is long enough to
    /// justify typing over scanning — but a query already in progress
    /// (e.g. the list just shrank below the threshold as a result of
    /// typing) keeps the field visible so clearing it does not also make
    /// the field itself vanish out from under the user.
    var isSearchFieldVisible: Bool {
        editorRows.count >= Self.searchFieldThreshold
            || !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Whether the strip shows its expanded, two-sided layout (coordinator
    /// decision: compact while resting; expands to the wings pill on
    /// hover-dwell or click). Drives `CompanionWingsView`'s layout.
    ///
    /// Attention widens only the plain-display pill. The resting notch
    /// strip keeps its one leading wing — a wider strip would cover the
    /// menu bar's "«" overflow chevron right of the notch — and shows the
    /// attention count there. On an island the wider frame is for hover
    /// only, and a bell takes the attention drop-down instead.
    var isStripExpanded: Bool {
        hoverState != .resting || (attentionCount > 0 && surface == .pill)
    }

    /// Whether a bell may route into an open attention feed. An island
    /// panel offers Usage only, so it has no feed to show; the menu bar
    /// card's Up next has one while the card is open.
    var isAttentionFeedAvailable: Bool { surface != .island || isMenuPopoverShown }

    /// The island capsule's right-lobe figure: the most constrained
    /// front-line usage window, or `nil` with no usage data.
    var islandUsageGlance: NotchIslandUsageGlance? {
        NotchIslandUsageGlance.resolve(
            frontLine: usageFrontLine, observedAt: usageObservedAt, mode: usageDisplayMode,
            displayName: { UsageProviderRegistry.descriptor(for: $0)?.displayName ?? $0.rawValue },
            now: Date())
    }

    /// Whether the panel (tabs and content) is showing: pinned, or peeking
    /// while hover-to-open is on. With it off, peeking is only the wider
    /// wings strip and a click opens the panel.
    var isPanelOpen: Bool {
        hoverState == .pinned || (hoverState == .peeking && opensOnHover)
    }

    /// Which companion surfaces should exist for the current surface, usage
    /// glance position, and "Show notch companion" setting. A plain screen
    /// with the pill off has no companion.
    var presence: CompanionPresence {
        CompanionPresence.resolve(
            surface: surface, position: usageGlancePosition,
            isEnabled: preferenceStore.isEnabled(), allowsPill: allowsPill)
    }

    /// The companion is a status item in the menu bar, so the notch strip,
    /// the pills, and their panels do not exist.
    private var showsUsageInMenuBar: Bool {
        usageGlancePosition == .menuBar
    }

    // MARK: - Agents (collapsed status, mascot, Ensembles, Up next)

    /// The recognised agent CLI behind a terminal (`resolvedAgentProvider`,
    /// `Support/AgentIdentity.swift`): the process spec's provider when Rafu
    /// launched it, else the hook session, the foreground process, or the
    /// sticky title match. `nil` for an ordinary shell.
    static func agentIdentity(of controller: WorkspaceTerminalController) -> ConductorCLIID? {
        controller.resolvedAgentProvider
    }

    static func terminalInput(
        for controller: WorkspaceTerminalController, windowID: UUID? = nil,
        boardID: UUID? = nil, cardID: UUID? = nil
    ) -> NotchTerminalInput {
        let store = AgentActivityStore.shared
        let session = store.trackedSession(for: controller)
        return NotchTerminalInput(
            id: controller.id,
            title: controller.presentedTitle,
            cli: agentIdentity(of: controller),
            status: controller.status,
            isProducingOutput: controller.isProducingOutput,
            cause: controller.lastAttentionCause,
            boardID: boardID,
            cardID: cardID,
            windowID: windowID,
            trackedPhase: AgentTrackedPhase.terminalPhase(
                session: session, status: controller.status, now: store.now),
            subagents: AgentTrackedPhase.subagentEntries(session))
    }

    /// Every agent terminal in every registered window. Reads only the
    /// terminal list and each controller's status flags, so a card drag on an
    /// Ensemble never invalidates the collapsed strip that reads this.
    var allAgentRows: [NotchAgentRow] {
        entries.flatMap { entry -> [NotchAgentRow] in
            guard let session = entry.session else { return [] }
            return NotchAgentRow.rows(
                from: session.terminal.sessions.map {
                    Self.terminalInput(for: $0, windowID: entry.id)
                })
        }
    }

    /// Agents seen through hooks that run outside every Rafu terminal (X11).
    /// They count toward the collapsed strip and the mascot.
    var externalAgentRows: [NotchAgentRow] {
        AgentActivityStore.shared.externalNotchRows(
            excluding: entries.flatMap { $0.session?.terminal.sessions ?? [] })
    }

    var agentSummary: NotchAgentSummary {
        NotchAgentSummary.summarize(allAgentRows + externalAgentRows)
    }

    var mascotState: RafuMascotState {
        RafuMascotState.resolve(agents: allAgentRows + externalAgentRows)
    }

    /// Agents in Rafu terminals that ask the person to look, most urgent
    /// first.
    var upNextRows: [NotchAgentRow] {
        NotchAgentRow.byUrgency(allAgentRows.filter { $0.phase.needsAttention })
    }

    /// The host that shows outside agents that need the person
    /// (`CompanionHost.outsideNotices`): the surface in use, never two.
    var outsideNoticesHost: CompanionHost? {
        CompanionHost.outsideNotices(
            surface: surface, position: usageGlancePosition, allowsPill: allowsPill)
    }

    /// Up next for `host`: Rafu agents that need the person, plus outside
    /// agents that need them when `host` is the surface in use.
    func upNextRows(for host: CompanionHost) -> [NotchAgentRow] {
        Self.upNextRows(
            rafu: allAgentRows,
            outside: host == outsideNoticesHost ? externalAgentRows : [])
    }

    /// Pure core of `upNextRows(for:)`: every row that needs the person,
    /// most urgent first; Rafu rows before outside rows of equal urgency.
    nonisolated static func upNextRows(rafu: [NotchAgentRow], outside: [NotchAgentRow])
        -> [NotchAgentRow]
    {
        NotchAgentRow.byUrgency((rafu + outside).filter { $0.phase.needsAttention })
    }

    /// One window's open Ensembles with their agents, plus agents outside any
    /// Ensemble. Reads each board's cards, so only the open Ensembles section
    /// calls it.
    func windowAgents(for entryID: UUID) -> NotchWindowAgents {
        guard let session = entries.first(where: { $0.id == entryID })?.session else {
            return .empty
        }
        return Self.windowAgents(for: session, windowID: entryID)
    }

    static func windowAgents(for session: WorkspaceSession, windowID: UUID) -> NotchWindowAgents {
        var placement: [UUID: (board: UUID, card: UUID)] = [:]
        var boards: [NotchBoardInput] = []
        let open = session.canvas.boards.values.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        for board in open {
            let cards = board.cards
            boards.append(
                NotchBoardInput(id: board.id.rawValue, title: board.title, cardCount: cards.count))
            for card in cards {
                guard case .terminal(let groupID) = card.content,
                    let group = session.terminal.terminalGroup(groupID)
                else { continue }
                for pane in group.panes {
                    if let sessionID = pane.sessionID {
                        placement[sessionID] = (board.id.rawValue, card.id.rawValue)
                    }
                }
            }
        }
        let terminals = session.terminal.sessions.map { controller in
            terminalInput(
                for: controller, windowID: windowID,
                boardID: placement[controller.id]?.board,
                cardID: placement[controller.id]?.card)
        }
        return NotchWindowAgents.build(boards: boards, terminals: terminals)
    }

    /// Takes the person to an agent: its window, its Ensemble, its node.
    /// Presentation only — it starts nothing and sends no input. An agent in a
    /// terminal outside any Ensemble goes through the attention center's
    /// existing reveal route. Collapses the panel afterwards.
    func focusAgent(_ row: NotchAgentRow) {
        entries.removeAll { $0.session == nil }
        guard let windowID = row.windowID,
            let session = entries.first(where: { $0.id == windowID })?.session
        else { return }
        if let boardRaw = row.boardID, let cardRaw = row.cardID,
            let board = session.canvas.boards[CanvasID(rawValue: boardRaw)]
        {
            let card = CanvasCardID(rawValue: cardRaw)
            session.presentCanvasBoard(board)
            board.select([card])
            board.revealCard(card)
            session.terminal.terminalController(sessionID: row.id)?.clearAttention()
            clearFeedItem(sessionID: row.id)
            WorkspaceWindowRegistry.shared.focus(session: session)
        } else {
            revealFeedSession(row.id)
        }
        escapePressed()
    }

    /// Opens an Ensemble in its window. Presentation only.
    func openEnsemble(windowID: UUID, boardID: UUID) {
        entries.removeAll { $0.session == nil }
        guard let session = entries.first(where: { $0.id == windowID })?.session,
            let board = session.canvas.boards[CanvasID(rawValue: boardID)]
        else { return }
        session.presentCanvasBoard(board)
        WorkspaceWindowRegistry.shared.focus(session: session)
        escapePressed()
    }

    /// Lets the mascot bounce once per ready reply, however often it redraws.
    func claimMascotBounce(_ id: UUID) -> Bool { bounceLedger.claim(id) }

    // MARK: - Display preferences

    /// Reads the notch's display preferences from defaults. Called when the
    /// companion activates and when a Settings control changes one; a view
    /// never reads defaults itself.
    func reloadDisplayPreferences() {
        let store = displayPreferences
        isMascotEnabled = store.isMascotEnabled()
        allowsPill = store.showsPillOnPlainDisplays()
        let position = store.usageGlancePosition()
        if usageGlancePosition != position { usageGlancePosition = position }
        applySurfacePolicy()
    }

    /// The preferences the current `surface` filters: on an island the panel
    /// offers Usage only and hover never opens it. Reads the stored
    /// preferences but never writes them — the remembered tab and the
    /// section flags survive for the next notched screen.
    private func applySurfacePolicy() {
        let store = displayPreferences
        visibleSections = NotchSection.offered(store.visibleSections(), on: surface)
        selectedSection = NotchSection.selection(
            remembered: store.selectedSection(), visible: visibleSections)
        opensOnHover = CompanionHoverPolicy.effectiveOpensOnHover(
            preference: store.opensOnHover(), surface: surface)
        menuBarSections = NotchSection.offered(store.visibleSections(), host: .menuBar)
        if !menuBarSections.contains(menuBarSelection) {
            menuBarSelection = NotchSection.selection(
                remembered: store.menuBarSelectedSection(), visible: menuBarSections)
        }
        if panel != nil { syncNowPlaying() }
    }

    /// Sets `surface` without a screen, then applies its policy. Headless
    /// tests only — production derives `surface` from the companion's
    /// screen.
    func setSurfaceForTesting(_ surface: NotchCompanionSurface) {
        self.surface = surface
        applySurfacePolicy()
    }

    /// The hover dwell has started and not fired yet. Headless tests only.
    var isHoverDwellPendingForTesting: Bool { dwellTimer != nil }

    /// The mouse-out grace has started and not fired yet. Headless tests
    /// only.
    var isHoverGracePendingForTesting: Bool { graceTimer != nil }

    /// Fires a pending hover dwell now, as its timer would. Headless tests
    /// only — they never wait on the real timer.
    func fireHoverDwellForTesting() {
        guard let timer = dwellTimer else { return }
        timer.invalidate()
        dwellTimerFired()
    }

    /// The surface for `metrics`. With the pill off on a plain screen there
    /// is no companion at all; `.pill` still names that screen's kind so
    /// the policy stays the plain-display one.
    private static func surfaceKind(for metrics: NotchScreenMetrics) -> NotchCompanionSurface {
        NotchCompanionGeometry.surface(for: metrics, allowsPill: true) ?? .pill
    }

    /// Now Playing listens (observers only, no Apple events) while the strip
    /// exists and its section is on; otherwise it is stopped.
    private func syncNowPlaying() {
        if visibleSections.contains(.nowPlaying) { nowPlaying.start() } else { nowPlaying.stop() }
    }

    /// A Settings change: reload, then rebuild or reposition the strip (the
    /// pill setting can add or remove it).
    func displayPreferencesDidChange() {
        activateIfEnabled()
    }

    func select(_ section: NotchSection) {
        guard visibleSections.contains(section), section != selectedSection else { return }
        selectedSection = section
        displayPreferences.setSelectedSection(section)
        if section == .usage { refreshUsage() }
    }

    // MARK: - Hosts (notch panel, island card, menu bar card)

    /// The tabs `host` shows.
    func sections(for host: CompanionHost) -> [NotchSection] {
        host == .menuBar ? menuBarSections : visibleSections
    }

    /// The tab `host` shows now.
    func selection(for host: CompanionHost) -> NotchSection {
        host == .menuBar ? menuBarSelection : selectedSection
    }

    /// Selects a tab on `host`. The menu bar card remembers its own tab.
    func select(_ section: NotchSection, host: CompanionHost) {
        guard host == .menuBar else {
            select(section)
            return
        }
        guard menuBarSections.contains(section), section != menuBarSelection else { return }
        menuBarSelection = section
        displayPreferences.setMenuBarSelectedSection(section)
        if section == .usage { refreshUsage() }
    }

    /// Shows the usage surface for a `rafu://usage` widget link: the menu
    /// bar card when the usage glance is in the menu bar, else the notch or
    /// island panel on its Usage section, else Settings ▸ Usage
    /// (`UsageDeepLinkTarget`). Presentation only: it reads usage
    /// (TTL-gated) and never starts a process.
    func revealUsage(openSettings: @MainActor () -> Void) {
        let target = UsageDeepLinkTarget.resolve(
            hasMenuBarItem: usageMenuBarItem != nil, hasPanel: panel != nil,
            panelOffersUsage: visibleSections.contains(.usage))
        switch target {
        case .menuBarCard:
            usageMenuBarItem?.revealCard()
            select(.usage, host: .menuBar)
        case .companionPanel:
            select(.usage)
            if hoverState != .pinned { clicked() }
            refreshUsage()
        case .settings:
            openSettings()
        }
    }

    /// The menu bar card opens: Up next first when something waits for
    /// the person (`CompanionMenuSelection.initial`), and bells now land
    /// in its feed. Called by `UsageMenuBarItem` before the popover shows.
    func menuPopoverWillShow() {
        let store = displayPreferences
        menuBarSections = NotchSection.offered(store.visibleSections(), host: .menuBar)
        menuBarSelection = CompanionMenuSelection.initial(
            remembered: store.menuBarSelectedSection(), offered: menuBarSections,
            attention: upNextRows(for: .menuBar).count)
        isMenuPopoverShown = true
    }

    /// The menu bar card closed. Feed cards hold a terminal snippet, which
    /// must not outlive the surface that showed it (ADR 0016), so they are
    /// dropped here when no notch panel shows them. The terminals keep
    /// their attention state, so they stay in Up next as rows.
    func menuPopoverDidClose() {
        isMenuPopoverShown = false
        searchQuery = ""
        guard panel == nil, !feedItems.isEmpty else { return }
        feedItems = []
    }

    /// The view's ONLY write path to `searchQuery` — per-keystroke and
    /// deliberately unanimated (AGENTS: "Typing-path work targets one
    /// display frame"; a spring resize on every keystroke would read as
    /// jittery, not intentional).
    func setSearchQuery(_ query: String) {
        searchQuery = query
        reposition()
    }

    /// The testable seam (terminal-notch-hud.md NC-B): pure given a
    /// `WorkspaceSession`'s already-live state, so a headless test can
    /// construct a real `WorkspaceSession()` (no process ever spawns —
    /// `WorkspaceTerminalController` only spawns when a `TerminalHostView`
    /// mounts, per ADR 0004), set its `descriptor`/`gitSnapshot`, add
    /// terminal sessions via `newTerminalTab()` +
    /// `markRunningForTesting()`, and assert the mapped `CompanionEditorInput`
    /// directly — the same fixture pattern `TerminalAttentionTests.swift`
    /// already uses, so no separate "fake session" type is needed.
    static func companionInput(
        for session: WorkspaceSession, id: UUID, windowNumber: Int
    ) -> CompanionEditorInput {
        CompanionEditorInput(
            id: id,
            name: session.descriptor?.displayName ?? RafuBuildInformation.appName,
            windowNumber: windowNumber,
            git: session.gitSnapshot.map(companionGitInput),
            statuses: session.terminal.sessions.map(\.status)
        )
    }

    static func companionGitInput(_ snapshot: GitSnapshot) -> CompanionGitInput {
        CompanionGitInput(
            branch: snapshot.branch,
            ahead: snapshot.aheadCount,
            behind: snapshot.behindCount,
            dirtyCount: snapshot.changes.count,
            isDetached: snapshot.isDetached,
            isUnborn: snapshot.isUnborn
        )
    }

    /// 1-based display number from `WorkspaceWindowRegistry`'s own
    /// zero-based `registrationOrder` — `0` (never a valid 1-based number)
    /// when the session has not registered there yet, which self-corrects
    /// on the next `refreshEditorRows()` (`WorkspaceWindowRegistry`
    /// registers from the same `WorkspaceSceneRoot` window-lifecycle path
    /// this model does).
    private static func windowNumber(for session: WorkspaceSession) -> Int {
        guard
            let order = WorkspaceWindowRegistry.shared.entries[ObjectIdentifier(session)]?
                .registrationOrder
        else { return 0 }
        return order + 1
    }

    /// Focuses the workspace window backing a companion row (row click). A
    /// no-op once the session's window has closed. The attention chip's
    /// per-session reveal is `revealFeedSession(_:)` below, which also
    /// clears that session's feed card.
    func focusEditor(_ id: UUID) {
        entries.removeAll { $0.session == nil }
        guard let session = entries.first(where: { $0.id == id })?.session else { return }
        WorkspaceWindowRegistry.shared.focus(session: session)
    }

    // MARK: - Attention feed (terminal-notch-hud.md NC-C)

    /// Adds (or replaces) a feed card. A session already in the feed is
    /// dropped and re-inserted at the front — a second bell from the same
    /// session REPLACES its card rather than duplicating it, regardless of
    /// timestamp ordering — then `CompanionFeedItem.attentionFeed(from:)`
    /// re-sorts newest-first and the result is capped to `maxFeedItems`
    /// (oldest dropped first). Called from
    /// `WorkspaceSession.notifyIfNeeded(for:)`'s feed-vs-drop-down
    /// arbitration; a no-op on panel geometry when no panel is showing
    /// (`reposition()` guards on `panel != nil`).
    func pushFeedItem(_ item: CompanionFeedItem) {
        var items = feedItems
        items.removeAll { $0.sessionID == item.sessionID }
        items.insert(item, at: 0)
        feedItems = Array(CompanionFeedItem.attentionFeed(from: items).prefix(Self.maxFeedItems))
        reposition()
    }

    /// Removes a session's feed card, for any reason its `.bell` cleared
    /// (reveal, reply, tab selection) — wired from
    /// `WorkspaceSession.terminalSessionDidClearAttention(_:)`. A no-op for
    /// an unknown session id.
    func clearFeedItem(sessionID: UUID) {
        let before = feedItems.count
        feedItems.removeAll { $0.sessionID == sessionID }
        guard feedItems.count != before else { return }
        reposition()
    }

    /// Reply-field engagement — one of two fields (alongside the search
    /// field) that can make the panel key. Never sets `allowsKeyStatus`
    /// directly — see `updateKeyStatus()`, the ONE place that arbitrates
    /// between the two so one field's disengagement can never stomp on the
    /// other's still-active engagement.
    func engageReply() {
        guard panel != nil else { return }
        isReplyEngaged = true
        updateKeyStatus()
    }

    func disengageReply() {
        isReplyEngaged = false
        updateKeyStatus()
    }

    /// Search-field engagement — mirrors `engageReply()`/`disengageReply()`
    /// exactly, on the other half of `updateKeyStatus()`'s arbiter.
    func engageSearch() {
        guard panel != nil else { return }
        isSearchEngaged = true
        updateKeyStatus()
    }

    func disengageSearch() {
        isSearchEngaged = false
        updateKeyStatus()
    }

    /// THE key-status arbiter: the ONE place `allowsKeyStatus` is ever
    /// written from an engage/disengage call — two independently focusable
    /// fields (a feed card's reply field, the search field) means neither
    /// can safely flip `allowsKeyStatus` on its own `onChange(of:
    /// isFocused)` callback, since AppKit's focus hop from one field to the
    /// other can transiently report BOTH as unfocused mid-transition; a
    /// naive `disengageX() { allowsKeyStatus = false }` on the outgoing
    /// field would drop key status out from under the incoming one. Instead
    /// every engage/disengage only flips its own `is*Engaged` flag and
    /// re-derives `wantsKey` from BOTH here. `wasKey`/`makeKey()` is
    /// edge-guarded (only called on a false→true transition) because
    /// `makeKey()` reactivates focus-follow behavior that would be
    /// redundant — and, per NC-B/NC-C's non-activating-panel contract,
    /// never activates the app — on an already-key panel.
    private func updateKeyStatus() {
        guard let panel else { return }
        let wantsKey = isReplyEngaged || isSearchEngaged
        let wasKey = panel.allowsKeyStatus
        panel.allowsKeyStatus = wantsKey
        if wantsKey && !wasKey {
            panel.makeKey()
        }
    }

    /// The "nothing should be able to make this panel key anymore" path —
    /// used by `panelDidResignKey()` and `teardown()`, NEVER by a normal
    /// disengage: those two call sites need both flags AND
    /// `allowsKeyStatus` false unconditionally (not re-derived through
    /// `updateKeyStatus()`, which would leave `allowsKeyStatus` true if the
    /// OTHER field's flag happened to still read true at that instant).
    private func clearKeyEngagement() {
        isReplyEngaged = false
        isSearchEngaged = false
        panel?.allowsKeyStatus = false
    }

    /// Sanitizes through the ONE approved path
    /// (`TerminalAttentionPolicy.sanitizedReply`, matching
    /// `NotchHUDController.sendReply()` verbatim), delivers through the
    /// injected `deliverReply` route, then clears the card — an empty reply
    /// is a no-op (the card stays up).
    func sendReply(_ text: String, to sessionID: UUID) {
        guard let sanitized = TerminalAttentionPolicy.sanitizedReply(text) else { return }
        deliverReply(sanitized, sessionID)
        clearFeedItem(sessionID: sessionID)
    }

    /// "Open": reveals the session's tab (focusing its owning window) and
    /// clears its feed card — mirroring `NotchHUDController
    /// .revealSessionAndDismiss()`'s "reveal clears bell" reasoning.
    func revealFeedSession(_ sessionID: UUID) {
        revealSession(sessionID)
        clearFeedItem(sessionID: sessionID)
    }

    // MARK: - Activation (existence, not hover state)

    /// Creates (or tears down) the persistent strip window. Idempotent —
    /// safe to call from app launch, a preference change (NC-E), and every
    /// screen-parameter change. `nil` panel + disabled/non-notch is already
    /// the correct end state, so this never no-ops into a half-torn-down
    /// window.
    func activateIfEnabled() {
        let screen = NotchScreenAdapter.companionMetrics()
        if let screen {
            let kind = Self.surfaceKind(for: screen)
            if surface != kind { surface = kind }
        }
        reloadDisplayPreferences()
        let wanted =
            screen.map {
                CompanionPresence.resolve(
                    surface: Self.surfaceKind(for: $0), position: usageGlancePosition,
                    isEnabled: preferenceStore.isEnabled(), allowsPill: allowsPill)
            } ?? .none
        syncUsageMenuBarItem(installed: wanted.showsMenuBarItem)
        observeAgentTurnEnds()
        guard wanted.showsPanel,
            let metrics = screen,
            NotchCompanionGeometry.restingFrame(for: metrics, allowsPill: allowsPill) != nil
        else {
            // The status item reads usage too, so its refresh survives.
            teardown(keepingUsageRefresh: wanted.showsMenuBarItem)
            return
        }
        if panel == nil {
            presentPanel(metrics: metrics)
        } else {
            reposition()
        }
    }

    /// Adds or removes the usage status item. Installing reads usage once
    /// (TTL-gated); the item then redraws when the model's usage changes.
    private func syncUsageMenuBarItem(installed: Bool) {
        if installed {
            guard usageMenuBarItem == nil else { return }
            usageMenuBarItem = UsageMenuBarItem(model: self)
            refreshUsage()
        } else {
            usageMenuBarItem?.remove()
            usageMenuBarItem = nil
        }
        rearmUsageWake()
    }

    /// Resolved from the same inputs `WorkspaceSceneRoot` binds through the
    /// SwiftUI environment (`themeChoice` default + effective appearance),
    /// mirroring `WorkspaceSession.hudThemeProvider`'s "not read from an
    /// environment" doc comment — the strip belongs to no scene either.
    /// Guarded on `panel != nil` (skipped from `presentPanel`, which sets it
    /// unconditionally before creating the panel): every OTHER call site is
    /// reachable even with no panel showing (a headless test calling
    /// `clicked()`/hover directly, or `dwellTimerFired()` racing a
    /// same-tick teardown), and `NSApp.effectiveAppearance` is a crashing
    /// implicitly-unwrapped `nil` with no `NSApplication` instance — nothing
    /// is on screen to theme in that case anyway.
    private func refreshTheme() {
        guard panel != nil else { return }
        theme = RafuThemeCatalog.resolvedForCurrentAppearance()
    }

    private func presentPanel(metrics: NotchScreenMetrics) {
        guard
            let frame = NotchCompanionGeometry.restingFrame(for: metrics, allowsPill: allowsPill)
        else { return }
        theme = RafuThemeCatalog.resolvedForCurrentAppearance()
        updateStripMetrics(metrics, restingFrame: frame)
        let panel = NotchHUDPanel(contentRect: frame)
        panel.onCancel = { [weak self] in self?.escapePressed() }
        // Key status went elsewhere (e.g. the user clicked out while a feed
        // card's reply field was engaged): disengage so a later engagement
        // starts non-activating again — mirrors
        // `NotchHUDController.panelDidResignKey` exactly.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        let hostingView = NotchHUDPassthroughHostingView(rootView: NotchCompanionView(model: self))
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        // Click-through regions must stay EMPTY, even over the notch-only
        // resting strip: `NotchHUDPassthroughHostingView.hitTest` returns
        // `nil` inside a click-through region, which also suppresses
        // SwiftUI's `.onHover` there — a click-through notch region would
        // make the notch-only resting strip un-hoverable, so attention
        // could never dwell-expand it. The v1 drop-down sets its own
        // `clickThroughRegions` independently and is unaffected.
        panel.clickThroughRegions = []
        // No window shadow while resting: `NSPanel`'s shadow paints a rim
        // light around ALL edges — including the top — which reads as a
        // bright outline separating the strip's black from the physical
        // notch it must appear continuous with (the same seamlessness bug
        // the v1 drop-down's band fix addressed). `reposition()` re-enables
        // it for the peeked/pinned panel, where depth against window
        // content below is wanted.
        panel.hasShadow = false
        self.panel = panel
        panel.orderFrontRegardless()
        syncNowPlaying()
        refreshEditorRows()
        // The island capsule shows a usage ring at rest, so read usage once
        // (TTL-gated) when it appears. No periodic timer at rest.
        if surface == .island { refreshUsage() }
        rearmUsageWake()
    }

    /// Records the strip's band, height and notch-ness from the screen the
    /// companion is on, for the views that size themselves to them.
    private func updateStripMetrics(_ metrics: NotchScreenMetrics, restingFrame: CGRect) {
        // Assign only on change: `@Observable` notifies on every write.
        let band = NotchHUDGeometry.bandInset(for: metrics)
        if bandInset != band { bandInset = band }
        let notched = NotchHUDGeometry.notchRect(for: metrics) != nil
        if hasPhysicalNotch != notched { hasPhysicalNotch = notched }
        if stripHeight != restingFrame.height { stripHeight = restingFrame.height }
        let radius = NotchIslandGeometry.openCornerRadius(for: metrics)
        if islandOpenCornerRadius != radius { islandOpenCornerRadius = radius }
        let kind = Self.surfaceKind(for: metrics)
        if surface != kind {
            surface = kind
            applySurfacePolicy()
        }
    }

    @objc
    private func panelDidResignKey() {
        clearKeyEngagement()
    }

    // MARK: - Usage refresh (terminal-notch-hud.md NC-D)

    /// Recomputes `usageSnapshots` OFF the main actor (the registry's
    /// strategies — file reads today, network calls in later phases — all
    /// run inside `Task.detached`) and assigns the result back on the main
    /// actor when done. Without `force` this is an "a surface opened"
    /// request: it reads only when the last read is more than
    /// `UsageRefreshSchedule.openStaleness` old. With `force` (the refresh
    /// button, Settings) it always reads, or joins a read that already runs.
    /// Returns the task (`nil` when fresh data suppressed the call) so tests
    /// can await completion instead of polling.
    @discardableResult
    func refreshUsage(force: Bool = false) -> Task<Void, Never>? {
        let now = usageNow()
        if force {
            if !usageSchedule.shouldStartManualRefresh() { return usageRefreshTask }
        } else if !usageSchedule.shouldRefreshOnOpen(at: now) {
            return nil
        }
        return startUsageRead(at: now)
    }

    /// Starts one read. The caller has checked that none runs.
    private func startUsageRead(at now: Date) -> Task<Void, Never>? {
        guard usageSchedule.begin(at: now) else { return usageRefreshTask }
        isUsageRefreshing = true
        let reader = usageReader
        let task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                let snapshots = await reader.snapshots(now: now)
                let ids = reader.descriptors.map(\.id)
                let consent = Set(
                    reader.descriptors.filter { $0.authPattern.connectAffordance != .none }
                        .map(\.id).filter(reader.hasNetworkConsent))
                let enabled = Set(ids.filter(reader.isEnabled))
                return (snapshots, consent, enabled, ids)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.applyUsageRefresh(
                fresh: result.0, now: now, networkConsent: result.1, enabled: result.2,
                registryOrder: result.3)
        }
        usageRefreshTask = task
        return task
    }

    private func applyUsageRefresh(
        fresh: [UsageSnapshot], now: Date, networkConsent: Set<UsageProviderID>,
        enabled: Set<UsageProviderID>, registryOrder: [UsageProviderID]
    ) {
        let merged = UsageSnapshotRetention.merge(
            previous: usageSnapshots, previousObservedAt: usageObservedAt, fresh: fresh,
            now: now, enabled: enabled, networkConsent: networkConsent,
            registryOrder: registryOrder)
        usageSnapshots = merged.snapshots
        usageObservedAt = merged.observedAt
        usageStaleProviderIDs = merged.staleProviderIDs
        usageNetworkConsentIDs = networkConsent
        isUsageRefreshing = false
        // A read fails only when providers show stale data and none came
        // back fresh; "no providers at all" is a success.
        let failed = fresh.isEmpty && !merged.staleProviderIDs.isEmpty
        usageSchedule.finish(at: usageNow(), succeeded: !failed)
        rearmUsageWake()
        publishWidgetSnapshot()
    }

    /// Shares the current usage and the ring settings with the WidgetKit
    /// extension. It reloads the widget only when a shown value changed.
    private func publishWidgetSnapshot() {
        widgetSnapshotPublisher.publish(
            snapshots: usageSnapshots, observedAt: usageObservedAt,
            stale: usageStaleProviderIDs, mode: usageDisplayMode, palette: usageRingPalette,
            now: usageNow())
    }

    func setUsageDisplayMode(_ mode: UsageDisplayMode) {
        guard mode != usageDisplayMode else { return }
        usageDisplayMode = mode
        usageDisplayModeStore.setMode(mode)
        publishWidgetSnapshot()
    }

    func setUsageRingPalette(_ palette: UsageRingPalette) {
        guard palette != usageRingPalette else { return }
        usageRingPalette = palette
        usageRingPaletteStore.setPalette(palette)
        publishWidgetSnapshot()
    }

    /// Everything one provider card needs, derived from the last refresh.
    /// `nil` when the provider has no snapshot.
    func usageCard(for id: UsageProviderID) -> UsageProviderCardModel? {
        guard let snapshot = usageSnapshots.first(where: { $0.providerID == id }) else {
            return nil
        }
        return UsageProviderCardModel(
            snapshot: snapshot, observedAt: usageObservedAt[id],
            isStale: usageStaleProviderIDs.contains(id),
            hasNetworkConsent: usageNetworkConsentIDs.contains(id))
    }

    // MARK: - Usage schedule wake-up

    /// What is on screen decides the fallback cadence.
    private var usageCadence: UsageRefreshSchedule.Cadence {
        .resolve(
            hasStatusItem: usageMenuBarItem != nil || usageSurfaceOverrideForTesting,
            hasPanel: panel != nil, isPinned: hoverState == .pinned)
    }

    /// Sleeps until the schedule's next read, replacing any earlier wake-up.
    /// Safe to call after any change; with nothing on screen it only cancels.
    private func rearmUsageWake(minimumDelay: TimeInterval = 0) {
        usageWakeTask?.cancel()
        usageWakeTask = nil
        guard let due = usageSchedule.next(cadence: usageCadence) else { return }
        let delay = max(due.timeIntervalSince(usageNow()), minimumDelay, 0)
        usageWakeTask = Task { [weak self] in
            // Lets the system coalesce this wake-up with others.
            try? await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 10))
            guard !Task.isCancelled, let self else { return }
            self.usageWakeFired()
        }
    }

    /// The wake-up: read if due, then plan the next one. Internal for tests.
    func usageWakeFired() {
        usageWakeTask = nil
        let now = usageNow()
        guard usageSchedule.isDue(at: now, cadence: usageCadence) else {
            rearmUsageWake()
            return
        }
        // Nobody can see a locked or sleeping screen, and a read could raise
        // a Keychain prompt behind it: look again soon instead.
        guard RafuMotionGate.shared.isScreenActive else {
            rearmUsageWake(minimumDelay: Self.usageInactiveRecheck)
            return
        }
        _ = startUsageRead(at: now)
        rearmUsageWake()
    }

    /// Agent turn ends (from the Activity tracking hooks) feed the schedule.
    private func observeAgentTurnEnds() {
        AgentActivityStore.shared.onTurnEnded = { [weak self] providers in
            self?.agentTurnsEnded(providers)
        }
    }

    /// Internal for tests. Ignored while nothing shows usage, and when none
    /// of the providers has its usage turned on.
    func agentTurnsEnded(_ providers: Set<AgentHookProvider>) {
        guard usageCadence != .none else { return }
        let reader = usageReader
        guard
            providers.contains(where: {
                reader.isEnabled(UsageRefreshTrigger.usageProvider(for: $0))
            })
        else { return }
        usageSchedule.receivedTurnEnd(at: usageNow())
        rearmUsageWake()
    }

    /// Removes the panel and its timers. `keepingUsageRefresh` leaves an
    /// in-flight usage read running for the usage status item, which stays.
    private func teardown(keepingUsageRefresh: Bool = false) {
        nowPlaying.stop()
        cancelTimers()
        removeIslandYieldMonitor()
        if !keepingUsageRefresh {
            usageRefreshTask?.cancel()
            usageRefreshTask = nil
            isUsageRefreshing = false
            usageSchedule.abort()
        }
        clearKeyEngagement()
        searchQuery = ""
        if let panel {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didResignKeyNotification, object: panel)
            panel.orderOut(nil)
        }
        panel = nil
        hoverState = .resting
        // Keeps a wake-up only while the status item still shows usage.
        rearmUsageWake()
    }

    /// Recomputes the panel's frame from the CURRENT screen for the CURRENT
    /// `hoverState` — resting stays the notch plus one leading wing
    /// (`restingStripFrame`), also while attention is active (only the
    /// plain-display pill widens for attention); peeking grows to
    /// the SAME wings pill (band height, no downward panel); pinned grows
    /// downward to `peekPanelFrame`, matching content height. Click-through
    /// regions are always empty (see `presentPanel`'s doc comment).
    ///
    /// `animated` (terminal-notch-hud.md NC-E, "Peek": "Spring expand,
    /// cross-fade under Reduce Motion"): `true` only at the two hover-state
    /// TRANSITION call sites (`dwellTimerFired()`/`clicked()` opening,
    /// `graceTimerFired()`/`escapePressed()` collapsing) — every other call
    /// site (register/unregister, feed push/clear, screen-parameter
    /// changes) is a passive content/geometry refresh of whatever state is
    /// already showing and stays instant, matching
    /// `NotchHUDController.reposition(animated:)`'s own `animated: false` at
    /// its passive call site. `NSWorkspace.shared
    /// .accessibilityDisplayShouldReduceMotion` is the same AppKit-level
    /// signal `NotchHUDController` already reads (not the SwiftUI
    /// `\.accessibilityReduceMotion` environment key, which has no
    /// environment to live in for a window-frame resize happening outside
    /// any view's `body`).
    private func reposition(animated: Bool = false) {
        guard let panel, let metrics = NotchScreenAdapter.companionMetrics() else { return }
        if let resting = NotchCompanionGeometry.restingFrame(for: metrics, allowsPill: allowsPill) {
            updateStripMetrics(metrics, restingFrame: resting)
        }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let shouldAnimate = animated && !reduceMotion
        if isPanelOpen {
            let frame = NotchCompanionGeometry.peekPanelFrame(
                for: metrics, contentHeight: peekContentHeight())
            panel.setFrame(frame, display: true, animate: shouldAnimate)
            panel.clickThroughRegions = []
            // The open notch or pill panel has concave shoulders
            // (`NotchCompanionView.outlineLimits`); beside them the panel
            // takes no clicks. The island card is a plain rounded card.
            panel.hitOutline = surface == .island ? nil : .open
            panel.hasShadow = true
            if surface == .island {
                installIslandYieldMonitor()
            } else {
                removeIslandYieldMonitor()
            }
            return
        }
        removeIslandYieldMonitor()
        let strip =
            isStripExpanded
            ? NotchCompanionGeometry.expandedFrame(for: metrics, allowsPill: allowsPill)
            : NotchCompanionGeometry.restingFrame(for: metrics, allowsPill: allowsPill)
        guard let frame = strip else {
            teardown()
            return
        }
        panel.setFrame(frame, display: true, animate: shouldAnimate)
        panel.clickThroughRegions = []
        panel.hitOutline = nil
        panel.hasShadow = false
    }

    // MARK: - Island yield (Dynamic Island screens only)

    /// Installs the global monitor that closes the island card when the
    /// person clicks or taps the system island. Global monitors see only
    /// events that go to OTHER apps (here: MenuBarAgent, which owns the
    /// system island), never clicks on Rafu's own card. Mouse-down global
    /// monitoring needs no Accessibility permission. The handler reads only
    /// the pointer location and never logs it.
    private func installIslandYieldMonitor() {
        guard islandYieldMonitor == nil else { return }
        islandYieldMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) {
            [weak self] _ in
            // Global monitor handlers run on the main thread.
            MainActor.assumeIsolated { self?.islandYieldCheck() }
        }
    }

    private func removeIslandYieldMonitor() {
        guard let monitor = islandYieldMonitor else { return }
        NSEvent.removeMonitor(monitor)
        islandYieldMonitor = nil
    }

    private func islandYieldCheck() {
        guard surface == .island, isPanelOpen,
            let metrics = NotchScreenAdapter.companionMetrics(),
            let zone = NotchIslandGeometry.systemZone(for: metrics),
            zone.contains(NSEvent.mouseLocation)
        else { return }
        escapePressed()
    }

    /// The open panel's total height: the strip row plus the fixed body.
    /// Fixed on purpose (see `NotchCompanionGeometry.openPanelBodyHeight`):
    /// content scrolls inside it, so switching tabs, a search keystroke, or a
    /// feed card never resizes the window. `internal` so tests can assert it.
    func peekContentHeight() -> CGFloat {
        stripHeight + NotchCompanionGeometry.openPanelBodyHeight
    }

    // MARK: - Hover / pin (terminal-notch-hud.md NC-A `CompanionHoverPolicy`)

    /// The whole strip/panel content reports ONE hover region (mirroring
    /// `NotchHUDView`'s single `.onHover`) — dwell only ever STARTS a peek
    /// from `.resting`, but once open, hovering the now-visible editors list
    /// (not just the wing that triggered it) must keep it open, so the
    /// dwell/grace pair is driven by entering/leaving the ENTIRE content,
    /// not per-wing.
    func hoverEntered() {
        graceTimer?.invalidate()
        graceTimer = nil
        guard hoverState == .resting, dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(
            withTimeInterval: CompanionHoverPolicy.dwellSeconds, repeats: false
        ) { [weak self] _ in
            // Timers fire on the main run loop; same discipline as
            // `WorkspaceTerminalController`'s quiescence timer.
            MainActor.assumeIsolated { self?.dwellTimerFired() }
        }
    }

    /// The view's hover report while the pointer is on the strip or panel.
    /// Starts the dwell once per entry: `isPointerInside` stays set until
    /// `hoverExited`, so an Escape with the pointer still on the strip does
    /// not open it again until the pointer leaves and returns.
    func hoverMoved() {
        guard !isPointerInside else { return }
        isPointerInside = true
        hoverEntered()
    }

    func hoverExited() {
        isPointerInside = false
        dwellTimer?.invalidate()
        dwellTimer = nil
        guard hoverState == .peeking, graceTimer == nil else { return }
        graceTimer = Timer.scheduledTimer(
            withTimeInterval: CompanionHoverPolicy.graceSeconds, repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.graceTimerFired() }
        }
    }

    private func dwellTimerFired() {
        dwellTimer = nil
        let next = CompanionHoverPolicy.onHoverEnter(hoverState)
        guard next != hoverState else { return }
        hoverState = next
        refreshTheme()
        // Usage is only worth reading once the panel shows it: a hover that
        // opens the panel refreshes (TTL-gated); a hover that only widens the
        // strip does not — except on an island, where the wider capsule
        // shows the usage percentage.
        if isPanelOpen || surface == .island { refreshUsage() }
        refreshEditorRows(animated: true)
    }

    private func graceTimerFired() {
        graceTimer = nil
        // Never collapse out from under a field the person is typing in: a
        // pointer that drifts off the panel mid-reply must not discard it.
        guard !isReplyEngaged, !isSearchEngaged else { return }
        let next = CompanionHoverPolicy.onHoverExitAfterGrace(hoverState)
        guard next != hoverState else { return }
        hoverState = next
        if hoverState == .resting {
            // Collapsing back to resting always starts the next peek with a
            // blank filter — this is a live narrowing of the CURRENT
            // session, not a saved/persisted search (brief: "no query
            // persistence across peek open/close").
            searchQuery = ""
            disengageSearch()
        }
        reposition(animated: true)
    }

    /// A click on a wing: pins open (or, already pinned, toggles back to a
    /// still-open peek) — `CompanionHoverPolicy.onClick` never returns
    /// `.resting`, so this always ends with the panel open and its rows
    /// fresh.
    ///
    /// On an island a click (or a touch-screen tap, which macOS delivers as
    /// a click) is a plain toggle (`CompanionHoverPolicy.onIslandTap`): an
    /// open card closes through the same path as Escape.
    func clicked() {
        // The usage glance lives in the menu bar: there is no island card.
        if showsUsageInMenuBar { return }
        if surface == .island, hoverState == .pinned {
            escapePressed()
            return
        }
        cancelTimers()
        hoverState =
            surface == .island
            ? CompanionHoverPolicy.onIslandTap(hoverState)
            : CompanionHoverPolicy.onClick(hoverState)
        refreshTheme()
        refreshEditorRows(animated: true)
        if hoverState == .pinned { refreshUsage() }
        // Pinned reads faster than resting (`UsageRefreshSchedule.Cadence`).
        rearmUsageWake()
    }

    /// Escape always collapses — `CompanionHoverPolicy.onEscape` always
    /// returns `.resting`, regardless of pin state — and always disengages
    /// reply first, so a collapse never leaves `allowsKeyStatus` true on a
    /// panel with no field left to focus. Because Escape ALWAYS reaches
    /// `.resting`, the search field is always cleared/disengaged too:
    /// deliberately NOT a two-stage "first Escape clears the filter,
    /// second Escape collapses" — that would contradict
    /// `CompanionHoverPolicy.onEscape`'s always-`.resting` contract.
    func escapePressed() {
        cancelTimers()
        disengageReply()
        let next = CompanionHoverPolicy.onEscape(hoverState)
        if next == .resting {
            searchQuery = ""
            disengageSearch()
        }
        guard next != hoverState else { return }
        hoverState = next
        rearmUsageWake()
        reposition(animated: true)
    }

    private func cancelTimers() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        graceTimer?.invalidate()
        graceTimer = nil
    }
}
