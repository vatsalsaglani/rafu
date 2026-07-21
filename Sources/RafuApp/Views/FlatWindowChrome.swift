import AppKit
import SwiftUI

/// Applies Rafu's flat window chrome (ADR 0012) to the hosting `NSWindow` and
/// reports full-screen transitions, so `WorkspaceWindowView` can draw its own
/// title bar in place of the system band.
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
/// Dropping the toolbar does NOT center the system title: with a transparent
/// titlebar the title draws at the LEADING edge, jammed against the traffic
/// lights. So the system title is hidden here and Rafu draws its own centered
/// one — which also keeps it flat, themed, and free of any glass treatment.
struct FlatWindowChrome: NSViewRepresentable {
    /// Painted behind the traffic lights. SwiftUI content laid out in the
    /// titlebar zone is not rendered there (only backgrounds bleed), so the
    /// zone is coloured through the window itself; matching
    /// `windowTitleBar`'s fill makes the two read as ONE bar.
    let titleBarColor: NSColor

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.titleBarColor = titleBarColor
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.titleBarColor = titleBarColor
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Selector-based notification observation (rather than the closure API)
    /// keeps this `@MainActor` type out of a `@Sendable` closure, matching
    /// `EditorGutterRulerView`'s observer pattern.
    @MainActor
    final class Coordinator: NSObject {
        var titleBarColor: NSColor = .windowBackgroundColor
        private weak var window: NSWindow?

        deinit { NotificationCenter.default.removeObserver(self) }

        /// `view.window` is `nil` until AppKit finishes inserting the view
        /// into a window's hierarchy, which has not happened during
        /// `makeNSView` itself — deferring one main run-loop turn is the
        /// standard way to observe it (same reason as `WindowAccessor`).
        func attach(to view: NSView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                self.bind(to: window)
            }
        }

        /// Headless seam: `attach(to:)` has to defer a run-loop turn before
        /// `view.window` exists, so tests bind a window directly.
        func bind(to window: NSWindow) {
            if window !== self.window {
                detach()
                self.window = window
                observe(window)
            }
            applyChrome(to: window)
        }

        func detach() {
            NotificationCenter.default.removeObserver(self)
            window = nil
        }

        private func observe(_ window: NSWindow) {
            let center = NotificationCenter.default
            for name in [
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification,
                NSWindow.didBecomeKeyNotification,
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
        /// back to `.visible` and `titlebarAppearsTransparent` back to
        /// `false`. Applying the chrome once at attach time is therefore not
        /// enough — after a full-screen round trip the opaque system band
        /// reappears, drawing its leading title and covering the title bar
        /// Rafu renders in that same zone (which is why the sidebar toggle
        /// vanished). Re-apply on every transition, and on `didBecomeKey` as
        /// a cheap net for any other AppKit reset.
        @objc private func windowChromeNeedsReapply(_ notification: Notification) {
            guard let window else { return }
            applyChrome(to: window)
        }

        private func applyChrome(to window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = titleBarColor
        }
    }
}
