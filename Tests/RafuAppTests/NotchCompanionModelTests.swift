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

// MARK: - refreshUsage (terminal-notch-hud.md NC-D)

/// `refreshUsage()` hops through `Task.detached` (AgentUsage.swift's parsers
/// are pure/`Sendable`, so this genuinely runs off the main actor) and
/// assigns back on the main actor — awaiting the returned task, rather than
/// a fixed sleep, is what proves completion here (AGENTS: "Await async APIs
/// directly; do not use fixed sleeps as synchronization").
@MainActor
@Test("refreshUsage: populates usageTiles from the injected reader")
func refreshUsagePopulatesTilesFromInjectedReader() async {
    let model = NotchCompanionModel()
    let codexContents = """
        {"timestamp":"2026-07-18T14:49:29.225Z","type":"event_msg","payload":{"rate_limits":{"limit_id":"codex","primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1},"secondary":null}}}
        """
    model.usageReader = AgentUsageReader(
        newestCodexRollout: { codexContents },
        recentClaudeTranscriptLines: { _ in [] }
    )

    let task = model.refreshUsage()
    await task?.value

    #expect(model.usageTiles.map(\.agent) == ["Codex"])
    #expect(model.usageTiles.first?.windows.first?.percent == 12.0)
}

@MainActor
@Test("refreshUsage: a second call within the TTL is suppressed unless forced")
func refreshUsageRespectsTTLUnlessForced() async {
    let model = NotchCompanionModel()
    model.usageReader = AgentUsageReader(
        newestCodexRollout: { nil }, recentClaudeTranscriptLines: { _ in [] })

    let first = model.refreshUsage()
    #expect(first != nil)
    await first?.value

    let second = model.refreshUsage()
    #expect(second == nil)

    let forced = model.refreshUsage(force: true)
    #expect(forced != nil)
    await forced?.value
}
