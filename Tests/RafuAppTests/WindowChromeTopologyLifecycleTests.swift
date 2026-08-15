import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Window chrome topology lifecycle")
@MainActor
struct WindowChromeTopologyLifecycleTests {
    @Test("A post-transaction pass repairs stock chrome on the replacement content view")
    func topologyPassRepairsReplacementContentView() throws {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        let firstToken = makeToken(tabIDs: [UUID()])
        let changedToken = makeToken(tabIDs: [UUID(), UUID()])
        let expectedColor = NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.24, alpha: 1)
        coordinator.titleBarColor = expectedColor
        defer { coordinator.detach() }

        coordinator.bind(to: window, topologyToken: firstToken)
        coordinator.bind(to: window, topologyToken: changedToken)

        // This is the proved failure ordering: SwiftUI reports the topology
        // change first, then AppKit replaces hosting content and restores its
        // stock titlebar values after the immediate bridge pass.
        let originalContentView = try #require(window.contentView)
        let originalFrameView = try #require(originalContentView.superview)
        let replacementContentView = NSView(frame: originalContentView.frame)
        window.contentView = replacementContentView
        restoreStockChrome(on: window)
        let currentFrameView = try #require(replacementContentView.superview)

        #expect(window.contentView === replacementContentView)
        #expect(currentFrameView === originalFrameView)
        #expect(window.titleVisibility == .visible)
        #expect(!window.titlebarAppearsTransparent)
        #expect(!window.styleMask.contains(.fullSizeContentView))
        #expect(window.titlebarSeparatorStyle != .none)
        #expect(window.isMovable)

        coordinator.performNextDeferredPassForTesting()

        assertFlatInvariant(window, expectedColor: expectedColor)
        let appliedBaseTopSafeArea =
            replacementContentView.safeAreaInsets.top
            - replacementContentView.additionalSafeAreaInsets.top
        #expect(window.contentView === replacementContentView)
        #expect(appliedBaseTopSafeArea > 0)
        #expect(replacementContentView.additionalSafeAreaInsets.top == -appliedBaseTopSafeArea)
        #expect(window.contentView?.safeAreaInsets.top == 0)
    }

    @Test("Duplicate tokens coalesce while a changed token schedules a fresh bounded repair")
    func tokenCoalescing() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        let firstToken = makeToken(tabIDs: [UUID()])
        let secondToken = makeToken(tabIDs: [UUID(), UUID()])
        defer { coordinator.detach() }

        coordinator.bind(to: window, topologyToken: firstToken)
        let initialApplications = coordinator.chromeApplicationCount
        #expect(coordinator.pendingDeferredPassCount == 3)

        coordinator.bind(to: window, topologyToken: firstToken)
        #expect(coordinator.chromeApplicationCount == initialApplications)
        #expect(coordinator.pendingDeferredPassCount == 3)

        coordinator.bind(to: window, topologyToken: secondToken)
        #expect(coordinator.chromeApplicationCount == initialApplications + 1)
        #expect(coordinator.pendingDeferredPassCount == 3)
    }

    @Test("Detach and window replacement cancel stale scheduled repairs")
    func detachAndReplacementCancelStaleWork() {
        let firstWindow = makeWindow()
        let secondWindow = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        let firstToken = makeToken(tabIDs: [UUID()])
        let secondToken = makeToken(tabIDs: [UUID(), UUID()])

        coordinator.bind(to: firstWindow, topologyToken: firstToken)
        #expect(coordinator.pendingDeferredPassCount == 3)

        coordinator.bind(to: secondWindow, topologyToken: secondToken)
        #expect(coordinator.pendingDeferredPassCount == 3)
        restoreStockChrome(on: firstWindow)
        coordinator.performNextDeferredPassForTesting()

        #expect(firstWindow.titleVisibility == .visible)
        #expect(!firstWindow.titlebarAppearsTransparent)
        assertFlatInvariant(secondWindow, expectedColor: .windowBackgroundColor)

        coordinator.detach()
        #expect(coordinator.pendingDeferredPassCount == 0)
        restoreStockChrome(on: secondWindow)
        coordinator.performNextDeferredPassForTesting()
        #expect(secondWindow.titleVisibility == .visible)
    }

    @Test("Window notifications and topology changes use the same bounded scheduler")
    func notificationAndTopologyRoutesShareScheduler() {
        let window = makeWindow()
        let coordinator = FlatWindowChrome.Coordinator()
        let token = makeToken(tabIDs: [UUID()])
        defer { coordinator.detach() }

        coordinator.bind(to: window, topologyToken: token)
        let topologyGeneration = coordinator.reapplyScheduleGeneration
        restoreStockChrome(on: window)

        NotificationCenter.default.post(
            name: NSWindow.didBecomeMainNotification,
            object: window
        )

        #expect(coordinator.reapplyScheduleGeneration == topologyGeneration + 1)
        #expect(coordinator.pendingDeferredPassCount == 3)
        assertFlatInvariant(window, expectedColor: .windowBackgroundColor)
    }

    @Test("Workspace window passes one bounded topology token to one chrome bridge")
    func workspaceCompositionUsesOneTopologyToken() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")

        #expect(Self.occurrences(of: "FlatWindowChrome(", in: source) == 1)
        #expect(Self.occurrences(of: "topologyToken: windowChromeTopologyToken", in: source) == 1)
        #expect(source.contains("private var windowChromeTopologyToken"))
        #expect(source.contains("session.editorLayout"))
        #expect(source.contains("EditorCanvasRoute.resolve"))
        #expect(source.contains("session.windowTitle"))
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
    }

    private func makeToken(tabIDs: [UUID]) -> FlatWindowChrome.TopologyToken {
        FlatWindowChrome.TopologyToken(
            editorNodes: [
                .group(id: UUID(), tabIDs: tabIDs, selectedTabID: tabIDs.first)
            ],
            focusedGroupID: nil,
            canvasIdentity: "editor",
            windowTitleIdentity: "Workspace"
        )
    }

    private func restoreStockChrome(on window: NSWindow) {
        window.styleMask.remove(.fullSizeContentView)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.titlebarSeparatorStyle = .automatic
        window.isMovable = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView?.additionalSafeAreaInsets = .init()
    }

    private func assertFlatInvariant(_ window: NSWindow, expectedColor: NSColor) {
        #expect(window.styleMask.contains(.fullSizeContentView))
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.titlebarSeparatorStyle == .none)
        #expect(!window.isMovable)
        #expect(window.backgroundColor.isEqual(expectedColor))
        #expect(window.contentView?.safeAreaInsets.top == 0)
        #expect(window.standardWindowButton(.closeButton) != nil)
        #expect(window.standardWindowButton(.miniaturizeButton) != nil)
        #expect(window.standardWindowButton(.zoomButton) != nil)
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(
                    contentsOf: directory.appending(path: path),
                    encoding: .utf8
                )
            }
            directory = directory.deletingLastPathComponent()
        }
        throw WindowChromeTopologyLifecycleTestError.repositoryRootNotFound
    }

    private enum WindowChromeTopologyLifecycleTestError: Error {
        case repositoryRootNotFound
    }
}
