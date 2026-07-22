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
    let suiteName = "NotchCompanionModelTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
    let store = NotchCompanionPreferenceStore(suiteName: suiteName)
    #expect(store.isEnabled() == true)
}

@MainActor
@Test("NotchCompanionPreferenceStore: setEnabled persists and round-trips")
func preferenceStoreRoundTrips() {
    let suiteName = "NotchCompanionModelTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
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
        isEnabled: { _ in true }
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

@MainActor
@Test("toggleUsageOverflow: flips isUsageOverflowExpanded")
func toggleUsageOverflowFlipsExpandedState() {
    let model = NotchCompanionModel()
    #expect(model.isUsageOverflowExpanded == false)
    model.toggleUsageOverflow()
    #expect(model.isUsageOverflowExpanded == true)
    model.toggleUsageOverflow()
    #expect(model.isUsageOverflowExpanded == false)
}

@MainActor
@Test("escapePressed: collapsing to .resting resets isUsageOverflowExpanded to false")
func escapePressedResetsUsageOverflowExpanded() {
    let model = NotchCompanionModel()
    model.clicked()
    model.toggleUsageOverflow()
    #expect(model.isUsageOverflowExpanded == true)

    model.escapePressed()

    #expect(model.isUsageOverflowExpanded == false)
}
