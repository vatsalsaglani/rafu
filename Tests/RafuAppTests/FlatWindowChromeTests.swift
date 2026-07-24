import AppKit
import Testing

@testable import RafuApp

/// Regression for "the system title bar came back after exiting full screen":
/// AppKit rebuilds the window's frame view across a full-screen transition and
/// restores the stock titlebar, so chrome applied once at attach time is
/// silently undone. The opaque band then covers the title bar Rafu draws in
/// that same zone, taking the sidebar toggle with it.
@Suite("Flat window chrome")
@MainActor
struct FlatWindowChromeTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    @Test("Binding hides the system title and makes the titlebar transparent")
    func bindAppliesFlatChrome() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }

        coordinator.bind(to: window)

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test("A full-screen exit that restores the stock titlebar is re-flattened")
    func fullScreenExitReappliesChrome() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }
        coordinator.bind(to: window)

        // Exactly what AppKit does when it rebuilds the frame view on exit.
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)

        NotificationCenter.default.post(
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test("Becoming key also re-applies, covering any other AppKit reset")
    func becomingKeyReappliesChrome() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }
        coordinator.bind(to: window)

        window.titlebarAppearsTransparent = false

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        #expect(window.titlebarAppearsTransparent)
    }

    /// The content merge relies on the WINDOW-level safe-area cancellation
    /// (`additionalSafeAreaInsets.top = -base`), not per-view
    /// `.ignoresSafeArea` — split-view panes re-derive the safe area on
    /// their own schedule and drift out of sync with view-level escapes.
    @Test("Binding cancels the titlebar's top safe area at the window level")
    func bindCancelsTopSafeArea() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }

        coordinator.bind(to: window)

        #expect(window.contentView != nil)
        #expect(window.contentView?.safeAreaInsets.top == 0)
    }

    /// Tabs live in the titlebar's implicit drag region; with `isMovable`
    /// left on, dragging a tab also dragged the whole window. Movement is
    /// restored via explicit `WindowDragHandle` surfaces instead.
    @Test("Binding disables implicit window dragging")
    func bindDisablesImplicitWindowDrag() {
        let window = makeWindow()
        #expect(window.isMovable)
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }

        coordinator.bind(to: window)

        #expect(!window.isMovable)
    }

    @Test("Binding removes the titlebar separator")
    func bindRemovesTitlebarSeparator() {
        let window = makeWindow()
        window.titlebarSeparatorStyle = .automatic
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }

        coordinator.bind(to: window)

        #expect(window.titlebarSeparatorStyle == .none)
    }

    @Test("hidesTrafficLights hides the standard window buttons, and only then")
    func trafficLightVisibilityFollowsFlag() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }

        coordinator.hidesTrafficLights = true
        coordinator.bind(to: window)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == true)

        coordinator.hidesTrafficLights = false
        coordinator.bind(to: window)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        #expect(window.standardWindowButton(.zoomButton)?.isHidden == false)
    }

    @Test("Binding reports the window's initial full-screen state")
    func bindReportsFullScreenState() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }
        var reported: Bool?
        coordinator.onFullScreenChange = { reported = $0 }

        coordinator.bind(to: window)

        #expect(reported == false)
    }

    /// `_NSTitlebarDecorationView` is the macOS 26 view that paints the
    /// opaque band across an INACTIVE window's titlebar zone even when
    /// `titlebarAppearsTransparent` is set; the matcher drives the scrub
    /// that hides it. `NSTitlebarView` hosts the traffic lights and
    /// `NSTitlebarBackgroundView` is already managed by AppKit — neither
    /// may ever match.
    @Test("Backdrop class matcher targets decoration/material views only")
    func backdropClassMatcher() {
        #expect(FlatWindowChrome.isTitlebarBackdropClassName("_NSTitlebarDecorationView"))
        #expect(FlatWindowChrome.isTitlebarBackdropClassName("NSVisualEffectView"))
        #expect(FlatWindowChrome.isTitlebarBackdropClassName("NSGlassContainerView"))
        #expect(!FlatWindowChrome.isTitlebarBackdropClassName("NSTitlebarView"))
        #expect(!FlatWindowChrome.isTitlebarBackdropClassName("NSTitlebarBackgroundView"))
        #expect(!FlatWindowChrome.isTitlebarBackdropClassName("_NSThemeCloseWidget"))
    }

    @Test("Detaching stops re-applying so a closed window is not retained")
    func detachStopsReapplying() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        coordinator.bind(to: window)
        coordinator.detach()

        window.titlebarAppearsTransparent = false
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        #expect(!window.titlebarAppearsTransparent)
    }
}
