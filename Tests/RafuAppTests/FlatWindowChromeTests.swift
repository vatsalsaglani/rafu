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
