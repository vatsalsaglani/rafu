import AppKit
import RafuCore
import SwiftUI
import Testing
import WebKit

@testable import RafuApp

@Suite("Canvas editor and native ownership")
@MainActor
struct CanvasIntegrationTests {
    @Test("Canvas fills an empty editor group and follows its size")
    func canvasFillsEmptyEditor() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession(
            CanvasPersistenceStore(directory: folder.appending(path: "state")))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Layout"))
        session.presentCanvasBoard(board)
        try board.add(title: "Finder", content: .nativeApp(bundleID: "com.apple.finder"))
        let cardID = try #require(board.cards.first?.id)
        let host = NSHostingView(rootView: EditorCanvasView(session: session, openFolder: {}))
        host.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        host.layoutSubtreeIfNeeded()
        #expect(board.visibleSize.width > 1100)
        #expect(board.visibleSize.height > 650)
        let app = try #require(session.canvasResources[board.id]?.apps[cardID])
        #expect(!app.isDocked)
        host.frame.size = CGSize(width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(board.visibleSize.width > 800 && board.visibleSize.width < 950)
        #expect(board.visibleSize.height > 450 && board.visibleSize.height < 600)
    }

    @Test("Switching Canvas tabs transfers presentation ownership to the new board")
    func switchingBoardsInstallsPresentation() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession(CanvasPersistenceStore(directory: folder))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let first = try #require(await session.canvas.create(title: "First"))
        session.presentCanvasBoard(first)
        let host = NSHostingView(rootView: EditorCanvasView(session: session, openFolder: {}))
        host.frame = CGRect(x: 0, y: 0, width: 900, height: 600)
        host.layoutSubtreeIfNeeded()
        #expect(session.canvasResources[first.id]?.isPresented == true)
        let second = try #require(await session.canvas.create(title: "Second"))
        session.presentCanvasBoard(second)
        host.layoutSubtreeIfNeeded()
        #expect(session.canvasResources[second.id]?.isPresented == true)
        session.presentCanvasBoard(first)
        host.layoutSubtreeIfNeeded()
        #expect(session.canvasResources[first.id]?.isPresented == true)
    }

    @Test("A native mount requests focus only after attachment and clears it on detach")
    func nativeMountFocusAttachment() {
        let mount = NativeContentMount()
        let note = CanvasNoteBuffer(snapshot: "Note")
        mount.mount(note.scrollView)
        var attachments = 0
        mount.onWindowAttached = { [weak mount, weak note] in
            attachments += 1
            if let text = note?.textView { mount?.window?.makeFirstResponder(text) }
        }
        #expect(attachments == 0)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = mount
        #expect(attachments == 1)
        #expect(window.firstResponder === note.textView)
        mount.detach()
        #expect(mount.onWindowAttached == nil)
        window.contentView = nil
    }

    @Test("Canvas layout restoration retains only records that were loaded")
    func typedRestoration() throws {
        let id = CanvasID()
        let resource = EditorTabResource.canvas(id)
        let data = try JSONEncoder().encode(resource)
        let decoded = try JSONDecoder().decode(EditorTabResource.self, from: data)
        #expect(decoded == resource)
        #expect(decoded.restorationClassification(terminalGroups: nil) == .notRestorable)
        #expect(
            decoded.restorationClassification(terminalGroups: nil, canvasIDs: [id])
                == .canvasRecord(id))
        let old = RestorableWorkspace(
            bookmark: Data(), rootPath: "/test", openRelativePaths: [],
            selectedRelativePath: nil, navigatorMode: .files, editorLayout: nil)
        let restored = try JSONDecoder().decode(
            RestorableWorkspace.self, from: JSONEncoder().encode(old))
        #expect(restored.canvasIDs.isEmpty)
    }

    @Test("A stopped terminal card saves safe metadata and restores with no controller or process")
    func inertTerminalAndRouting() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = CanvasPersistenceStore(directory: folder.appending(path: "state"))
        let session = makeSession(disk)
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Task"))
        session.presentCanvasBoard(board)
        session.addCanvasStoppedTerminal(board.id)
        #expect(session.terminal.sessions.isEmpty)
        let card = try #require(board.cards.first)
        guard case .terminal(let groupID) = card.content else {
            Issue.record("Expected terminal card")
            return
        }
        #expect(session.terminal.terminalGroup(groupID)?.savedLayoutID == nil)
        #expect(session.terminal.terminalGroup(groupID)?.panes.count == 1)
        #expect(await session.canvas.save(board.id))
        #expect(try board.snapshot().terminalGroups?.openGroups.count == 1)
        board.focus(card.id)
        #expect(session.selectedTerminalGroupID == nil)
        board.contentIsActive = true
        session.canvasTerminalOwners[groupID] = board.id
        #expect(session.selectedTerminalGroupID == groupID)
        #expect(!session.terminalGroupPresentationAvailability(.splitRight).isEnabled)
        #expect(!session.terminalGroupPresentationAvailability(.splitDown).isEnabled)
        board.leaveContent()
        #expect(session.canvasTerminalOwners[groupID] == board.id)
        #expect(session.selectedTerminalGroupID == nil)
        #expect(session.terminal.sessions.isEmpty)

        let other = makeSession(disk)
        other.descriptor = session.descriptor
        #expect(await other.canvas.configure(root: folder))
        let reopened = try #require(await other.canvas.open(board.id))
        other.restoreCanvasTerminalReferences(reopened)
        other.presentCanvasBoard(reopened)
        #expect(other.terminal.sessions.isEmpty)
        let group = try #require(other.terminal.terminalGroup(groupID))
        #expect(group.panes.allSatisfy { $0.status == .stopped && $0.sessionID == nil })
        #expect(other.canvasResources[board.id]?.webs.isEmpty == true)
        #expect(other.canvasResources[board.id]?.apps.isEmpty == true)
        reopened.focus(card.id)
        reopened.contentIsActive = true
        other.canvasTerminalOwners[groupID] = reopened.id
        other.startTerminalPane(group.focusedPaneID)
        #expect(other.selectedCanvasID == reopened.id)
        #expect(other.editorLayout.tab(matching: .terminalGroup(groupID: groupID)) == nil)
        let lazyController = try #require(other.terminal.sessions.first)
        #expect(
            !(await ProcessResourceRegistry.shared.sample()).contains { $0.id == lazyController.id }
        )
        other.teardownTerminalGroups()
    }

    @Test(
        "Start Terminal Here replaces an orphaned card's content in place, starting nothing")
    func startTerminalHereReplacesOrphanedCard() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession(
            CanvasPersistenceStore(directory: folder.appending(path: "state")))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Task"))
        session.presentCanvasBoard(board)

        // A card referencing a Terminal Group that no longer exists — e.g. a
        // saved board reopened with ADR 0025 inert restore.
        let missingGroupID = TerminalGroupID()
        try board.add(
            title: "Orphan", content: .terminal(groupID: missingGroupID),
            center: CGPoint(x: 10, y: 10))
        let orphan = try #require(board.cards.first)
        #expect(session.terminal.terminalGroup(missingGroupID) == nil)

        session.startTerminalHere(orphan.id, on: board.id)

        #expect(board.cards.count == 1)
        let replaced = try #require(board.cards.first)
        #expect(replaced.id == orphan.id)
        #expect(replaced.rect == orphan.rect)
        guard case .terminal(let newGroupID) = replaced.content else {
            Issue.record("Expected a replaced terminal card")
            return
        }
        #expect(newGroupID != missingGroupID)
        let group = try #require(session.terminal.terminalGroup(newGroupID))
        #expect(group.panes.count == 1)
        #expect(group.panes.first?.status == .stopped)
        #expect(session.terminal.sessions.isEmpty)
    }

    @Test("Late teardown of an old native mount cannot detach a transferred terminal")
    func nativeMountTransfer() {
        let old = NativeContentMount(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let new = NativeContentMount(frame: old.frame)
        let terminal = RafuTerminalView(frame: old.bounds)
        let parser = terminal.getTerminal()
        old.mount(terminal)
        new.mount(terminal)
        old.detach()
        #expect(terminal.superview === new)
        #expect(terminal.getTerminal() === parser)
        new.detach()
        #expect(terminal.superview == nil)
    }

    @Test("Note input rejects oversized paste and snapshots current native text")
    func nativeNoteBounds() throws {
        let note = CanvasNoteBuffer(snapshot: "hello")
        #expect(
            !note.textView(
                note.textView, shouldChangeTextIn: NSRange(location: 0, length: 0),
                replacementString: String(repeating: "é", count: CanvasLimits.noteBytes)))
        #expect(
            note.textView(
                note.textView, shouldChangeTextIn: NSRange(location: 0, length: 5),
                replacementString: "updated"))
        note.textView.string = "updated"
        #expect(try note.snapshot() == "updated")
    }

    @Test("The close guard preserves original callbacks and optional-method availability")
    func windowDelegateForwarding() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = OriginalDelegate()
        window.delegate = original
        let session = makeSession(
            CanvasPersistenceStore(
                directory: .temporaryDirectory.appending(path: UUID().uuidString)))
        let proxy = CanvasWindowCloseGuard.CloseDelegate(session: session)
        proxy.attach(window)
        #expect(!proxy.windowShouldClose(window))
        #expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowWillResize(_:to:))))
        proxy.windowDidResize(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(original.resizeCount == 1)
        proxy.detach()
        #expect(window.delegate === original)
    }

    @Test("A save conflict prevents window close and app quit without discarding native notes")
    func failedSaveBlocksCloseAndQuit() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = CanvasPersistenceStore(directory: folder)
        let session = makeSession(disk)
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Original"))
        session.installCanvasResources(for: board)
        let key = TerminalGroupWorkspaceKey(standardizedRoot: folder)
        var winner = try #require(try await disk.load(board.id, workspace: key))
        winner.title = "Another window"
        _ = try await disk.save(winner, expectedRevision: winner.revision, workspace: key)
        try board.add(title: "Unsaved", content: .note(snapshot: "keep this text"))

        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let original = OriginalDelegate()
        window.delegate = original
        let proxy = CanvasWindowCloseGuard.CloseDelegate(session: session)
        proxy.attach(window)
        #expect(!proxy.windowShouldClose(window))
        await proxy.waitForPendingSave()
        #expect(board.isDirty && board.errorMessage != nil)
        #expect(original.closeCount == 0)
        var denied = false
        var approved = false
        let termination = WorkspaceTerminationPersistence(
            closeSaveTracker: WorkspaceCloseSaveTracker())
        await termination.request(
            sessions: [session], onSaveFailure: { denied = true },
            reply: { approved = true }
        ).value
        #expect(denied && !approved)
        #expect(board.cards.first?.content == .note(snapshot: "keep this text"))
        #expect(try await disk.load(board.id, workspace: key)?.title == "Another window")
        proxy.detach()
    }

    @Test("WebKit policy callbacks are installed with the current SDK signatures")
    func webPolicySelectors() throws {
        let controller = CanvasWebPreviewController(
            destination: try CanvasWebDestination("http://localhost:3000"))
        #expect(controller.webView == nil)
        for selector in [
            "webView:decidePolicyForNavigationAction:decisionHandler:",
            "webView:decidePolicyForNavigationResponse:decisionHandler:",
            "webView:didReceiveAuthenticationChallenge:completionHandler:",
            "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        ] {
            #expect(controller.responds(to: NSSelectorFromString(selector)))
        }
        controller.stop()
        #expect(controller.webView == nil)
    }

    @Test("Legacy layouts migrate and unknown optional layout data cannot discard the workspace")
    func layoutMigrationAndIsolation() throws {
        let layout = EditorLayoutState()
        #expect(
            try EditorLayoutRestoration(schemaVersion: 1, layout: layout).restoredLayout() == layout
        )
        #expect(EditorLayoutRestoration(layout: layout).schemaVersion == 2)
        let workspace = RestorableWorkspace(
            bookmark: Data(), rootPath: "/test", openRelativePaths: ["README.md"],
            selectedRelativePath: "README.md", navigatorMode: .files, editorLayout: nil)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace)) as? [String: Any])
        object["editorLayout"] = ["schemaVersion": 99, "layout": ["unknownResource": true]]
        object["canvasIDs"] = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode((0...CanvasLimits.boards).map { _ in CanvasID() }))
        let decoded = try JSONDecoder().decode(
            RestorableWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.rootPath == "/test")
        #expect(decoded.openRelativePaths == ["README.md"])
        #expect(decoded.editorLayout == nil && decoded.canvasIDs.isEmpty)
    }

    @Test("Window availability never docks, launches, or moves a native app by itself")
    func visibilityIsInert() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession(CanvasPersistenceStore(directory: folder))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Test"))
        try board.add(title: "Calculator", content: .nativeApp(bundleID: "com.apple.calculator"))
        session.installCanvasResources(for: board)
        let resources = try #require(session.canvasResources[board.id])
        resources.present(owner: UUID())
        let app = try #require(resources.nativeApp(for: board.cards[0]))
        #expect(resources.permitsLiveContent)
        resources.pause()
        #expect(!resources.permitsLiveContent)
        resources.windowBecameAvailable()
        #expect(resources.permitsLiveContent)
        #expect(!app.isDocked)
        #expect(CanvasAppDocking.shared.state(for: board.cards[0].id) == .notDocked)
        #expect(await CanvasAppDocking.shared.inspect(cardID: board.cards[0].id) == nil)
        #expect(await session.canvas.flushAll())
    }

    @Test("Closing a background Canvas keeps the selected Settings tab")
    func backgroundClosePreservesAuxiliarySelection() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = makeSession(CanvasPersistenceStore(directory: folder))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let first = try #require(await session.canvas.create(title: "One"))
        let second = try #require(await session.canvas.create(title: "Two"))
        session.presentCanvasBoard(first)
        session.presentCanvasBoard(second)
        session.showSettings()
        #expect(session.selectedAuxiliaryTab == .settings)
        await session.closeCanvas(first.id).value
        #expect(session.selectedAuxiliaryTab == .settings)
        #expect(session.canvas.boards[first.id] == nil)
        #expect(session.canvas.boards[second.id] === second)
    }

    @Test("Parking Canvas groups during teardown cannot cancel the captured workspace save")
    func teardownKeepsCloseSave() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = TestDefaultsSuite.name("dev.rafu.canvas-close-test")
        defer {
            try? FileManager.default.removeItem(at: folder)
            TestDefaultsSuite.remove(suite)
        }
        let restoration = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        let tracker = WorkspaceCloseSaveTracker()
        let disk = CanvasPersistenceStore(directory: folder)
        let session = WorkspaceSession(
            restorationStore: restoration, closeSaveTracker: tracker,
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: folder)))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Task"))
        session.presentCanvasBoard(board)
        session.addCanvasStoppedTerminal(board.id)
        #expect(await session.canvas.flushAll())
        guard case .terminal(let id) = board.cards.first?.content else {
            Issue.record("Expected terminal card")
            return
        }
        session.canvasTerminalOwners[id] = board.id
        session.teardownTerminalGroups()
        await tracker.drain()
        let saved = try #require(try await restoration.load())
        #expect(saved.canvasIDs == [board.id])
        #expect(saved.editorLayout?.layout.tab(matching: .canvas(board.id)) != nil)
        #expect(session.terminal.sessions.isEmpty)
        #expect(await session.canvas.flushAll())
        let preserved = try #require(
            try await disk.load(
                board.id, workspace: TerminalGroupWorkspaceKey(standardizedRoot: folder)))
        #expect(preserved.terminalGroups?.openGroups.count == 1)
    }

    @Test("A note edited during an awaited quit metadata save is flushed before the reply")
    func editsDuringQuitAreSaved() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let suite = TestDefaultsSuite.name("dev.rafu.canvas-quit-edit")
        defer {
            try? FileManager.default.removeItem(at: folder)
            TestDefaultsSuite.remove(suite)
        }
        let gate = CanvasBookmarkGate()
        let restoration = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in await gate.makeBookmark() })
        let disk = CanvasPersistenceStore(directory: folder)
        let tracker = WorkspaceCloseSaveTracker()
        let session = WorkspaceSession(
            restorationStore: restoration, closeSaveTracker: tracker,
            canvasStore: WorkspaceCanvasStore(persistence: disk))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: folder.path)))
        #expect(await session.canvas.configure(root: folder))
        let board = try #require(await session.canvas.create(title: "Task"))
        session.installCanvasResources(for: board)
        // Control the producer without a debounce timer, so the test does not
        // depend on the scheduler beating an automatic save.
        board.requestSave = nil
        try board.add(title: "Note", content: .note(snapshot: "before"))
        #expect(await session.canvas.flushAll())
        let quit = WorkspaceTerminationPersistence(closeSaveTracker: tracker)
        var replied = false
        let task = quit.request(sessions: [session]) { replied = true }
        await gate.waitUntilStarted()
        try board.edit { $0.cards[0].content = .note(snapshot: "during metadata save") }
        await gate.release()
        await task.value
        let saved = try #require(
            try await disk.load(
                board.id, workspace: TerminalGroupWorkspaceKey(standardizedRoot: folder)))
        #expect(replied && !board.isDirty)
        #expect(saved.cards[0].content == .note(snapshot: "during metadata save"))
        _ = await session.canvas.flushAll()
    }

    @Test("Removing a focused card returns to the board and undo remains inert")
    func removingFocusedCard() throws {
        let board = CanvasBoardState(document: CanvasDocument(title: "Task"))
        try board.add(title: "Note", content: .note(snapshot: "keep"))
        let id = try #require(board.cards.first?.id)
        board.focus(id)
        try board.removeSelection()
        #expect(board.focusedCardID == nil && board.cards.isEmpty)
        board.performUndo()
        #expect(board.cards.first?.id == id && !board.contentIsActive)
    }

    private func makeSession(_ disk: CanvasPersistenceStore) -> WorkspaceSession {
        WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(persistence: disk))
    }
    private final class OriginalDelegate: NSObject, NSWindowDelegate {
        var resizeCount = 0
        var closeCount = 0
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            closeCount += 1
            return false
        }
        func windowDidResize(_ notification: Notification) { resizeCount += 1 }
    }
}

private actor CanvasBookmarkGate {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resume: CheckedContinuation<Void, Never>?
    func makeBookmark() async -> Data {
        started = true
        for waiter in startWaiters { waiter.resume() }
        startWaiters = []
        await withCheckedContinuation { resume = $0 }
        return Data([1])
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func release() {
        resume?.resume()
        resume = nil
    }
}
