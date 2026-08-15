import AppKit
import SwiftUI

/// Applies Rafu's flat window chrome (ADR 0012) to the hosting `NSWindow` and
/// reports full-screen transitions, so `WorkspaceWindowView` can lay out the
/// top-left control cluster around the traffic lights.
///
/// Rafu deliberately carries NO `NSToolbar`, for two macOS 26 reasons:
///
/// 1. Every toolbar item is wrapped in a Liquid Glass capsule with a border
///    and a drop shadow — including a bare `Text` used as a `.principal`
///    item, which rendered the window title as a floating pill.
/// 2. A window WITH a toolbar keeps its titlebar band permanently on screen
///    in full screen (the Safari behavior). Without one, AppKit auto-hides
///    the titlebar and reveals it when the pointer reaches the top edge.
///
/// Window content merges with the titlebar zone: `WorkspaceWindowView`
/// applies `.ignoresSafeArea(.container, edges: .top)`, which DOES render
/// SwiftUI content under the transparent titlebar (an earlier note here
/// claimed only backgrounds bleed into that zone — that is true merely of
/// content that respects the top safe area). The window `backgroundColor`
/// still matches the sidebar surface as a fallback for the first frames
/// before SwiftUI lays out.
///
/// Two AppKit behaviors fight the flat look and are both handled here:
///
/// - `titlebarAppearsTransparent` hides `NSTitlebarBackgroundView` but NOT
///   the private `_NSTitlebarDecorationView`, which on macOS 26 draws an
///   opaque band across the top of an INACTIVE window. `scrubTitlebarBackdrop`
///   hides it (and any glass/visual-effect companions) by class-name match.
/// - AppKit rebuilds the frame view across a full-screen transition,
///   restoring the stock titlebar and RECREATING the decoration view —
///   sometimes after the transition notification has already fired. Chrome
///   is therefore re-applied on every relevant notification AND again on
///   short delayed passes, which is what actually catches the rebuilt
///   decoration view (verified in the TitleBarProto spike, 2026-07-25).
struct FlatWindowChrome: NSViewRepresentable {
    /// A bounded, value-semantic description of the window-hosted editor
    /// topology. It contains only group/split/tab identity, the selected
    /// canvas identity, and the logical window title. A changed value tells
    /// the AppKit bridge that SwiftUI may have replaced hosting content after
    /// the bridge's immediate update.
    nonisolated struct TopologyToken: Equatable, Sendable {
        nonisolated enum EditorNode: Equatable, Sendable {
            case group(id: UUID, tabIDs: [UUID], selectedTabID: UUID?)
            case split(id: UUID, axis: String)
        }

        let editorNodes: [EditorNode]
        let focusedGroupID: UUID?
        let canvasIdentity: String
        let windowTitleIdentity: String

        static let empty = TopologyToken(
            editorNodes: [],
            focusedGroupID: nil,
            canvasIdentity: "empty",
            windowTitleIdentity: ""
        )
    }

    /// Painted behind the first frames and the titlebar zone fallback;
    /// matches the sidebar surface so the zone reads as one surface.
    let titleBarColor: NSColor

    /// Changes only when bounded workbench topology/canvas identity changes.
    var topologyToken: TopologyToken = .empty

    /// Hides the traffic lights while the pointer is away from the top-left
    /// hover cluster. Ignored in full screen, where the system manages them.
    var hidesTrafficLights: Bool = false

    /// Reports full-screen transitions so SwiftUI can drop the traffic-light
    /// inset (the lights don't occupy window space in full screen).
    var onFullScreenChange: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        configure(context.coordinator)
        context.coordinator.attach(to: view, topologyToken: topologyToken)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(context.coordinator)
        context.coordinator.attach(to: nsView, topologyToken: topologyToken)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configure(_ coordinator: Coordinator) {
        coordinator.titleBarColor = titleBarColor
        coordinator.hidesTrafficLights = hidesTrafficLights
        coordinator.onFullScreenChange = onFullScreenChange
    }

    /// Matches the private AppKit views that paint titlebar material over
    /// Rafu's flat chrome. `_NSTitlebarDecorationView` is the inactive-window
    /// band on macOS 26; the glass/visual-effect names cover the materials
    /// AppKit has used across releases. Deliberately does NOT match
    /// `NSTitlebarView`/`NSTitlebarBackgroundView` (the container holding the
    /// traffic lights, and the view `titlebarAppearsTransparent` already
    /// manages).
    nonisolated static func isTitlebarBackdropClassName(_ name: String) -> Bool {
        name.contains("Decoration") || name.contains("VisualEffect")
            || name.contains("Glass") || name.contains("Backdrop")
            || name.contains("Separator")
    }

    /// Selector-based notification observation (rather than the closure API)
    /// keeps this `@MainActor` type out of a `@Sendable` closure, matching
    /// `EditorGutterRulerView`'s observer pattern.
    @MainActor
    final class Coordinator: NSObject {
        var titleBarColor: NSColor = .windowBackgroundColor
        var hidesTrafficLights = false
        var onFullScreenChange: ((Bool) -> Void)?

        private weak var window: NSWindow?
        private var topologyToken: TopologyToken?
        private var attachGeneration = 0
        private var appliedTitleBarColor: NSColor?
        private var appliedHidesTrafficLights: Bool?
        private var pendingDeferredPasses: [UUID: DispatchWorkItem] = [:]

        private(set) var chromeApplicationCount = 0
        private(set) var reapplyScheduleGeneration = 0
        var pendingDeferredPassCount: Int { pendingDeferredPasses.count }

        private static let postTransactionDelays: [TimeInterval] = [0.05, 0.3, 1.0]

        deinit { NotificationCenter.default.removeObserver(self) }

        /// `view.window` is `nil` until AppKit finishes inserting the view
        /// into a window's hierarchy, which has not happened during
        /// `makeNSView` itself — deferring one main run-loop turn is the
        /// standard way to observe it (same reason as `WindowAccessor`).
        func attach(to view: NSView, topologyToken: TopologyToken = .empty) {
            attachGeneration &+= 1
            let generation = attachGeneration
            if let window = view.window {
                bind(to: window, topologyToken: topologyToken)
                return
            }
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, self.attachGeneration == generation,
                    let window = view?.window
                else { return }
                self.bind(to: window, topologyToken: topologyToken)
            }
        }

        /// Headless seam: `attach(to:)` has to defer a run-loop turn before
        /// `view.window` exists, so tests bind a window directly.
        func bind(to window: NSWindow, topologyToken: TopologyToken = .empty) {
            if window !== self.window {
                detach()
                self.window = window
                self.topologyToken = topologyToken
                observe(window)
                onFullScreenChange?(window.styleMask.contains(.fullScreen))
                scheduleChromeReapply(
                    for: window,
                    topologyToken: topologyToken,
                    includesPostTransactionPasses: true
                )
                return
            }

            let topologyChanged = topologyToken != self.topologyToken
            let configurationChanged = currentConfigurationNeedsApply
            self.topologyToken = topologyToken
            if topologyChanged {
                scheduleChromeReapply(
                    for: window,
                    topologyToken: topologyToken,
                    includesPostTransactionPasses: true
                )
            } else if configurationChanged {
                scheduleChromeReapply(
                    for: window,
                    topologyToken: topologyToken,
                    includesPostTransactionPasses: false
                )
            }
        }

        func detach() {
            attachGeneration &+= 1
            NotificationCenter.default.removeObserver(self)
            cancelDeferredPasses()
            window = nil
            topologyToken = nil
            appliedTitleBarColor = nil
            appliedHidesTrafficLights = nil
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
            ] {
                center.addObserver(
                    self,
                    selector: #selector(self.windowChromeNeedsReapply),
                    name: name,
                    object: window
                )
            }
        }

        /// AppKit rebuilds the window's frame view across a full-screen
        /// transition and RESTORES the stock titlebar: `titleVisibility` goes
        /// back to `.visible`, `titlebarAppearsTransparent` back to `false`,
        /// and a fresh `_NSTitlebarDecorationView` appears. Applying the
        /// chrome once at attach time is therefore not enough. Worse, the
        /// rebuild can land AFTER this notification fires, so a single
        /// immediate re-apply misses the new decoration view and the opaque
        /// band reappears the next time the window goes inactive — hence the
        /// delayed passes.
        @objc private func windowChromeNeedsReapply(_ notification: Notification) {
            guard let window, let topologyToken else { return }
            switch notification.name {
            case NSWindow.didEnterFullScreenNotification:
                onFullScreenChange?(true)
            case NSWindow.didExitFullScreenNotification:
                onFullScreenChange?(false)
            default:
                break
            }
            scheduleChromeReapply(
                for: window,
                topologyToken: topologyToken,
                includesPostTransactionPasses: true
            )
        }

        /// The one entry point for attach, topology, configuration, and
        /// notification requests. Every request repairs immediately. Requests
        /// that can bracket an AppKit/SwiftUI hosting transaction replace any
        /// older deferred work with exactly three evidence-backed passes, so
        /// duplicate requests never stack an unbounded queue.
        private func scheduleChromeReapply(
            for window: NSWindow,
            topologyToken: TopologyToken,
            includesPostTransactionPasses: Bool
        ) {
            guard window === self.window, topologyToken == self.topologyToken else { return }
            applyChrome(to: window)
            guard includesPostTransactionPasses else { return }

            cancelDeferredPasses()
            reapplyScheduleGeneration &+= 1
            let generation = reapplyScheduleGeneration
            for delay in Self.postTransactionDelays {
                let passID = UUID()
                let workItem = DispatchWorkItem { [weak self, weak window] in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.performDeferredPass(
                            passID,
                            generation: generation,
                            window: window,
                            topologyToken: topologyToken
                        )
                    }
                }
                pendingDeferredPasses[passID] = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
            }
        }

        private func performDeferredPass(
            _ passID: UUID,
            generation: Int,
            window: NSWindow,
            topologyToken: TopologyToken
        ) {
            guard let workItem = pendingDeferredPasses.removeValue(forKey: passID),
                !workItem.isCancelled,
                generation == reapplyScheduleGeneration,
                window === self.window,
                topologyToken == self.topologyToken
            else { return }
            applyChrome(to: window)
        }

        private func cancelDeferredPasses() {
            for workItem in pendingDeferredPasses.values {
                workItem.cancel()
            }
            pendingDeferredPasses.removeAll()
        }

        /// Deterministic headless seam. It models the first bounded delayed
        /// pass without a fixed sleep, then cancels the remaining equivalent
        /// passes so tests never leave delayed work behind.
        func performNextDeferredPassForTesting() {
            guard !pendingDeferredPasses.isEmpty, let window else { return }
            cancelDeferredPasses()
            applyChrome(to: window)
        }

        private var currentConfigurationNeedsApply: Bool {
            guard let appliedTitleBarColor, let appliedHidesTrafficLights else { return true }
            return !appliedTitleBarColor.isEqual(titleBarColor)
                || appliedHidesTrafficLights != hidesTrafficLights
        }

        private func applyChrome(to window: NSWindow) {
            chromeApplicationCount &+= 1
            appliedTitleBarColor = titleBarColor
            appliedHidesTrafficLights = hidesTrafficLights
            // The tab strip and other interactive content live in the
            // titlebar's implicit drag region; without this, dragging a tab
            // (or drag-to-split) also drags the WHOLE WINDOW along. Window
            // movement is restored explicitly through `WindowDragHandle`
            // (`WindowDragGesture` bypasses `isMovable`).
            window.isMovable = false
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.titlebarSeparatorStyle = .none
            window.backgroundColor = titleBarColor
            cancelTitlebarSafeArea(of: window)
            scrubTitlebarBackdrop(of: window)
            applyTrafficLightVisibility(to: window)
        }

        /// Zeroes the titlebar's top safe area AT THE SOURCE, so no hosting
        /// view anywhere in the window reports one. This is what actually
        /// merges content with the titlebar zone: per-view SwiftUI
        /// `.ignoresSafeArea` escapes are NOT equivalent, because every
        /// `HSplitView` pane is its own AppKit hosting view that re-derives
        /// the window safe area on its own schedule — per-pane escapes
        /// under- or over-corrected depending on window lifecycle state
        /// (verified in the TitleBarProto spike, strategy comparison).
        /// In full screen the base inset is already 0, so this is a no-op.
        private func cancelTitlebarSafeArea(of window: NSWindow) {
            guard let contentView = window.contentView else { return }
            let base = contentView.safeAreaInsets.top - contentView.additionalSafeAreaInsets.top
            let target = -base
            if contentView.additionalSafeAreaInsets.top != target {
                contentView.additionalSafeAreaInsets = NSEdgeInsets(
                    top: target, left: 0, bottom: 0, right: 0)
            }
        }

        /// The traffic lights stay in the view hierarchy (hidden, not
        /// removed) so `performClose`/`performZoom` and their accessibility
        /// actions keep working. Full screen leaves them to the system,
        /// which already auto-hides them with the menu bar.
        private func applyTrafficLightVisibility(to window: NSWindow) {
            let hidden = hidesTrafficLights && !window.styleMask.contains(.fullScreen)
            for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = hidden
            }
        }

        private func scrubTitlebarBackdrop(of window: NSWindow) {
            guard let frameView = window.contentView?.superview else { return }
            for sub in frameView.subviews
            where String(describing: type(of: sub)).contains("Titlebar") {
                hideBackdropViews(in: sub)
            }
        }

        private func hideBackdropViews(in view: NSView) {
            for sub in view.subviews {
                let cls = String(describing: type(of: sub))
                if !(sub is NSButton), FlatWindowChrome.isTitlebarBackdropClassName(cls) {
                    // Both, deliberately: AppKit flips `isHidden` back during
                    // window-state transitions (sheet presentation, key
                    // changes), which flashed the band for the milliseconds
                    // until the next notification-driven scrub. It does NOT
                    // restore `alphaValue`, so zero alpha keeps the view
                    // invisible even inside that gap.
                    sub.isHidden = true
                    sub.alphaValue = 0
                }
                hideBackdropViews(in: sub)
            }
        }
    }
}

/// Explicit window-move surface. `FlatWindowChrome` sets `isMovable = false`
/// (the implicit titlebar drag region would otherwise drag the window along
/// with any tab drag), so window movement is opt-in: place this as the
/// `.background` of quiet chrome surfaces (rails, sidebar header,
/// breadcrumb). Interactive controls layered above it still win hit-testing;
/// only clicks on empty area reach the handle.
struct WindowDragHandle: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
    }
}
