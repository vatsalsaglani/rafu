import AppKit
import Testing

@testable import RafuApp

/// Every tab switch re-runs the flat-chrome pass. A repeated pass must not
/// write AppKit window properties whose value is already correct, because each
/// write can invalidate the titlebar.
@Suite("Flat window chrome idempotency")
@MainActor
struct FlatWindowChromeIdempotencyTests {
    private func makeWindow() -> CountingWindow {
        CountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
    }

    @Test("A repeated chrome pass writes no window property again")
    func repeatedPassWritesNothing() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }
        coordinator.bind(to: window)
        let styleMask = window.styleMask
        window.writes = 0
        let applications = coordinator.chromeApplicationCount

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(coordinator.chromeApplicationCount == applications + 1)
        #expect(window.writes == 0)
        #expect(window.styleMask == styleMask)
        #expect(!window.isMovable)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }

    @Test("A value that AppKit reset is still written back")
    func resetValueIsRestored() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        defer { coordinator.detach() }
        coordinator.bind(to: window)

        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovable = true
        window.styleMask.remove(.fullSizeContentView)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(!window.isMovable)
        #expect(window.styleMask.contains(.fullSizeContentView))
    }
}

/// Counts every Swift-side setter call on the window properties that the
/// chrome pass owns, whether or not the value changes.
@MainActor
private final class CountingWindow: NSWindow {
    var writes = 0

    override var isMovable: Bool { didSet { writes += 1 } }
    override var titlebarAppearsTransparent: Bool { didSet { writes += 1 } }
    override var titleVisibility: NSWindow.TitleVisibility { didSet { writes += 1 } }
    override var titlebarSeparatorStyle: NSTitlebarSeparatorStyle { didSet { writes += 1 } }
    override var backgroundColor: NSColor! { didSet { writes += 1 } }
}
