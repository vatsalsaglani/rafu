import AppKit
import Testing

@testable import RafuApp

@Suite("Editor lifetime repair", .serialized)
@MainActor
struct EditorLifetimeRepairTests {
    @Test("Repeated host moves keep dirty TextKit, undo, selections, and actions")
    func repeatedMovesKeepEditorResources() async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let resources = try #require(document.editorResources)
        let textView = try #require(coordinator.textView)
        let storage = try #require(textView.textStorage)
        let undo = try #require(textView.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        textView.insertText("alpha\nbeta", replacementRange: NSRange(location: 0, length: 0))
        undo.endUndoGrouping()
        textView.applyCaretRanges(
            [
                NSRange(location: 1, length: 0), NSRange(location: 8, length: 0),
            ], primaryIndex: 1)
        let selections = textView.currentCaretRanges
        let primarySelection = textView.primaryCaretRange
        var host = editor.makeHost(coordinator: coordinator)

        for index in 0..<12 {
            let oldHost = host
            // Exercise both teardown orders without timing or fixed sleeps.
            if index.isMultiple(of: 2) {
                CodeEditorView.dismantleNSView(oldHost, coordinator: coordinator)
            }
            let nextCoordinator = editor.makeCoordinator()
            host = editor.makeHost(coordinator: nextCoordinator)
            CodeEditorView.dismantleNSView(oldHost, coordinator: coordinator)
            #expect(nextCoordinator === coordinator)
            #expect(document.editorResources === resources)
            #expect(resources.activeHost === host)
            #expect(textView.textStorage === storage)
            #expect(textView.undoManager === undo)
            #expect(textView.string == "alpha\nbeta")
            #expect(textView.currentCaretRanges == selections)
            #expect(textView.primaryCaretRange == primarySelection)
            #expect(document.textSnapshotProvider?() == "alpha\nbeta")
            #expect(document.saveAction != nil)
            #expect(document.toggleCommentAction != nil)
            #expect(document.pendingDirtyText == nil)
            #expect(document.isDirty)
        }
        #expect(undo.canUndo)
        undo.undo()
        #expect(textView.string.isEmpty)
        #expect(undo.canRedo)
        undo.redo()
        #expect(textView.string == "alpha\nbeta")
        CodeEditorView.dismantleNSView(host, coordinator: coordinator)
        document.editorResources?.release()
    }

    @Test("Save after a move uses the live editor and survives old teardown")
    func saveAfterMoveUsesLiveBuffer() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("disk".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let textView = try #require(coordinator.textView)
        let oldHost = editor.makeHost(coordinator: coordinator)
        textView.insertText("edited", replacementRange: NSRange(location: 0, length: 4))
        let newHost = editor.makeHost(coordinator: editor.makeCoordinator())
        CodeEditorView.dismantleNSView(oldHost, coordinator: coordinator)
        let save = try #require(document.saveAction)
        save()
        let saveTask = try #require(coordinator.saveTask)
        await saveTask.value
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited")
        #expect(!document.isDirty)
        #expect(document.textSnapshotProvider?() == "edited")
        #expect(document.editorResources?.activeHost === newHost)
        document.editorResources?.release()
    }

    @Test("An edit after Save starts keeps the newer live buffer dirty")
    func editDuringSaveStaysDirty() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data("disk".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = EditorDocument(url: url)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let textView = try #require(coordinator.textView)
        textView.insertText("save", replacementRange: NSRange(location: 0, length: 4))
        document.saveAction?()
        let saveTask = try #require(coordinator.saveTask)
        // No suspension: this edit must occur before the save task completes.
        textView.insertText(" newer", replacementRange: NSRange(location: 4, length: 0))
        await saveTask.value
        #expect(try String(contentsOf: url, encoding: .utf8) == "save")
        #expect(document.textSnapshotProvider?() == "save newer")
        #expect(document.isDirty)
        document.editorResources?.release()
    }

    @Test("Clean hibernation releases ownership; stale cleanup cannot clear new actions")
    func hibernationAndStaleCleanup() async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let oldCoordinator = editor.makeCoordinator()
        await oldCoordinator.loadTask?.value
        let oldHost = editor.makeHost(coordinator: oldCoordinator)
        let oldTextView = try #require(oldCoordinator.textView)
        oldTextView.string = "clean"
        oldTextView.setSelectedRange(NSRange(location: 3, length: 0))
        document.markHibernated()
        #expect(document.editorResources == nil)
        #expect(document.restoredSelection == NSRange(location: 3, length: 0))
        #expect(document.saveAction == nil)
        #expect(document.textSnapshotProvider == nil)
        #expect(oldTextView.delegate == nil)
        document.markLoaded()
        let newCoordinator = editor.makeCoordinator()
        await newCoordinator.loadTask?.value
        let newHost = editor.makeHost(coordinator: newCoordinator)
        CodeEditorView.dismantleNSView(oldHost, coordinator: oldCoordinator)
        oldCoordinator.releaseResources()
        #expect(newCoordinator !== oldCoordinator)
        #expect(document.saveAction != nil)
        #expect(document.textSnapshotProvider?() == "")
        #expect(document.editorResources?.activeHost === newHost)
        document.editorResources?.release()
    }

    @Test("Dirty hibernation does not release the editor")
    func dirtyEditorCannotHibernate() async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let resources = try #require(document.editorResources)
        coordinator.textView?.insertText(
            "unsaved", replacementRange: NSRange(location: 0, length: 0))
        document.markHibernated()
        #expect(document.loadState == .loaded)
        #expect(document.editorResources === resources)
        #expect(document.textSnapshotProvider?() == "unsaved")
        resources.release()
    }

    @Test("A document and its unmounted editor have no ownership cycle", .timeLimit(.minutes(1)))
    func editorDoesNotRetainDocument() async throws {
        let release = AsyncStream<Void>.makeStream()
        var document: EditorDocument?
        weak var weakDocument: EditorDocument?
        weak var weakResources: CodeEditorView.EditorResources?
        weak var weakTextView: RafuTextView?
        weak var weakScrollView: NSScrollView?
        weak var weakCoordinator: CodeEditorView.Coordinator?
        weak var weakRuler: NSRulerView?
        // AppKit can return autoreleased objects during editor construction.
        // Drain construction and teardown separately; an autorelease pool is
        // thread-local and must never span an async suspension.
        let loadTask = try autoreleasepool {
            let ownedDocument = EditorDocument(untitledNumber: 1)
            document = ownedDocument
            weakDocument = ownedDocument
            let editor = CodeEditorView(document: ownedDocument, theme: RafuThemeCatalog.indigo)
            let coordinator = editor.makeCoordinator()
            weakResources = ownedDocument.editorResources
            weakTextView = coordinator.textView
            let probe = EditorDeallocationProbe(continuation: release.continuation)
            objc_setAssociatedObject(
                try #require(coordinator.textView), Unmanaged.passUnretained(probe).toOpaque(),
                probe, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            weakScrollView = ownedDocument.editorResources?.scrollView
            weakCoordinator = coordinator
            weakRuler = coordinator.gutterRuler
            return try #require(coordinator.loadTask)
        }
        await loadTask.value
        #expect(document != nil)
        #expect(weakResources != nil)
        autoreleasepool {
            document = nil
            #expect(weakDocument == nil)
            #expect(weakResources == nil)
        }
        // AppKit can retain a text view for pending native work. Await its
        // deallocation event instead of assuming one main-queue turn is enough.
        var events = release.stream.makeAsyncIterator()
        _ = await events.next()
        #expect(weakScrollView == nil)
        #expect(weakCoordinator == nil)
        #expect(weakRuler == nil)
        #expect(weakTextView == nil)
    }

    @Test("Hidden mounted editor stops caret blinking and resumes when shown")
    func hiddenCaretTimerStops() async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let host = editor.makeHost(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let textView = try #require(coordinator.textView)
        let overlay = MultiCaretOverlayView(frame: textView.bounds)
        textView.addSubview(overlay)
        overlay.update(
            caretRects: [NSRect(x: 10, y: 10, width: 1, height: 14)],
            color: .textColor, reduceMotion: false)
        #expect(overlay.isBlinking)
        host.setEditorVisible(false)
        #expect(!overlay.isBlinking)
        host.setEditorVisible(true)
        #expect(overlay.isBlinking)
        CodeEditorView.dismantleNSView(host, coordinator: coordinator)
        #expect(!overlay.isBlinking)
        window.contentView = nil
        document.editorResources?.release()
    }

    @Test("Moving a focused editor restores its responder in the same window")
    func moveRestoresFocus() async throws {
        let document = EditorDocument(untitledNumber: 1)
        let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
        let coordinator = editor.makeCoordinator()
        await coordinator.loadTask?.value
        let textView = try #require(coordinator.textView)
        let oldHost = editor.makeHost(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 250),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = oldHost
        #expect(window.makeFirstResponder(textView))
        CodeEditorView.dismantleNSView(oldHost, coordinator: coordinator)
        let newHost = editor.makeHost(coordinator: coordinator)
        window.contentView = newHost
        #expect(window.firstResponder === textView)
        #expect(document.editorResources?.activeHost === newHost)
        window.contentView = nil
        document.editorResources?.release()
    }

    @Test("Cross-group split preserves one tab and collapses the empty source")
    func crossGroupSplitIsOneMutation() throws {
        let moving = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/moving.swift")))
        let target = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/target.swift")))
        let sourceGroup = EditorGroupState(tabs: [moving])
        let targetGroup = EditorGroupState(tabs: [target])
        var layout = EditorLayoutState(
            root: .split(
                id: EditorSplitID(), axis: .horizontal,
                fraction: 0.5, first: .group(sourceGroup), second: .group(targetGroup)))
        let splitGroupID = layout.split(group: targetGroup.id, at: .bottom, moving: moving.id)
        let newGroup = try #require(splitGroupID)
        #expect(layout.group(containing: moving.id)?.id == newGroup)
        #expect(layout.group(id: targetGroup.id)?.tabs == [target])
        #expect(layout.group(id: sourceGroup.id) == nil)
        #expect(layout.focusedGroupID == newGroup)
        #expect(layout.groupIDs.count == 2)
    }
}

private final class EditorDeallocationProbe: Sendable {
    let continuation: AsyncStream<Void>.Continuation

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    deinit {
        continuation.yield(())
        continuation.finish()
    }
}
