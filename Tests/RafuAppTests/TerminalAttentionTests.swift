import Foundation
import Testing

@testable import RafuApp

/// terminal-manager.md T-E: bell → `.bell` state, attention clearing on
/// selection/reveal, the pure `TerminalAttentionPolicy` decision/bounding
/// functions, the opt-in notification preference, and reply delivery. No
/// test in this file (or anywhere else — grep-verify with `grep -rn
/// "import UserNotifications" Sources/`) ever constructs
/// `SystemTerminalAttentionNotifier`: `WorkspaceSession.attentionNotifier`
/// is always a `SpyTerminalAttentionNotifier` here, and
/// `notifyIfNeeded(for:)`'s own focus decision
/// (`NSApp.isActive`/a key `NSWindow`) is exercised separately, and only in
/// its pure form, via `TerminalAttentionPolicy.shouldRaiseAttention` — an
/// unsigned/headless test binary has no bundle identity to post a real
/// system notification through.

@MainActor
private final class SpyTerminalAttentionNotifier: TerminalAttentionNotifying {
    private(set) var posted: [TerminalAttentionNotification] = []
    var authorized: Bool

    init(authorized: Bool = true) {
        self.authorized = authorized
    }

    func requestAuthorizationIfNeeded() async -> Bool { authorized }

    func post(_ notification: TerminalAttentionNotification) {
        posted.append(notification)
    }
}

/// Spy for the notch HUD seam (terminal-notch-hud.md) — records what
/// `WorkspaceSession.notifyIfNeeded(for:)` would surface, so no headless
/// test ever constructs the real `NotchHUDController`/panel.
@MainActor
private final class SpyNotchHUD: NotchHUDPresenting {
    private(set) var shown: [NotchHUDEvent] = []
    private(set) var clearedIDs: [UUID] = []

    func show(_ event: NotchHUDEvent, theme: RafuTheme) {
        shown.append(event)
    }

    func attentionCleared(for sessionID: UUID) {
        clearedIDs.append(sessionID)
    }
}

/// A hermetic attention rig for `notifyIfNeeded(for:)` tests: a suite-backed
/// surface store (NEVER the standard defaults — `TerminalAttentionSurfaceStore`
/// migrates, i.e. WRITES, on first read), a spy notifier, a spy HUD, and a
/// fixed theme provider so nothing reads the real `themeChoice` default.
/// The returned suite name must be cleaned up by the caller in `defer`.
@MainActor
private func installAttentionRig(
    on session: WorkspaceSession,
    surface: TerminalAttentionSurface,
    authorized: Bool = true
) -> (notifier: SpyTerminalAttentionNotifier, hud: SpyNotchHUD, suiteName: String) {
    let suiteName = "TerminalAttentionTests.\(UUID().uuidString)"
    let store = TerminalAttentionSurfaceStore(suiteName: suiteName)
    store.setSurface(surface)
    session.terminalAttentionSurfaceStore = store
    let notifier = SpyTerminalAttentionNotifier(authorized: authorized)
    session.attentionNotifier = notifier
    let hud = SpyNotchHUD()
    session.attentionHUD = hud
    session.hudThemeProvider = { RafuThemeCatalog.indigo }
    return (notifier, hud, suiteName)
}

/// `notifyIfNeeded(for:)` posts from inside a detached `Task` — poll
/// cooperatively (never a fixed sleep) until the expected count arrives or
/// the bound is exhausted.
@MainActor
private func waitUntilPosted(
    _ spy: SpyTerminalAttentionNotifier, count: Int = 1
) async -> [TerminalAttentionNotification] {
    for _ in 0..<20_000 {
        if spy.posted.count >= count { break }
        await Task.yield()
    }
    return spy.posted
}

/// For a NEGATIVE assertion ("nothing posts") there is nothing to poll
/// until — this cooperatively yields a bounded number of times to give a
/// pending `Task` every reasonable chance to run before asserting absence.
@MainActor
private func drainPendingTasks(iterations: Int = 500) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}

// MARK: - noteBell / clearAttention

@MainActor
@Test("noteBell transitions .running to .bell; an already-exited session is unaffected")
func noteBellTransitionsRunningToBellOnly() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()

    controller.noteBell()
    #expect(controller.status == .bell)

    // Coalescing: a second bell while already `.bell` is a no-op.
    controller.noteBell()
    #expect(controller.status == .bell)

    controller.processDidTerminate(exitCode: 2)
    #expect(controller.status == .exited(code: 2))
    controller.noteBell()
    #expect(controller.status == .exited(code: 2))
}

@MainActor
@Test("clearAttention resets .bell to .running; no-op for .idle or .exited")
func clearAttentionResetsBellOnlyToRunning() throws {
    let manager = WorkspaceTerminalManager()
    let shell = TerminalShell(path: "/bin/zsh", name: "Default (zsh)", isDefault: true)
    let neverMounted = manager.newSession(startingDirectory: "/tmp", shell: shell)
    #expect(neverMounted.status == .idle)
    neverMounted.clearAttention()
    #expect(neverMounted.status == .idle)

    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()
    controller.noteBell()
    controller.clearAttention()
    #expect(controller.status == .running)

    controller.processDidTerminate(exitCode: nil)
    controller.clearAttention()
    #expect(controller.status == .exited(code: nil))
}

// MARK: - needsAttention / attentionCount / symbol/label

@Test("needsAttention is true only for .bell")
func needsAttentionTrueOnlyForBell() {
    #expect(TerminalSessionPresentation.needsAttention(.bell))
    #expect(!TerminalSessionPresentation.needsAttention(.idle))
    #expect(!TerminalSessionPresentation.needsAttention(.running))
    #expect(!TerminalSessionPresentation.needsAttention(.exited(code: nil)))
}

@MainActor
@Test("Both attentionCount overloads count only .bell sessions")
func attentionCountOverloadsCountOnlyBellSessions() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    session.newTerminalTab()
    let controllers = session.terminal.sessions
    #expect(controllers.count == 2)
    controllers[0].markRunningForTesting()
    controllers[0].noteBell()

    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )

    #expect(TerminalsPanelModel.attentionCount(rows) == 1)
    #expect(TerminalsPanelModel.attentionCount(sessions: session.terminal.sessions) == 1)
}

@Test("isExited is true only for .exited — the T-E regression guard's own predicate")
func isExitedTrueOnlyForExited() {
    #expect(TerminalSessionPresentation.isExited(.exited(code: nil)))
    #expect(TerminalSessionPresentation.isExited(.exited(code: 1)))
    #expect(!TerminalSessionPresentation.isExited(.bell))
    #expect(!TerminalSessionPresentation.isExited(.running))
    #expect(!TerminalSessionPresentation.isExited(.idle))
}

// MARK: - selection/reveal clear attention (the three bell-clear hooks)

@MainActor
@Test(
    "Selecting a belling session's tab clears .bell; revealing a parked belling session clears it too"
)
func selectingOrRevealingClearsBellAttention() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    session.newTerminalTab()
    let controllers = session.terminal.sessions
    let first = try #require(controllers.first)
    first.markRunningForTesting()

    first.noteBell()
    #expect(first.status == .bell)

    let firstTab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs
            .first { $0.resource == .terminal(sessionID: first.id) })
    session.selectEditorTab(firstTab.id, in: session.editorLayout.focusedGroupID)
    #expect(first.status == .running)

    session.hideTerminalTab(firstTab.id)
    #expect(session.parkedTerminalSessions.contains { $0.id == first.id })
    first.noteBell()
    #expect(first.status == .bell)

    session.revealTerminalSession(first.id)
    #expect(first.status == .running)
}

// MARK: - TerminalAttentionPolicy (pure)

@Test(
    "shouldRaiseAttention: selected+active+key suppresses; any one false raises; .exited never raises"
)
func shouldRaiseAttentionTruthTable() {
    #expect(
        TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: true, isAppActive: true, isWindowKey: true, status: .running) == false)
    #expect(
        TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: true, isAppActive: false, isWindowKey: true, status: .running) == true)
    #expect(
        TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: false, isAppActive: true, isWindowKey: true, status: .running) == true)
    #expect(
        TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: true, isAppActive: true, isWindowKey: false, status: .running) == true)
    #expect(
        TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: false, isAppActive: false, isWindowKey: false,
            status: .exited(code: nil)) == false)
    #expect(
        TerminalAttentionPolicy.shouldRaiseAttention(
            isSelectedTab: true, isAppActive: true, isWindowKey: true, status: .exited(code: 0))
            == false)
}

@Test("shouldNotify requires raised attention, the preference on, and OS authorization — all three")
func shouldNotifyRequiresAllThree() {
    #expect(
        TerminalAttentionPolicy.shouldNotify(
            raisedAttention: true, preferenceEnabled: true, isAuthorized: true))
    #expect(
        !TerminalAttentionPolicy.shouldNotify(
            raisedAttention: false, preferenceEnabled: true, isAuthorized: true))
    #expect(
        !TerminalAttentionPolicy.shouldNotify(
            raisedAttention: true, preferenceEnabled: false, isAuthorized: true))
    #expect(
        !TerminalAttentionPolicy.shouldNotify(
            raisedAttention: true, preferenceEnabled: true, isAuthorized: false))
}

@Test("snippet keeps the last 6 non-empty lines and drops empty ones")
func snippetKeepsLastSixNonEmptyLines() {
    let lines = (1...10).map { "line \($0)" }
    let snippet = TerminalAttentionPolicy.snippet(from: lines)
    #expect(
        snippet.components(separatedBy: "\n") == [
            "line 5", "line 6", "line 7", "line 8", "line 9", "line 10",
        ])

    let withEmpties = ["", "   ", "a", "", "b", "c"]
    #expect(TerminalAttentionPolicy.snippet(from: withEmpties) == "a\nb\nc")

    #expect(TerminalAttentionPolicy.snippet(from: ["", "   ", ""]) == "")
    #expect(TerminalAttentionPolicy.snippet(from: []) == "")
}

@Test("snippet caps each line and the whole body in UTF-8 bytes")
func snippetCapsLineAndTotalBytes() {
    let longLine = String(repeating: "x", count: 5000)
    let perLineCapped = TerminalAttentionPolicy.snippet(from: [longLine], maxLineBytes: 200)
    #expect(perLineCapped.utf8.count == 200)

    let sixLongLines = Array(repeating: String(repeating: "y", count: 200), count: 6)
    let totalCapped = TerminalAttentionPolicy.snippet(
        from: sixLongLines, maxLineBytes: 200, maxBytes: 512)
    #expect(totalCapped.utf8.count == 512)
}

@Test("snippet truncation never corrupts multibyte characters into unbounded garbage")
func snippetTruncationStaysBoundedForMultibyteCharacters() {
    let emojiLine = String(repeating: "🎉", count: 300)  // 1200 UTF-8 bytes
    let capped = TerminalAttentionPolicy.snippet(from: [emojiLine], maxLineBytes: 201)
    // Reuses `WorkspaceSession.boundedAIErrorMessage`'s established
    // `String(decoding:as:)` idiom: an incomplete trailing multibyte
    // sequence is repaired into a single replacement character rather than
    // corrupting further bytes or crashing — bounded, not byte-exact, at a
    // mid-character cut.
    #expect(capped.utf8.count < emojiLine.utf8.count)
    #expect(capped.utf8.count <= 204)
}

@Test("snippet strips NUL, ESC, and other C0 control characters")
func snippetStripsControlCharacters() {
    let line = "\u{0}Hello\u{1B}[31mWorld\u{07}"
    #expect(TerminalAttentionPolicy.snippet(from: [line]) == "Hello[31mWorld")
}

@Test("sanitizedReply strips newlines/ESC/C0, collapses to one line, and rejects blank input")
func sanitizedReplyStripsCollapsesAndRejectsBlank() {
    #expect(TerminalAttentionPolicy.sanitizedReply("") == nil)
    #expect(TerminalAttentionPolicy.sanitizedReply("   ") == nil)
    #expect(TerminalAttentionPolicy.sanitizedReply("hello") == "hello")

    let multiline = "line one\nline two\r\nline three"
    #expect(TerminalAttentionPolicy.sanitizedReply(multiline) == "line one line two line three")

    let withEscape = "hello\u{1B}[0mworld"
    #expect(TerminalAttentionPolicy.sanitizedReply(withEscape) == "hello[0mworld")
}

@Test("sanitizedReply caps at 1024 UTF-8 bytes by default, on a byte boundary")
func sanitizedReplyCapsAtDefaultByteLimit() {
    let long = String(repeating: "a", count: 2000)
    let capped = TerminalAttentionPolicy.sanitizedReply(long)
    #expect(capped?.utf8.count == 1024)
}

// MARK: - notification preference store

// The boolean `TerminalNotificationPreferenceStore` was replaced by the
// `TerminalAttentionSurface` arbitration enum and its store
// (terminal-notch-hud.md, product decision 1); its tests — defaults,
// legacy-boolean migration, and round-trips — live in
// `NotchHUDCoreTests.swift`.

// MARK: - notifyIfNeeded (spy notifier, no UserNotifications anywhere)

@MainActor
@Test(
    "notifyIfNeeded posts exactly one matching notification for a belling, authorized session (.both also shows the HUD)"
)
func notifyIfNeededPostsForBellingAuthorizedSession() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()
    controller.noteBell()

    let rig = installAttentionRig(on: session, surface: .both, authorized: true)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.notifyIfNeeded(for: controller)

    let posted = await waitUntilPosted(rig.notifier)
    #expect(posted.count == 1)
    #expect(posted.first?.sessionID == controller.id)
    #expect(posted.first?.title == controller.displayName)

    // The HUD surface fires synchronously — no authorization needed.
    #expect(rig.hud.shown.count == 1)
    #expect(rig.hud.shown.first?.sessionID == controller.id)
    #expect(rig.hud.shown.first?.title == controller.displayName)
}

@MainActor
@Test(
    "notifyIfNeeded posts nothing when the session's attention was never raised (status stays .running)"
)
func notifyIfNeededPostsNothingWhenNotRaised() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    // Mirrors `terminalSessionDidBell` never calling `notifyIfNeeded` when
    // `TerminalAttentionPolicy.shouldRaiseAttention` says no (the
    // selected/focused-tab case — already covered by the pure truth-table
    // test above); here the session simply was never `noteBell()`'d.

    let rig = installAttentionRig(on: session, surface: .both, authorized: true)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.notifyIfNeeded(for: controller)

    await drainPendingTasks()
    #expect(rig.notifier.posted.isEmpty)
    #expect(rig.hud.shown.isEmpty)
}

@MainActor
@Test("notifyIfNeeded surfaces nothing when the preference is .none")
func notifyIfNeededPostsNothingWhenPreferenceOff() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()
    controller.noteBell()

    let rig = installAttentionRig(on: session, surface: .none, authorized: true)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.notifyIfNeeded(for: controller)

    await drainPendingTasks()
    #expect(rig.notifier.posted.isEmpty)
    #expect(rig.hud.shown.isEmpty)
}

@MainActor
@Test(
    "notifyIfNeeded posts nothing when unauthorized — but the HUD still shows (.both: HUD needs no authorization)"
)
func notifyIfNeededPostsNothingWhenUnauthorized() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()
    controller.noteBell()

    let rig = installAttentionRig(on: session, surface: .both, authorized: false)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.notifyIfNeeded(for: controller)

    await drainPendingTasks()
    #expect(rig.notifier.posted.isEmpty)
    // The HUD is our own window — OS notification authorization is
    // irrelevant to it (terminal-notch-hud.md N-3).
    #expect(rig.hud.shown.count == 1)
}

@MainActor
@Test(
    "notifyIfNeeded with .hud shows only the HUD — no notification even when authorized, and no authorization requested"
)
func notifyIfNeededHUDOnlySurface() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()
    controller.noteBell()

    let rig = installAttentionRig(on: session, surface: .hud, authorized: true)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.notifyIfNeeded(for: controller)

    await drainPendingTasks()
    #expect(rig.hud.shown.count == 1)
    #expect(rig.hud.shown.first?.sessionID == controller.id)
    #expect(rig.notifier.posted.isEmpty)
}

@MainActor
@Test("notifyIfNeeded with .notification posts only the notification — no HUD")
func notifyIfNeededNotificationOnlySurface() async throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.markRunningForTesting()
    controller.noteBell()

    let rig = installAttentionRig(on: session, surface: .notification, authorized: true)
    defer { UserDefaults(suiteName: rig.suiteName)?.removePersistentDomain(forName: rig.suiteName) }

    session.notifyIfNeeded(for: controller)

    let posted = await waitUntilPosted(rig.notifier)
    #expect(posted.count == 1)
    #expect(rig.hud.shown.isEmpty)
}

// MARK: - reply delivery

@MainActor
@Test("deliverTerminalReply is a no-op for an unknown session id, never crashing")
func deliverTerminalReplyNoOpsForUnknownSessionID() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()

    #expect(session.deliverTerminalReply("hello", to: UUID()) == false)
}

@MainActor
@Test(
    "deliverTerminalReply drops silently (but is still found) for an exited session, never crashing"
)
func deliverTerminalReplyDropsForExitedSession() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    controller.processDidTerminate(exitCode: 0)

    // Found in this workspace (`true`, so `TerminalAttentionCenter` stops
    // searching other windows), but silently dropped — no crash, no
    // respawn, no queue — inside `WorkspaceTerminalController.sendReply(_:)`.
    #expect(session.deliverTerminalReply("hello", to: controller.id) == true)
}

@MainActor
@Test("sendReply is a no-op returning false with no live view or once exited")
func sendReplyNoOpsWithNoLiveViewOrOnceExited() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    // Lazy spawn (ADR 0004): no view was ever mounted, so there is nothing
    // to send into yet.
    #expect(controller.sendReply("hello") == false)

    controller.processDidTerminate(exitCode: nil)
    #expect(controller.sendReply("hello") == false)
}

@MainActor
@Test("TerminalAttentionCenter.deliverReply drops silently when no registered session owns the id")
func attentionCenterDeliverReplyDropsUnknownSessionSilently() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    TerminalAttentionCenter.shared.register(session)

    // Must not crash; there is nothing to assert beyond "this returns".
    TerminalAttentionCenter.shared.deliverReply("hello", to: UUID())
}

// MARK: - attention-cleared wiring (terminal-notch-hud.md)

@MainActor
@Test("clearing .bell notifies the HUD exactly once; clearing outside .bell is silent")
func clearingBellNotifiesHUD() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    let hud = SpyNotchHUD()
    session.attentionHUD = hud

    controller.markRunningForTesting()
    controller.noteBell()
    #expect(hud.clearedIDs.isEmpty)

    controller.clearAttention()
    #expect(hud.clearedIDs == [controller.id])

    // A no-op clear (already back to .running) does not re-notify.
    controller.clearAttention()
    #expect(hud.clearedIDs.count == 1)
}

@MainActor
@Test("selecting a belling session's tab dismisses the HUD through the attention-cleared hook")
func selectingTabDismissesHUD() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    session.newTerminalTab()
    let controllers = session.terminal.sessions
    let first = try #require(controllers.first)
    let hud = SpyNotchHUD()
    session.attentionHUD = hud

    first.markRunningForTesting()
    first.noteBell()
    let firstTab = try #require(
        session.editorLayout.group(id: session.editorLayout.focusedGroupID)?.tabs
            .first { $0.resource == .terminal(sessionID: first.id) })
    session.selectEditorTab(firstTab.id, in: session.editorLayout.focusedGroupID)

    #expect(first.status == .running)
    #expect(hud.clearedIDs == [first.id])
}
