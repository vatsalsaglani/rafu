import AppKit
import SwiftUI

/// The seam between `WorkspaceSession` and the HUD (terminal-notch-hud.md
/// N-3) — mirrors `TerminalAttentionNotifying`: tests inject a spy so no
/// headless test ever constructs or shows the real panel.
@MainActor
protocol NotchHUDPresenting: AnyObject {
    /// Shows (or updates) the HUD for a belling session. `theme` is passed
    /// ON SHOW from the belling session's workspace — the HUD belongs to no
    /// window/scene, so it cannot read one from an `@Environment`.
    func show(_ event: NotchHUDEvent, theme: RafuTheme)
    /// Called by the workspace when a session's `.bell` clears for any
    /// reason (tab selected, session revealed, reply sent) — the HUD does
    /// not own attention state, it dismisses when that state clears.
    func attentionCleared(for sessionID: UUID)
}

/// Why the HUD went away — each case maps to a product-decision-5 rule.
nonisolated enum NotchHUDDismissReason: Equatable, Sendable {
    case timeout
    case escape
    case replied
    case revealed
    case queueRevealed
    case attentionCleared
}

/// App-global owner of the one notch HUD (terminal-notch-hud.md N-3) — a
/// singleton beside `TerminalAttentionCenter`, because bells arrive with
/// window context but the HUD is one-per-Mac, not one-per-window.
///
/// PRESENTATION ONLY: every value it shows arrives in the `NotchHUDEvent`
/// it is handed (already bounded/sanitized by the existing seams). It never
/// reads a terminal buffer, never sanitizes a reply itself beyond the one
/// approved `TerminalAttentionPolicy.sanitizedReply` call, and never logs,
/// persists, or transmits the snippet — `event` is set to `nil` on dismiss
/// and that is the only lifetime the snippet has.
@Observable
@MainActor
final class NotchHUDController: NSObject, NotchHUDPresenting {
    static let shared = NotchHUDController()

    // MARK: - View-visible state

    /// The session currently shown; `nil` while dismissed. The snippet it
    /// carries is dropped (set to `nil`) on dismissal and lives nowhere
    /// else (ADR 0016's privacy rules, carried over verbatim).
    private(set) var event: NotchHUDEvent?
    /// Superseded-session count behind the "+N more" chip (queue of one).
    private(set) var pendingCount = 0
    private(set) var state: NotchHUDState = .compact
    /// The theme captured at show time; never read from an environment.
    private(set) var theme = RafuThemeCatalog.indigo
    /// The user's in-progress reply. Dropped with the event on dismissal.
    var replyText = ""
    /// Whether the reply field is engaged — THE focus-recipe flag the
    /// panel's `canBecomeKey` reads.
    private(set) var isReplyEngaged = false
    /// Pointer-over-HUD state; hovering pauses the auto-dismiss timer.
    var isHovered = false

    // MARK: - Private infrastructure

    @ObservationIgnored
    private var panel: NotchHUDPanel?
    @ObservationIgnored
    private var dismissTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastInteraction = Date.distantPast

    // MARK: - Test seams (mirroring WorkspaceSession.attentionNotifier)

    /// The reply route. Production default: the existing, security-reviewed
    /// `TerminalAttentionCenter.deliverReply` — the ONLY delivery path.
    @ObservationIgnored
    var deliverReply: (String, UUID) -> Void = { text, sessionID in
        TerminalAttentionCenter.shared.deliverReply(text, to: sessionID)
    }
    /// Reveal routes (presentation only). Production defaults: the center's
    /// weak-registry lookups; tests substitute spies.
    @ObservationIgnored
    var revealSession: (UUID) -> Void = { sessionID in
        TerminalAttentionCenter.shared.revealTerminalSession(sessionID)
    }
    @ObservationIgnored
    var revealTerminalsPanel: (UUID) -> Void = { sessionID in
        TerminalAttentionCenter.shared.showTerminalsPanel(for: sessionID)
    }
    /// Attention-state query backing the dismiss timer's `stillNeedsAttention`.
    @ObservationIgnored
    var sessionNeedsAttention: (UUID) -> Bool = { sessionID in
        TerminalAttentionCenter.shared.sessionNeedsAttention(sessionID)
    }

    // MARK: - Layout constants

    static let layoutWidth: CGFloat = 384
    static let compactHeight: CGFloat = 52
    static let expandedHeight: CGFloat = 196

    /// Selector-based observation (matching `FlatWindowChrome.Coordinator`)
    /// keeps this `@MainActor` singleton out of `@Sendable` closures.
    /// Internal (not `private`) so tests can construct their OWN instance —
    /// hermetic under parallel test runs, unlike mutating `.shared`.
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

    /// Dock/undock, resolution change, display (dis)connect: recompute the
    /// frame from the CURRENT screen (geometry is pure and cheap).
    @objc
    private func screenParametersDidChange() {
        reposition(animated: false)
    }

    /// Key status went elsewhere: disengage so a later show starts
    /// non-activating again. The reply text stays. Registered per-panel (the
    /// notification's object), so no identity check is needed here.
    @objc
    private func panelDidResignKey() {
        disengageReply()
    }

    // MARK: - Show / dismiss lifecycle

    func show(_ incoming: NotchHUDEvent, theme: RafuTheme) {
        let merged = NotchHUDPolicy.merge(
            current: event, incoming: incoming, pendingCount: pendingCount)
        event = merged.shown
        pendingCount = merged.pendingCount
        self.theme = theme
        replyText = ""
        presentPanel()
        noteInteraction()
        startDismissTimer()
    }

    func dismiss(reason: NotchHUDDismissReason) {
        guard event != nil || panel != nil else { return }
        dismissTask?.cancel()
        dismissTask = nil
        // The snippet and any in-progress reply die here — the HUD's one
        // and only copy of terminal content.
        event = nil
        pendingCount = 0
        replyText = ""
        isReplyEngaged = false
        isHovered = false
        state = .compact
        guard let panel else { return }
        panel.allowsKeyStatus = false
        if panel.isKeyWindow { panel.resignKey() }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = reduceMotion ? 0.01 : 0.18
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self, weak panel] in
                Task { @MainActor [weak self, weak panel] in
                    // A fresh show may have re-used the panel while this fade ran.
                    guard let self, self.event == nil else { return }
                    panel?.orderOut(nil)
                }
            })
    }

    func attentionCleared(for sessionID: UUID) {
        guard event?.sessionID == sessionID else { return }
        dismiss(reason: .attentionCleared)
    }

    // MARK: - User actions (driven by NotchHUDView)

    /// Compact pill click → the expanded state (full snippet + reply).
    func expand() {
        guard state == .compact, event != nil else { return }
        state = .expanded
        noteInteraction()
        reposition(animated: true)
    }

    /// Reply-field engagement: the moment the panel MAY become key.
    func engageReply() {
        guard event != nil, let panel else { return }
        isReplyEngaged = true
        panel.allowsKeyStatus = true
        panel.makeKey()
        noteInteraction()
    }

    func disengageReply() {
        isReplyEngaged = false
        panel?.allowsKeyStatus = false
    }

    /// Send: sanitize through the ONE approved path, deliver through the
    /// ONE existing route, dismiss. An empty reply is a no-op (stays up).
    func sendReply() {
        guard let event else { return }
        guard let sanitized = TerminalAttentionPolicy.sanitizedReply(replyText) else { return }
        deliverReply(sanitized, event.sessionID)
        dismiss(reason: .replied)
    }

    func escapePressed() {
        dismiss(reason: .escape)
    }

    /// Clicking the session name reveals its tab (and dismisses — the
    /// reveal itself clears `.bell`, which would dismiss us anyway).
    func revealSessionAndDismiss() {
        guard let event else { return }
        revealSession(event.sessionID)
        dismiss(reason: .revealed)
    }

    /// The "+N more" chip reveals the Terminals panel — the many-sessions
    /// surface; the HUD stays a queue of one by design.
    func revealQueueAndDismiss() {
        guard let event else { return }
        revealTerminalsPanel(event.sessionID)
        dismiss(reason: .queueRevealed)
    }

    func noteInteraction() {
        lastInteraction = Date()
    }

    /// Test-only (mirroring `WorkspaceTerminalController.markRunningForTesting`):
    /// installs an event WITHOUT presenting the panel, so a headless test
    /// can drive the reply path (`sendReply`). Production events arrive
    /// only via `show(_:theme:)`.
    func installEventForTesting(_ event: NotchHUDEvent) {
        self.event = event
    }

    // MARK: - Panel presentation

    private func contentSize(for state: NotchHUDState) -> CGSize {
        CGSize(
            width: Self.layoutWidth,
            height: state == .compact ? Self.compactHeight : Self.expandedHeight)
    }

    /// Height of the notch/menu-bar band the window overlaps on a notched
    /// screen — the view pads its content down by this so nothing is laid
    /// out beside the physical housing (0 on the non-notch fallback).
    private(set) var bandInset: CGFloat = 0

    private func presentPanel() {
        guard let metrics = NotchScreenAdapter.currentMetrics() else { return }
        bandInset = NotchHUDGeometry.bandInset(for: metrics)
        let target = NotchHUDGeometry.hudFrame(
            for: metrics, contentSize: contentSize(for: state), state: state)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if let panel {
            // Already visible: a newer event replaced the shown one — keep
            // the top edge pinned (the geometry does that).
            panel.setFrame(target, display: true, animate: !reduceMotion)
            panel.alphaValue = 1
            panel.orderFrontRegardless()
            return
        }
        let panel = NotchHUDPanel(contentRect: target)
        panel.onCancel = { [weak self] in self?.escapePressed() }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(self.panelDidResignKey),
            name: NSWindow.didResignKeyNotification,
            object: panel
        )
        let hostingView = NSHostingView(rootView: NotchHUDView(controller: self))
        hostingView.frame = NSRect(origin: .zero, size: target.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        self.panel = panel
        // Appear WITHOUT activating: slide down from behind the notch and
        // fade in — or fade only under Reduce Motion.
        if reduceMotion {
            panel.alphaValue = 0
            panel.setFrame(target, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 1
            }
        } else {
            let start = target.offsetBy(dx: 0, dy: 8)
            panel.alphaValue = 0
            panel.setFrame(start, display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        }
    }

    /// Recompute the frame from the CURRENT screen — on state change
    /// (compact ↔ expanded grows downward only) and on screen-parameter
    /// changes (dock/undock, resolution change).
    private func reposition(animated: Bool) {
        guard let panel, event != nil,
            let metrics = NotchScreenAdapter.currentMetrics()
        else { return }
        bandInset = NotchHUDGeometry.bandInset(for: metrics)
        let target = NotchHUDGeometry.hudFrame(
            for: metrics, contentSize: contentSize(for: state), state: state)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.setFrame(target, display: true, animate: animated && !reduceMotion)
    }

    // MARK: - Auto-dismiss timer (12s, hover-paused)

    private func startDismissTimer() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                self.evaluateAutoDismiss()
            }
        }
    }

    private func evaluateAutoDismiss() {
        guard let event else { return }
        // Hovering pauses the countdown entirely (product decision 5).
        if isHovered { noteInteraction() }
        let seconds = Date().timeIntervalSince(lastInteraction)
        if NotchHUDPolicy.shouldDismiss(
            didReply: false,
            escapePressed: false,
            secondsSinceInteraction: seconds,
            stillNeedsAttention: sessionNeedsAttention(event.sessionID),
            isHovered: isHovered
        ) {
            dismiss(reason: .timeout)
        }
    }

}
