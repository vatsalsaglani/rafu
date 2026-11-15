import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// terminal-notch-hud.md NC-B: `NotchCompanionModel`'s MainActor-isolated
/// parts that do not require a real screen/window/timer — the weak-session
/// registry's hygiene, the `session → CompanionEditorInput` mapping seam
/// (`NotchCompanionModel.companionInput(for:id:windowNumber:)`), and
/// `focusEditor`'s no-op-on-unknown-id behavior. Each test constructs its
/// OWN `NotchCompanionModel()` (never `.shared`) and never calls
/// `activateIfEnabled()`, so no panel is ever created — mirroring
/// `NotchHUDControllerTests.swift`. Window creation, hit-testing, hover
/// dwell/grace timers, and screenshot-verified visual states are GUI-only
/// (terminal-notch-hud.md NC-B "Tests" section) and are NOT covered here.

@MainActor
private func session(named name: String, path: String) -> WorkspaceSession {
    let session = WorkspaceSession()
    session.descriptor = WorkspaceDescriptor(
        displayName: name, location: .local(LocalWorkspaceReference(path: path)))
    return session
}

// MARK: - Weak registry hygiene

@MainActor
private func registerDroppableSession(in model: NotchCompanionModel) {
    // The session lives only in this function's frame; once it returns, no
    // strong reference remains anywhere (the model's `Entry` is weak, and
    // `newTerminalTab()` is never called here, so `TerminalAttentionCenter`
    // never touches it either) — ARC deallocates it before the caller's
    // next line runs.
    let droppable = session(named: "droppable", path: "/tmp/notch-companion-droppable")
    model.register(droppable)
}

@MainActor
@Test("register: dedups by identity — registering the same session twice adds one row")
func registerDedupsByIdentity() {
    let model = NotchCompanionModel()
    let one = session(named: "rafu", path: "/tmp/rafu")
    model.register(one)
    model.register(one)
    #expect(model.editorRows.count == 1)
}

@MainActor
@Test("register/unregister: a weak entry prunes once its session deallocates, dropping its row")
func weakRegistryPrunesDroppedSession() {
    let model = NotchCompanionModel()
    let kept = session(named: "kept", path: "/tmp/notch-companion-kept")
    model.register(kept)
    registerDroppableSession(in: model)
    #expect(model.editorRows.count == 2)

    model.refreshEditorRows()
    #expect(model.editorRows.count == 1)
    #expect(model.editorRows.first?.name == "kept")
}

@MainActor
@Test("unregister: removes the row for that session immediately, without waiting on dealloc")
func unregisterRemovesRowImmediately() {
    let model = NotchCompanionModel()
    let first = session(named: "first", path: "/tmp/notch-companion-first")
    let second = session(named: "second", path: "/tmp/notch-companion-second")
    model.register(first)
    model.register(second)
    #expect(model.editorRows.count == 2)

    model.unregister(first)
    #expect(model.editorRows.map(\.name) == ["second"])
}

// MARK: - companionInput mapping (the pure session → CompanionEditorInput seam)

@MainActor
@Test("companionInput: falls back to the app name when the session has no descriptor")
func companionInputNameFallback() {
    let bare = WorkspaceSession()
    let input = NotchCompanionModel.companionInput(for: bare, id: UUID(), windowNumber: 1)
    #expect(input.name == RafuBuildInformation.appName)
    #expect(input.git == nil)
    #expect(input.statuses.isEmpty)
}

@MainActor
@Test("companionInput: uses the descriptor's displayName and the given id/windowNumber verbatim")
func companionInputUsesDescriptorAndGivenIdentity() {
    let workspace = session(named: "rafu", path: "/tmp/notch-companion-rafu")
    let id = UUID()
    let input = NotchCompanionModel.companionInput(for: workspace, id: id, windowNumber: 3)
    #expect(input.id == id)
    #expect(input.name == "rafu")
    #expect(input.windowNumber == 3)
}

@MainActor
@Test("companionInput: maps gitSnapshot to CompanionGitInput field-for-field")
func companionInputMapsGitSnapshot() {
    let workspace = session(named: "rafu", path: "/tmp/notch-companion-rafu-git")
    workspace.gitSnapshot = GitSnapshot(
        branch: "feature",
        aheadCount: 2,
        behindCount: 1,
        isDetached: false,
        isUnborn: false,
        changes: [
            GitChange(path: "a.swift", indexStatus: " ", worktreeStatus: "M"),
            GitChange(path: "b.swift", indexStatus: "A", worktreeStatus: " "),
        ]
    )
    let input = NotchCompanionModel.companionInput(for: workspace, id: UUID(), windowNumber: 1)
    #expect(input.git?.branch == "feature")
    #expect(input.git?.ahead == 2)
    #expect(input.git?.behind == 1)
    #expect(input.git?.dirtyCount == 2)
    #expect(input.git?.isDetached == false)
    #expect(input.git?.isUnborn == false)
}

@MainActor
@Test("companionInput: statuses come straight from terminal.sessions, in order")
func companionInputMapsTerminalStatuses() {
    let workspace = session(named: "rafu", path: "/tmp/notch-companion-rafu-terminals")
    workspace.newTerminalTab()
    workspace.newTerminalTab()
    let controllers = workspace.terminal.sessions
    #expect(controllers.count == 2)
    controllers[0].markRunningForTesting()
    controllers[1].markRunningForTesting()
    controllers[1].noteBell()

    let input = NotchCompanionModel.companionInput(for: workspace, id: UUID(), windowNumber: 1)
    #expect(input.statuses == [.running, .bell])

    // Feeds straight through the already-tested NC-A derivation.
    let row = CompanionEditorRow.editorRows(from: [input]).first!
    #expect(row.runningCount == 1)
    #expect(row.attentionCount == 1)
    #expect(row.exitedCount == 0)
}

// MARK: - refreshEditorRows: attentionCount aggregation

@MainActor
@Test("refreshEditorRows: attentionCount sums each row's attentionCount across sessions")
func refreshEditorRowsAggregatesAttentionCount() {
    let model = NotchCompanionModel()

    let quiet = session(named: "quiet", path: "/tmp/notch-companion-quiet")
    model.register(quiet)
    #expect(model.attentionCount == 0)

    let noisy = session(named: "noisy", path: "/tmp/notch-companion-noisy")
    noisy.newTerminalTab()
    noisy.terminal.sessions[0].markRunningForTesting()
    noisy.terminal.sessions[0].noteBell()
    model.register(noisy)

    #expect(model.attentionCount == 1)
    #expect(model.editorRows.count == 2)
}

// MARK: - isStripExpanded

@MainActor
@Test(
    "isStripExpanded: false while resting with no attention; true once a session bells; false again once cleared"
)
func isStripExpandedFollowsAttentionWhileResting() {
    let model = NotchCompanionModel()
    #expect(model.hoverState == .resting)
    #expect(model.isStripExpanded == false)

    let noisy = session(named: "noisy", path: "/tmp/notch-companion-strip-expanded")
    noisy.newTerminalTab()
    noisy.terminal.sessions[0].markRunningForTesting()
    model.register(noisy)
    #expect(model.isStripExpanded == false)

    noisy.terminal.sessions[0].noteBell()
    model.refreshEditorRows()
    #expect(model.attentionCount == 1)
    #expect(model.hoverState == .resting)
    #expect(model.isStripExpanded == true)

    noisy.terminal.sessions[0].clearAttention()
    model.refreshEditorRows()
    #expect(model.attentionCount == 0)
    #expect(model.isStripExpanded == false)
}

// MARK: - focusEditor

@MainActor
@Test("focusEditor: a no-op for an id that was never registered — no crash")
func focusEditorNoOpForUnknownID() {
    let model = NotchCompanionModel()
    model.focusEditor(UUID())
}

@MainActor
@Test("focusEditor: a no-op once the owning session has been unregistered")
func focusEditorNoOpAfterUnregister() {
    let model = NotchCompanionModel()
    let workspace = session(named: "rafu", path: "/tmp/notch-companion-focus")
    model.register(workspace)
    let id = model.editorRows.first!.id
    model.unregister(workspace)
    model.focusEditor(id)
}

// MARK: - NotchCompanionPreferenceStore

@MainActor
@Test("NotchCompanionPreferenceStore: defaults to enabled when the key has never been written")
func preferenceStoreDefaultsEnabled() {
    let suiteName = TestDefaultsSuite.name("NotchCompanionModelTests")
    defer { TestDefaultsSuite.remove(suiteName) }
    let store = NotchCompanionPreferenceStore(suiteName: suiteName)
    #expect(store.isEnabled() == true)
}

@MainActor
@Test("NotchCompanionPreferenceStore: setEnabled persists and round-trips")
func preferenceStoreRoundTrips() {
    let suiteName = TestDefaultsSuite.name("NotchCompanionModelTests")
    defer { TestDefaultsSuite.remove(suiteName) }
    let store = NotchCompanionPreferenceStore(suiteName: suiteName)
    store.setEnabled(false)
    #expect(store.isEnabled() == false)
    store.setEnabled(true)
    #expect(store.isEnabled() == true)
}

// MARK: - Search/filter (terminal-notch-hud.md NC-B "Search/filter")

@MainActor
@Test("setSearchQuery: narrows visibleEditorRows without touching editorRows itself")
func setSearchQueryFiltersVisibleEditorRows() {
    let model = NotchCompanionModel()
    // Held strongly for the test's duration — the registry is weak (mirrors
    // `TerminalAttentionCenter`), so a session with no other owner would be
    // pruned by the very next `register()` call, same gotcha
    // `registerDroppableSession(in:)` above exists to exercise deliberately.
    let rafu = session(named: "rafu", path: "/tmp/notch-companion-search-rafu")
    let notes = session(named: "notes", path: "/tmp/notch-companion-search-notes")
    model.register(rafu)
    model.register(notes)
    #expect(model.editorRows.count == 2)

    model.setSearchQuery("raf")
    #expect(model.editorRows.count == 2)
    #expect(model.visibleEditorRows.map(\.name) == ["rafu"])

    model.setSearchQuery("")
    #expect(model.visibleEditorRows.map(\.name) == ["rafu", "notes"])
}

@MainActor
@Test("setSearchQuery: a session registered while a query is active appears iff it matches")
func setSearchQueryAppliesToLaterRegistrations() {
    let model = NotchCompanionModel()
    model.setSearchQuery("raf")
    #expect(model.visibleEditorRows.isEmpty)

    let other = session(named: "other", path: "/tmp/notch-companion-search-other")
    model.register(other)
    #expect(model.visibleEditorRows.isEmpty)

    let rafu = session(named: "rafu", path: "/tmp/notch-companion-search-rafu-later")
    model.register(rafu)
    #expect(model.visibleEditorRows.map(\.name) == ["rafu"])
}

@MainActor
@Test("isSearchFieldVisible: true once the editors list reaches the threshold, false below it")
func isSearchFieldVisibleAtThreshold() {
    let model = NotchCompanionModel()
    let sessions = (0..<6).map {
        session(named: "w\($0)", path: "/tmp/notch-companion-threshold-\($0)")
    }
    for workspace in sessions.prefix(5) {
        model.register(workspace)
    }
    #expect(model.editorRows.count == 5)
    #expect(model.isSearchFieldVisible == false)

    model.register(sessions[5])
    #expect(model.editorRows.count == 6)
    #expect(model.isSearchFieldVisible == true)
}

@MainActor
@Test("isSearchFieldVisible: an active query keeps the field visible even below the threshold")
func isSearchFieldVisibleWithActiveQueryBelowThreshold() {
    let model = NotchCompanionModel()
    let rafu = session(named: "rafu", path: "/tmp/notch-companion-threshold-query")
    model.register(rafu)
    #expect(model.editorRows.count == 1)
    #expect(model.isSearchFieldVisible == false)

    model.setSearchQuery("raf")
    #expect(model.isSearchFieldVisible == true)
}

@MainActor
@Test("escapePressed: clears searchQuery and disengages search alongside collapsing to resting")
func escapePressedClearsSearchQuery() {
    let model = NotchCompanionModel()
    // `clicked()` pins the panel, which refreshes usage: without a fixture
    // reader that reads the real Keychain and blocks on its access prompt.
    model.usageReader = fixtureReader(descriptors: [])
    model.clicked()
    #expect(model.hoverState == .pinned)
    model.setSearchQuery("raf")
    #expect(model.searchQuery == "raf")

    model.escapePressed()

    #expect(model.hoverState == .resting)
    #expect(model.searchQuery == "")
    #expect(model.isSearchEngaged == false)
}

@MainActor
@Test("engageSearch: a no-op with no panel showing — isSearchEngaged stays false")
func engageSearchNoOpWithoutPanel() {
    let model = NotchCompanionModel()
    model.engageSearch()
    #expect(model.isSearchEngaged == false)
}

@MainActor
@Test("disengageSearch: always safe to call, even when never engaged")
func disengageSearchAlwaysSafe() {
    let model = NotchCompanionModel()
    model.disengageSearch()
    #expect(model.isSearchEngaged == false)
}

// MARK: - refreshUsage (agent-usage-providers.md, "Multi-provider display
// in the notch")

/// A fixture `UsageFetchStrategy` that always returns a canned snapshot —
/// mirrors `UsageCoreTests`' `StubStrategy` but lives here too since
/// Swift's `private` visibility does not cross files.
private struct FixtureUsageStrategy: UsageFetchStrategy {
    let id: String
    let snapshot: UsageSnapshot
    func isAvailable(_ context: UsageFetchContext) async -> Bool { true }
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot { snapshot }
    func shouldFallback(on error: Error) -> Bool { false }
}

private func fixtureDescriptor(id: UsageProviderID, snapshot: UsageSnapshot)
    -> UsageProviderDescriptor
{
    UsageProviderDescriptor(
        id: id, displayName: id.rawValue, authPattern: .localZeroConfig, disclosure: "fixture",
        defaultEnabled: true,
        makeStrategies: { _ in [FixtureUsageStrategy(id: id.rawValue, snapshot: snapshot)] }
    )
}

private func fixtureReader(descriptors: [UsageProviderDescriptor]) -> UsageRegistryReader {
    UsageRegistryReader(
        descriptors: descriptors,
        makeContext: { now in
            UsageFetchContext(
                now: now, readFile: { _ in nil }, http: .noop, credential: { _ in nil },
                cookieHeader: { _ in nil })
        },
        isEnabled: { _ in true },
        // The production defaults read the real Keychain, which blocks the
        // test process on an access prompt on any Mac where Rafu has stored
        // usage credentials.
        resolveCredentials: { _, _ in [:] },
        hasNetworkConsent: { _ in false }
    )
}

/// `refreshUsage()` hops through `Task.detached` (`UsageRegistryReader
/// .snapshots(now:)` and its strategies are pure/`Sendable`, so this
/// genuinely runs off the main actor) and assigns back on the main actor —
/// awaiting the returned task, rather than a fixed sleep, is what proves
/// completion here (AGENTS: "Await async APIs directly; do not use fixed
/// sleeps as synchronization").
@MainActor
@Test("refreshUsage: populates usageSnapshots from the injected reader")
func refreshUsagePopulatesSnapshotsFromInjectedReader() async {
    let model = NotchCompanionModel()
    let snapshot = UsageSnapshot(
        providerID: .codex,
        windows: [UsageWindow(label: "5h", percent: 12.0, tokens: nil, resetsAt: nil)],
        costLine: nil, identity: nil)
    model.usageReader = fixtureReader(descriptors: [
        fixtureDescriptor(id: .codex, snapshot: snapshot)
    ])

    let task = model.refreshUsage()
    await task?.value

    #expect(model.usageSnapshots.map(\.providerID) == [.codex])
    #expect(model.usageSnapshots.first?.windows.first?.percent == 12.0)
}

@MainActor
@Test("refreshUsage: a second call within the TTL is suppressed unless forced")
func refreshUsageRespectsTTLUnlessForced() async {
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])

    let first = model.refreshUsage()
    #expect(first != nil)
    await first?.value

    let second = model.refreshUsage()
    #expect(second == nil)

    let forced = model.refreshUsage(force: true)
    #expect(forced != nil)
    await forced?.value
}

// MARK: - Usage schedule wiring

@MainActor
@Test("Usage schedule: a turn end with a status item schedules a read; none without a surface")
func turnEndSchedulesUsageRead() {
    let clock = Date(timeIntervalSince1970: 5_000)
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])
    model.usageNow = { clock }
    // Nothing shows usage: the event changes nothing.
    model.agentTurnsEnded([.claude])
    #expect(model.usageSchedule.turnEndDue == nil)

    // A status item exists (no panel): the loop runs without one.
    model.usageSurfaceOverrideForTesting = true
    model.agentTurnsEnded([.claude])
    #expect(model.usageSchedule.turnEndDue == clock.addingTimeInterval(15))
}

@MainActor
@Test("Usage schedule: the wake-up reads only when due")
func usageWakeReadsWhenDue() async {
    let start = Date(timeIntervalSince1970: 5_000)
    var clock = start
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])
    model.usageSurfaceOverrideForTesting = true
    model.usageNow = { clock }
    await model.refreshUsage()?.value
    #expect(model.usageSchedule.lastStarted == start)

    clock = start.addingTimeInterval(100)
    model.agentTurnsEnded([.claude])
    // The turn end is 15 s away: an early wake-up does nothing.
    model.usageWakeFired()
    #expect(model.usageSchedule.lastStarted == start)
    #expect(!model.isUsageRefreshing)

    clock = start.addingTimeInterval(120)
    model.usageWakeFired()
    #expect(model.isUsageRefreshing)
    #expect(model.usageSchedule.lastStarted == clock)
}

@MainActor
@Test("Usage schedule: a forced refresh joins a running read instead of starting another")
func forcedRefreshJoinsRunningRead() async {
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])
    let first = model.refreshUsage()
    let joined = model.refreshUsage(force: true)
    #expect(first != nil)
    #expect(joined == first)
    await first?.value
}

// MARK: - Usage front-line/overflow (agent-usage-providers.md,
// "Multi-provider display in the notch")

@MainActor
@Test(
    "usageFrontLine/usageOverflow: default order (claude, codex) selects both into the front line")
func usageFrontLineDefaultOrderIncludesBoth() async {
    let model = NotchCompanionModel()
    let claudeSnapshot = UsageSnapshot(
        providerID: .claude,
        windows: [UsageWindow(label: "5h", percent: nil, tokens: 10, resetsAt: nil)],
        costLine: nil, identity: nil)
    let codexSnapshot = UsageSnapshot(
        providerID: .codex,
        windows: [UsageWindow(label: "5h", percent: 3.0, tokens: nil, resetsAt: nil)],
        costLine: nil, identity: nil)
    model.usageReader = fixtureReader(descriptors: [
        fixtureDescriptor(id: .claude, snapshot: claudeSnapshot),
        fixtureDescriptor(id: .codex, snapshot: codexSnapshot),
    ])

    await model.refreshUsage()?.value

    #expect(model.usageFrontLine.map(\.providerID) == [.claude, .codex])
    #expect(model.usageOverflow.isEmpty)
}

/// Builds a fixture reader with one enabled provider per given id, each
/// carrying a single renderable window — enough to land every id in
/// `usageFrontLine` (all counts here stay at/under `frontLineCap`).
private func fixtureReader(providerIDs: [UsageProviderID]) -> UsageRegistryReader {
    fixtureReader(
        descriptors: providerIDs.map { id in
            fixtureDescriptor(
                id: id,
                snapshot: UsageSnapshot(
                    providerID: id,
                    windows: [UsageWindow(label: "5h", percent: 10, tokens: nil, resetsAt: nil)],
                    costLine: nil, identity: nil))
        })
}

/// The open panel is a fixed size (Cider-style): usage rows, feed cards and
/// search results scroll inside it, so none of them may change the height.
@MainActor
@Test("peekContentHeight: fixed — usage providers do not change it")
func peekContentHeightIsFixed() async {
    let none = NotchCompanionModel()
    none.usageReader = fixtureReader(providerIDs: [])
    await none.refreshUsage()?.value

    let four = NotchCompanionModel()
    four.usageReader = fixtureReader(providerIDs: [.claude, .codex, .cline, .openCode])
    await four.refreshUsage()?.value

    #expect(four.usageFrontLine.count == 4)
    #expect(none.peekContentHeight() == four.peekContentHeight())
    #expect(
        none.peekContentHeight()
            == none.stripHeight + NotchCompanionGeometry.openPanelBodyHeight)
}

@MainActor
@Test("isPanelOpen: pinned always; peeking only with hover-to-open on; resting never")
func isPanelOpenFollowsHoverPolicy() {
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])  // see escapePressedClearsSearchQuery
    #expect(model.isPanelOpen == false)
    model.clicked()
    #expect(model.hoverState == .pinned)
    #expect(model.isPanelOpen == true)
    model.clicked()
    #expect(model.hoverState == .peeking)
    #expect(model.isPanelOpen == model.opensOnHover)
    model.escapePressed()
    #expect(model.hoverState == .resting)
    #expect(model.isPanelOpen == false)
}

@MainActor
@Test("focusAgent: a no-op for a row whose window is unknown — no crash")
func focusAgentNoOpForUnknownWindow() {
    let model = NotchCompanionModel()
    let row = NotchAgentRow(
        id: UUID(), title: "claude", cli: .claudeCode, phase: .needsYou, windowID: UUID())
    model.focusAgent(row)
    #expect(model.hoverState == .resting)
}

@MainActor
@Test("allAgentRows: an ordinary shell is not listed; a terminal titled as an agent is")
func allAgentRowsListsOnlyAgents() {
    let model = NotchCompanionModel()
    let host = session(named: "rafu", path: "/tmp/notch-agents")
    model.register(host)
    host.newTerminalTab()
    #expect(model.allAgentRows.isEmpty)
    #expect(model.agentSummary.live == 0)
    #expect(model.mascotState.mood == .idle)
}

// MARK: - Dynamic Island surface

@MainActor
@Test("island surface: Usage only, hover never opens, and no stored preference is written")
func islandSurfacePolicyOffersUsageOnly() {
    let suite = TestDefaultsSuite.name("dev.rafu.tests.notch-island-policy")
    defer { TestDefaultsSuite.remove(suite) }
    let model = NotchCompanionModel()
    model.displayPreferences = NotchDisplayPreferenceStore(suiteName: suite)

    model.setSurfaceForTesting(.island)
    #expect(model.visibleSections == [.usage])
    #expect(model.selectedSection == .usage)
    #expect(model.opensOnHover == false)
    model.select(.ensembles)
    #expect(model.selectedSection == .usage)
    #expect(model.displayPreferences.selectedSection() == nil)
    #expect(model.displayPreferences.visibleSections() == NotchSection.allCases)
    #expect(model.displayPreferences.opensOnHover())

    model.setSurfaceForTesting(.notch)
    #expect(model.visibleSections == NotchSection.allCases)
    #expect(model.selectedSection == .ensembles)
    #expect(model.opensOnHover == true)
}

@MainActor
@Test("island clicked: a tap opens, a second tap closes; the notch keeps its pin toggle")
func islandClickedTogglesOpenAndClosed() {
    let island = NotchCompanionModel()
    island.usageReader = fixtureReader(descriptors: [])  // see escapePressedClearsSearchQuery
    island.setSurfaceForTesting(.island)
    island.clicked()
    #expect(island.hoverState == .pinned)
    #expect(island.isPanelOpen)
    island.clicked()
    #expect(island.hoverState == .resting)
    #expect(!island.isPanelOpen)

    let notch = NotchCompanionModel()
    notch.usageReader = fixtureReader(descriptors: [])
    notch.clicked()
    notch.clicked()
    #expect(notch.hoverState == .peeking)
    notch.escapePressed()
}

@MainActor
@Test("island attention: does not widen the capsule and has no feed; the notch still widens")
func islandAttentionDoesNotWidenCapsule() {
    let model = NotchCompanionModel()
    let noisy = session(named: "noisy", path: "/tmp/notch-companion-island-attention")
    noisy.newTerminalTab()
    noisy.terminal.sessions[0].markRunningForTesting()
    noisy.terminal.sessions[0].noteBell()
    model.register(noisy)
    #expect(model.attentionCount == 1)

    #expect(model.isStripExpanded)
    #expect(model.isAttentionFeedAvailable)

    model.setSurfaceForTesting(.island)
    #expect(!model.isStripExpanded)
    #expect(!model.isAttentionFeedAvailable)
    let arbitration = CompanionHoverPolicy.companionArbitration(
        hoverState: .pinned, peekShowsPanel: model.opensOnHover,
        feedAvailable: model.isAttentionFeedAvailable)
    #expect(!arbitration.routeToFeed && arbitration.showDropDown)
}

@MainActor
@Test("islandUsageGlance: nil before usage loads; the most constrained window after")
func islandUsageGlanceFromInjectedReader() async throws {
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [
        fixtureDescriptor(
            id: .codex,
            snapshot: UsageSnapshot(
                providerID: .codex,
                windows: [
                    UsageWindow(label: "5h", percent: 12, tokens: nil, resetsAt: nil),
                    UsageWindow(label: "7d", percent: 30, tokens: nil, resetsAt: nil),
                ],
                costLine: nil, identity: nil))
    ])
    #expect(model.islandUsageGlance == nil)

    await model.refreshUsage()?.value

    let glance = try #require(model.islandUsageGlance)
    #expect(glance.level == .normal)
    #expect(glance.spokenLabel.hasPrefix("Usage: "))
    #expect(glance.spokenLabel.hasSuffix("Weekly \(glance.percentText)"))
}

// MARK: - Panel layering (menu-bar overflow on macOS 27)

@MainActor
@Test("panelLayering on macOS 27: resting lowers; hover dwell and open panel raise")
func panelLayeringFollowsHoverOnMacOS27() {
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])  // see escapePressedClearsSearchQuery
    model.osMajorVersion = 27
    model.setSurfaceForTesting(.notch)

    #expect(model.panelLayering.level == .belowMenuBar)
    #expect(!model.panelLayering.leadingWingStartsHover)

    // The leading wing does not start the dwell while lowered.
    model.hoverMoved(inLeadingWing: true)
    #expect(model.panelLayering.level == .belowMenuBar)

    // The housing or trailing wing does, and the panel rises at once.
    model.hoverMoved(inLeadingWing: false)
    #expect(model.panelLayering == .standard)
    model.hoverExited()
    #expect(model.panelLayering.level == .belowMenuBar)

    model.clicked()
    #expect(model.panelLayering == .standard)
    model.escapePressed()
    #expect(model.panelLayering.level == .belowMenuBar)

    // The island pill hangs below the menu bar, so it is never lowered.
    model.setSurfaceForTesting(.island)
    #expect(model.panelLayering == .standard)
    model.setSurfaceForTesting(.pill)
    #expect(model.panelLayering == .standard)
}

@MainActor
@Test("panelLayering on macOS 26: always the status-bar level and the full hover area")
func panelLayeringUnchangedOnMacOS26() {
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])
    model.osMajorVersion = 26
    for surface in [NotchCompanionSurface.notch, .island, .pill] {
        model.setSurfaceForTesting(surface)
        #expect(model.panelLayering == .standard)
        model.clicked()
        #expect(model.panelLayering == .standard)
        model.escapePressed()
    }
}

// MARK: - Usage glance in the menu bar (Dynamic Island Macs)

@MainActor
@Test("menu bar usage glance: an island shows no pill panel and a click opens no card")
func islandMenuBarPositionHasNoPillPanel() {
    let displaySuite = TestDefaultsSuite.name("dev.rafu.tests.usage-glance-model-display")
    let enabledSuite = TestDefaultsSuite.name("dev.rafu.tests.usage-glance-model-enabled")
    defer {
        TestDefaultsSuite.remove(displaySuite)
        TestDefaultsSuite.remove(enabledSuite)
    }
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])  // see escapePressedClearsSearchQuery
    model.preferenceStore = NotchCompanionPreferenceStore(suiteName: enabledSuite)
    model.displayPreferences = NotchDisplayPreferenceStore(suiteName: displaySuite)
    model.displayPreferences.setUsageGlancePosition(.menuBar)
    model.reloadDisplayPreferences()
    model.setSurfaceForTesting(.island)

    #expect(model.usageGlancePosition == .menuBar)
    #expect(model.presence == CompanionPresence(showsPanel: false, showsMenuBarItem: true))
    model.clicked()
    #expect(model.hoverState == .resting)
    #expect(!model.isPanelOpen)

    // A notched screen ignores the position.
    model.setSurfaceForTesting(.notch)
    #expect(model.presence == CompanionPresence(showsPanel: true, showsMenuBarItem: false))

    // Turning the companion off removes both.
    model.preferenceStore.setEnabled(false)
    model.setSurfaceForTesting(.island)
    #expect(model.presence == .none)
}

@MainActor
@Test("below-island usage glance: the island keeps its pill and its tap-to-open card")
func islandBelowIslandPositionKeepsPill() {
    let displaySuite = TestDefaultsSuite.name("dev.rafu.tests.usage-glance-below-display")
    let enabledSuite = TestDefaultsSuite.name("dev.rafu.tests.usage-glance-below-enabled")
    defer {
        TestDefaultsSuite.remove(displaySuite)
        TestDefaultsSuite.remove(enabledSuite)
    }
    let model = NotchCompanionModel()
    model.usageReader = fixtureReader(descriptors: [])
    model.preferenceStore = NotchCompanionPreferenceStore(suiteName: enabledSuite)
    model.displayPreferences = NotchDisplayPreferenceStore(suiteName: displaySuite)
    model.reloadDisplayPreferences()
    model.setSurfaceForTesting(.island)

    #expect(model.usageGlancePosition == .belowIsland)
    #expect(model.presence == CompanionPresence(showsPanel: true, showsMenuBarItem: false))
    model.clicked()
    #expect(model.hoverState == .pinned)
    model.clicked()
    #expect(model.hoverState == .resting)
}
