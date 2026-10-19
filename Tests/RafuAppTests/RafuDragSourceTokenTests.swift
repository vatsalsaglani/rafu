import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Drag source ghost token lifecycle")
struct RafuDragSourceLifecycleTests {
    @Test("begin sets the token")
    func beginSets() {
        let token = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.begin(token) == token)
    }

    @Test("end clears only when the token is still the in-flight one")
    func endClears() {
        let token = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.end(token, clearing: token) == nil)
    }

    @Test("end is a no-op for a drag already superseded by a newer token")
    func endIsNoOpWhenSuperseded() {
        let old = RafuDragSourceToken()
        let newer = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.end(old, clearing: newer) == newer)
    }

    @Test("cancel clears the same way as end")
    func cancelClears() {
        let token = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.cancel(token, clearing: token) == nil)
    }

    @Test("cancel is a no-op for a drag already superseded by a newer token")
    func cancelIsNoOpWhenSuperseded() {
        let old = RafuDragSourceToken()
        let newer = RafuDragSourceToken()
        #expect(RafuDragSourceLifecycle.cancel(old, clearing: newer) == newer)
    }

    @Test("A second window's in-flight token is independent of the first")
    @MainActor
    func secondWindowIsIndependent() {
        let first = WorkspaceSession()
        let second = WorkspaceSession()
        let firstToken = RafuDragSourceToken()
        let secondToken = RafuDragSourceToken()

        first.dragInFlight = RafuDragSourceLifecycle.begin(firstToken)
        second.dragInFlight = RafuDragSourceLifecycle.begin(secondToken)
        #expect(first.dragInFlight == firstToken)
        #expect(second.dragInFlight == secondToken)

        first.dragInFlight = RafuDragSourceLifecycle.end(firstToken, clearing: first.dragInFlight)
        #expect(first.dragInFlight == nil)
        #expect(second.dragInFlight == secondToken)
    }

    @Test("Mouse-up, a later mouse-move or mouse-down end a drag; Escape cancels it")
    func endSignals() {
        #expect(RafuDragSourceLifecycle.signal(for: .leftMouseUp, keyCode: 0) == .ended)
        #expect(RafuDragSourceLifecycle.signal(for: .mouseMoved, keyCode: 0) == .ended)
        #expect(RafuDragSourceLifecycle.signal(for: .leftMouseDown, keyCode: 0) == .ended)
        #expect(RafuDragSourceLifecycle.signal(for: .keyDown, keyCode: 53) == .cancelled)
    }

    @Test("Drag motion and other keys do not end a drag")
    func nonEndSignals() {
        #expect(RafuDragSourceLifecycle.signal(for: .leftMouseDragged, keyCode: 0) == nil)
        #expect(RafuDragSourceLifecycle.signal(for: .keyDown, keyCode: 36) == nil)
        #expect(RafuDragSourceLifecycle.signal(for: .rightMouseUp, keyCode: 0) == nil)
        #expect(RafuDragSourceLifecycle.signal(for: .scrollWheel, keyCode: 0) == nil)
    }

    @Test("Drag start never writes observed state inside the onDrag closure")
    @MainActor
    func dragStartDefersObservedWrite() {
        let session = WorkspaceSession()
        let token = RafuDragSourceToken()
        var scheduled: [@MainActor () -> Void] = []

        let returned = session.beginDragSourceTracking(token) { scheduled.append($0) }

        #expect(returned == token)
        #expect(session.dragInFlight == nil)
        #expect(scheduled.count == 1)
        for work in scheduled { work() }
        #expect(session.dragInFlight == token)
    }

    @Test("Drag-start closures cache the drop payload synchronously")
    @MainActor
    func dragStartCachesPayloadSynchronously() {
        let session = WorkspaceSession()
        _ = session.beginEditorDrag(.file(path: "/tmp/Changelog.md"))
        #expect(session.activeEditorDrag == .file(path: "/tmp/Changelog.md"))
    }
}

@Suite("Drag sources own their press")
struct RafuDragSourcePressOwnershipTests {
    @Test("Files-tree file rows and Agent History rows are not Buttons")
    func rowsAreNotButtons() throws {
        let sidebar = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        #expect(!sidebar.contains("Button(action: activateRow)"))
        #expect(sidebar.contains(".onTapGesture(perform: activateRow)"))
        #expect(sidebar.contains(".accessibilityAddTraits(.isButton)"))

        let history = try Self.source("Sources/RafuApp/AgentHistory/AgentHistoryPanelView.swift")
        #expect(!history.contains("Button(action: open)"))
        #expect(history.contains(".onTapGesture(perform: open)"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SourceLookupError.repositoryRootNotFound
    }

    private enum SourceLookupError: Error {
        case repositoryRootNotFound
    }
}
