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
    @ObservationIgnored
    var preferenceStore = NotchCompanionPreferenceStore()

    // MARK: - Layout constants (peek panel content sizing)

    private static let editorRowHeight: CGFloat = 56
    private static let emptyStateHeight: CGFloat = 64

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
    func refreshEditorRows() {
        entries.removeAll { $0.session == nil }
        let inputs = entries.compactMap { entry -> CompanionEditorInput? in
            guard let session = entry.session else { return nil }
            return Self.companionInput(
                for: session, id: entry.id, windowNumber: Self.windowNumber(for: session))
        }
        editorRows = CompanionEditorRow.editorRows(from: inputs)
        attentionCount = editorRows.reduce(0) { $0 + $1.attentionCount }
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

    /// Focuses the workspace window backing a companion row (row click, or
    /// — until NC-C's per-session reveal lands — the attention chip too).
    /// A no-op once the session's window has closed.
    func focusEditor(_ id: UUID) {
        entries.removeAll { $0.session == nil }
        guard let session = entries.first(where: { $0.id == id })?.session else { return }
        WorkspaceWindowRegistry.shared.focus(session: session)
    }

    // MARK: - Activation (existence, not hover state)

    /// Creates (or tears down) the persistent strip window. Idempotent —
    /// safe to call from app launch, a preference change (NC-E), and every
    /// screen-parameter change. `nil` panel + disabled/non-notch is already
    /// the correct end state, so this never no-ops into a half-torn-down
    /// window.
    func activateIfEnabled() {
        guard preferenceStore.isEnabled(),
            let metrics = NotchScreenAdapter.currentMetrics(),
            NotchCompanionGeometry.restingStripFrame(for: metrics) != nil
        else {
            teardown()
            return
        }
        if panel == nil {
            presentPanel(metrics: metrics)
        } else {
            reposition()
        }
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
        guard let frame = NotchCompanionGeometry.restingStripFrame(for: metrics) else { return }
        theme = RafuThemeCatalog.resolvedForCurrentAppearance()
        bandInset = NotchHUDGeometry.bandInset(for: metrics)
        let panel = NotchHUDPanel(contentRect: frame)
        panel.onCancel = { [weak self] in self?.escapePressed() }
        let hostingView = NotchHUDPassthroughHostingView(rootView: NotchCompanionView(model: self))
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        panel.clickThroughRegions = NotchCompanionGeometry.clickThroughRegions(for: metrics)
        self.panel = panel
        panel.orderFrontRegardless()
        refreshEditorRows()
    }

    private func teardown() {
        cancelTimers()
        panel?.orderOut(nil)
        panel = nil
        hoverState = .resting
    }

    /// Recomputes the panel's frame/click-through regions from the CURRENT
    /// screen for the CURRENT `hoverState` — resting stays pinned to
    /// `restingStripFrame` with the notch click-through; peeking/pinned
    /// grows downward to `peekPanelFrame`, matching content height, with the
    /// whole panel interactive (no click-through while open).
    private func reposition() {
        guard let panel, let metrics = NotchScreenAdapter.currentMetrics() else { return }
        bandInset = NotchHUDGeometry.bandInset(for: metrics)
        switch hoverState {
        case .resting:
            guard let frame = NotchCompanionGeometry.restingStripFrame(for: metrics) else {
                teardown()
                return
            }
            panel.setFrame(frame, display: true)
            panel.clickThroughRegions = NotchCompanionGeometry.clickThroughRegions(for: metrics)
        case .peeking, .pinned:
            let frame = NotchCompanionGeometry.peekPanelFrame(
                for: metrics, contentHeight: peekContentHeight())
            panel.setFrame(frame, display: true)
            panel.clickThroughRegions = []
        }
    }

    private func peekContentHeight() -> CGFloat {
        let listHeight: CGFloat
        if editorRows.isEmpty {
            listHeight = Self.emptyStateHeight
        } else {
            let rows = CGFloat(editorRows.count) * Self.editorRowHeight
            let spacing = CGFloat(max(editorRows.count - 1, 0)) * RafuMetrics.space2
            listHeight = rows + spacing + RafuMetrics.space3 * 2
        }
        return bandInset + listHeight
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

    func hoverExited() {
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
        refreshEditorRows()
    }

    private func graceTimerFired() {
        graceTimer = nil
        let next = CompanionHoverPolicy.onHoverExitAfterGrace(hoverState)
        guard next != hoverState else { return }
        hoverState = next
        reposition()
    }

    /// A click on a wing: pins open (or, already pinned, toggles back to a
    /// still-open peek) — `CompanionHoverPolicy.onClick` never returns
    /// `.resting`, so this always ends with the panel open and its rows
    /// fresh.
    func clicked() {
        cancelTimers()
        hoverState = CompanionHoverPolicy.onClick(hoverState)
        refreshTheme()
        refreshEditorRows()
    }

    func escapePressed() {
        cancelTimers()
        let next = CompanionHoverPolicy.onEscape(hoverState)
        guard next != hoverState else { return }
        hoverState = next
        reposition()
    }

    private func cancelTimers() {
        dwellTimer?.invalidate()
        dwellTimer = nil
        graceTimer?.invalidate()
        graceTimer = nil
    }
}
