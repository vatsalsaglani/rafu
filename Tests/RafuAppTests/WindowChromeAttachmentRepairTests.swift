import AppKit
import Testing

@testable import RafuApp

@Suite("Window chrome attachment repair")
@MainActor
struct WindowChromeAttachmentRepairTests {
    @Test("A window attached after the next main-queue turn still receives chrome")
    func lateAttachmentReceivesChrome() async throws {
        let coordinator = FlatWindowChrome.Coordinator()
        let view = FlatWindowChrome.AttachmentView(frame: .zero)
        coordinator.hidesTrafficLights = true
        coordinator.attach(to: view)
        defer { FlatWindowChrome.dismantleNSView(view, coordinator: coordinator) }

        // The old one-shot lookup could expire before the view had a window.
        // Wait for a queue boundary, not an arbitrary amount of wall time.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(view.window == nil)
        #expect(coordinator.chromeApplicationCount == 0)

        let window = makeWindow()
        let contentView = try #require(window.contentView)
        contentView.addSubview(view)

        #expect(view.window === window)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.contentView?.safeAreaInsets.top == 0)
        #expect(!window.isMovable)
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        #expect(window.standardWindowButton(.zoomButton) != nil)
    }

    @Test("Attachment uses the latest configuration and topology")
    func unattachedUpdatesUseLatestValues() throws {
        let coordinator = FlatWindowChrome.Coordinator()
        let view = FlatWindowChrome.AttachmentView(frame: .zero)
        coordinator.attach(to: view)
        let token = FlatWindowChrome.TopologyToken(
            editorNodes: [], focusedGroupID: nil,
            canvasIdentity: "welcome", windowTitleIdentity: "New Workspace"
        )
        coordinator.titleBarColor = .red
        coordinator.hidesTrafficLights = true
        coordinator.attach(to: view, topologyToken: token)
        defer { FlatWindowChrome.dismantleNSView(view, coordinator: coordinator) }
        let window = makeWindow()
        try #require(window.contentView).addSubview(view)

        #expect(window.backgroundColor.isEqual(NSColor.red))
        #expect(window.standardWindowButton(.closeButton)?.isHidden == true)
        let applicationCount = coordinator.chromeApplicationCount
        coordinator.attach(to: view, topologyToken: token)
        #expect(coordinator.chromeApplicationCount == applicationCount)
    }

    @Test("Removal cancels repairs and reattachment targets only the new window")
    func reattachmentKeepsWindowsIndependent() throws {
        let coordinator = FlatWindowChrome.Coordinator()
        let view = FlatWindowChrome.AttachmentView(frame: .zero)
        coordinator.attach(to: view)
        defer { FlatWindowChrome.dismantleNSView(view, coordinator: coordinator) }
        let firstWindow = makeWindow()
        try #require(firstWindow.contentView).addSubview(view)
        #expect(coordinator.pendingDeferredPassCount > 0)

        view.removeFromSuperview()
        #expect(coordinator.pendingDeferredPassCount == 0)
        firstWindow.titleVisibility = .visible
        firstWindow.titlebarAppearsTransparent = false
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification, object: firstWindow
        )
        #expect(firstWindow.titleVisibility == .visible)

        let secondWindow = makeWindow()
        try #require(secondWindow.contentView).addSubview(view)
        coordinator.performNextDeferredPassForTesting()

        #expect(secondWindow.titleVisibility == .hidden)
        #expect(secondWindow.titlebarAppearsTransparent)
        #expect(firstWindow.titleVisibility == .visible)
        #expect(!firstWindow.titlebarAppearsTransparent)
    }

    @Test("A dismantled bridge cannot bind again when its view moves")
    func dismantledViewCannotRebind() throws {
        let coordinator = FlatWindowChrome.Coordinator()
        let view = FlatWindowChrome.AttachmentView(frame: .zero)
        coordinator.attach(to: view)
        FlatWindowChrome.dismantleNSView(view, coordinator: coordinator)
        let window = makeWindow()
        try #require(window.contentView).addSubview(view)

        #expect(coordinator.chromeApplicationCount == 0)
        #expect(coordinator.pendingDeferredPassCount == 0)
        #expect(window.titleVisibility == .visible)
        #expect(view.coordinator == nil)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
    }
}
