import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

@MainActor
@Suite("Workspace navigation and restoration repair")
struct WorkspaceNavigationRestorationRepairTests {
    @Test("Unmounted goto resolves a CRLF caret through the async editor file boundary")
    func asyncGoto() async throws {
        let fixture = try RepairFixture(text: "alpha\r\nbeta\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let task = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 3))
        let document = try #require(session.selectedDocument)
        await task?.value
        #expect(document.restoredSelection == NSRange(location: 9, length: 0))
        let recorder = RepairSelectionRecorder()
        session.findState(for: document).attach(recorder)
        #expect(recorder.range == NSRange(location: 9, length: 0))
    }

    @Test("A transient dirty buffer wins without a readable disk file")
    func transientDirtyBufferWins() throws {
        let fixture = try RepairFixture(text: "disk\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let document = EditorDocument(url: fixture.fileURL)
        document.isDirty = true
        document.pendingDirtyText = "first\nunsaved\n"
        // The next mount can install its provider before it seeds storage.
        document.textSnapshotProvider = { "" }
        session.openDocuments = [document]
        try FileManager.default.removeItem(at: fixture.fileURL)
        let task = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 4))
        #expect(task == nil)
        #expect(document.restoredSelection == NSRange(location: 9, length: 0))
        #expect(document.pendingDirtyText == "first\nunsaved\n")
        #expect(document.isDirty)
    }

    @Test("A buffer that becomes dirty before navigation completes wins over disk")
    func dirtyBufferAfterRequestWins() async throws {
        let fixture = try RepairFixture(text: "disk\nshort\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let task = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 3))
        let document = try #require(session.selectedDocument)
        document.isDirty = true
        document.textSnapshotProvider = { "longer first line\nlive\n" }
        await task?.value
        let recorder = RepairSelectionRecorder()
        session.findState(for: document).attach(recorder)
        #expect(recorder.range == NSRange(location: 20, length: 0))
        #expect(document.restoredSelection == nil)
    }

    @Test("A clean live buffer that arrives after a request wins over the disk range")
    func cleanBufferAfterRequestWins() async throws {
        let fixture = try RepairFixture(text: "disk\nshort\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let task = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 3))
        let document = try #require(session.selectedDocument)
        document.textSnapshotProvider = { "longer first line\nlive\n" }
        await task?.value
        let recorder = RepairSelectionRecorder()
        session.findState(for: document).attach(recorder)
        #expect(recorder.range == NSRange(location: 20, length: 0))
        #expect(document.restoredSelection == nil)
        #expect(!document.isDirty)
    }

    @Test("Selecting away and back rejects the old goto")
    func staleSelectionRejected() async throws {
        let fixture = try RepairFixture(text: "first\nsecond\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let task = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 2))
        let document = try #require(session.selectedDocument)
        let other = EditorDocument(url: fixture.rootURL.appending(path: "other.swift"))
        session.openDocuments.append(other)
        session.select(other)
        session.select(document)
        await task?.value
        #expect(document.restoredSelection == nil)
    }

    @Test("A caret move in the same document rejects a late disk selection")
    func caretMoveRejectsLateRequest() async throws {
        let fixture = try RepairFixture(text: "first\nsecond\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let document = EditorDocument(url: fixture.fileURL)
        // An empty clean storage represents an editor still loading.
        document.textSnapshotProvider = { "" }
        var caret = NSRange(location: 0, length: 0)
        document.selectionProvider = { caret }
        session.openDocuments = [document]
        let navigation = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 2))
        caret = NSRange(location: 3, length: 0)
        await navigation?.value
        let recorder = RepairSelectionRecorder()
        session.findState(for: document).attach(recorder)
        #expect(recorder.range == nil)
        #expect(document.restoredSelection == nil)
        #expect(caret == NSRange(location: 3, length: 0))
    }

    @Test("A newer goto to the same document replaces the pending goto")
    func newerRequestWins() async throws {
        let fixture = try RepairFixture(text: "first\nsecond\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let old = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 2, column: 2))
        let latest = session.openFile(
            atRelativePath: "file.swift", selecting: RafuCore.SourceLocation(line: 1, column: 3))
        await old?.value
        await latest?.value
        #expect(session.selectedDocument?.restoredSelection == NSRange(location: 2, length: 0))
    }

    @Test("Navigation rejects invalid UTF-8 through the editor loader")
    func navigationUsesEditorValidation() async throws {
        let fixture = try RepairFixture(text: "first\n")
        defer { fixture.remove() }
        try Data([0xFF, 0xFE, 0xFF]).write(to: fixture.fileURL)
        await #expect(throws: WorkspaceFileError.self) {
            try await WorkspaceLocationLoader.range(
                at: fixture.fileURL, location: RafuCore.SourceLocation(line: 1))
        }
    }

    @Test("Bookmarks are cached only for the same root and authorization")
    func bookmarkAuthorizationCache() async throws {
        let calls = Mutex(0)
        let store = WorkspaceRestorationStore(bookmarkMaker: { _ in
            calls.withLock { count in
                count += 1
                return Data([UInt8(count)])
            }
        })
        let root = URL(fileURLWithPath: "/tmp/rafu-repair")
        let authorization = UUID()
        let first = try await store.makeBookmark(for: root, authorizationID: authorization)
        let second = try await store.makeBookmark(for: root, authorizationID: authorization)
        #expect(first == second)
        #expect(calls.withLock { $0 } == 1)
        let renewed = try await store.makeBookmark(for: root, authorizationID: UUID())
        #expect(renewed != first)
        let other = try await store.makeBookmark(
            for: root.appending(path: "other"), authorizationID: authorization)
        #expect(other != renewed)
        #expect(calls.withLock { $0 } == 3)
    }

    @Test("A valid restored bookmark is reused and stale data is not reused")
    func restoredBookmarkCache() async throws {
        let calls = Mutex(0)
        let store = WorkspaceRestorationStore(bookmarkMaker: { _ in
            calls.withLock { $0 += 1 }
            return Data([2])
        })
        let root = URL(fileURLWithPath: "/tmp/rafu-repair")
        let authorization = UUID()
        await store.cacheBookmark(Data([1]), for: root, authorizationID: authorization)
        let cached = try await store.makeBookmark(for: root, authorizationID: authorization)
        #expect(cached == Data([1]))
        #expect(calls.withLock { $0 } == 0)
        await store.cacheBookmark(nil, for: root, authorizationID: authorization)
        let renewed = try await store.makeBookmark(for: root, authorizationID: authorization)
        #expect(renewed == Data([2]))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test("Close flush saves the final navigator and tab state without waiting for debounce")
    func finalCloseFlush() async throws {
        let fixture = try RepairFixture(text: "first\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        session.openFile(atRelativePath: "file.swift")
        session.navigatorMode = .search
        session.navigatorMode = .sourceControl
        let closeSave = session.flushWorkspaceState()
        await closeSave?.value
        let saved = try #require(try await fixture.store.load())
        #expect(saved.navigatorMode == .sourceControl)
        #expect(saved.openRelativePaths == ["file.swift"])
        #expect(saved.selectedRelativePath == "file.swift")
        #expect(saved.terminalGroupRestoration?.openGroups.isEmpty == true)
        #expect(session.terminal.sessions.isEmpty)
    }

    @Test("Rapid state changes save the latest state after the combined request")
    func combinedStateChanges() async throws {
        let fixture = try RepairFixture(text: "first\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        for _ in 0..<20 {
            session.navigatorMode = .search
            session.navigatorMode = .files
        }
        session.navigatorMode = .sourceControl
        await session.waitForWorkspaceStateSave()
        let saved = try #require(try await fixture.store.load())
        #expect(saved.navigatorMode == .sourceControl)
    }

    @Test("A cancelled save cannot replace the last complete metadata blob")
    func cancelledSaveRejected() async throws {
        let fixture = try RepairFixture(text: "first\n")
        defer { fixture.remove() }
        let original = repairWorkspace(root: fixture.rootURL, mode: .files)
        try await fixture.store.save(original)
        let store = fixture.store
        let replacement = repairWorkspace(root: fixture.rootURL, mode: .search)
        let task = Task { try await store.save(replacement) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        let saved = try #require(try await store.load())
        #expect(saved.navigatorMode == .files)
    }

    @Test("Cross-group edge drop preserves tab identity, split topology, focus, and dirty state")
    func crossGroupEdgeDrop() throws {
        let fixture = try RepairFixture(text: "first\n")
        defer { fixture.remove() }
        let session = fixture.session()
        defer { session.descriptor = nil }
        let document = EditorDocument(url: fixture.fileURL)
        document.isDirty = true
        document.pendingDirtyText = "unsaved"
        session.openDocuments = [document]
        session.select(document)
        let tab = try #require(session.editorLayout.tab(matching: .file(document.url)))
        let sourceGroupID = session.editorLayout.focusedGroupID
        let splitTarget = session.editorLayout.split(
            group: session.editorLayout.focusedGroupID, at: .trailing)
        let target = try #require(splitTarget)
        let other = EditorTabState(resource: .file(fixture.rootURL.appending(path: "other.swift")))
        session.editorLayout.insert(other, in: target)
        session.handleEditorTabDrop(tab.id.rawValue.uuidString, on: target, edge: .bottom)
        // A bottom edge drop leaves the original target above the moved tab.
        // Check that shape and preserved identities, not newly generated IDs
        // from a second independent split operation.
        guard
            case .split(_, let axis, let fraction, let first, let second) = session.editorLayout
                .root,
            case .group(let upperGroup) = first,
            case .group(let movedGroup) = second
        else {
            Issue.record("Expected one split containing the target and moved-tab groups")
            return
        }
        #expect(axis == .vertical)
        #expect(fraction == 0.5)
        #expect(upperGroup.id == target)
        #expect(upperGroup.tabs == [other])
        #expect(upperGroup.selectedTabID == other.id)
        #expect(movedGroup.id != target)
        #expect(movedGroup.id != sourceGroupID)
        #expect(movedGroup.tabs == [tab])
        #expect(movedGroup.selectedTabID == tab.id)
        #expect(session.editorLayout.groupIDs == [target, movedGroup.id])
        #expect(session.editorLayout.group(id: sourceGroupID) == nil)
        #expect(session.editorLayout.focusedGroupID == movedGroup.id)
        #expect(session.selectedDocument === document)
        #expect(document.isDirty)
        #expect(document.pendingDirtyText == "unsaved")
        let beforeInvalid = session.editorLayout
        session.handleEditorTabDrop(tab.id.rawValue.uuidString, on: EditorGroupID(), edge: .top)
        #expect(session.editorLayout == beforeInvalid)
    }
}

@MainActor
private final class RepairSelectionRecorder: DocumentFindControlling {
    var range: NSRange?
    func refresh(using _: DocumentFindState) {}
    func find(_: FindDirection, using _: DocumentFindState) {}
    func replaceCurrent(using _: DocumentFindState) {}
    func replaceAll(using _: DocumentFindState) {}
    func select(_ range: NSRange) { self.range = range }
}

private func repairWorkspace(root: URL, mode: WorkspaceNavigatorMode) -> RestorableWorkspace {
    RestorableWorkspace(
        bookmark: Data([1]), rootPath: root.path, openRelativePaths: [],
        selectedRelativePath: nil, navigatorMode: mode, editorLayout: nil)
}

private struct RepairFixture {
    let rootURL: URL
    let store: WorkspaceRestorationStore
    private let suite: String
    var fileURL: URL { rootURL.appending(path: "file.swift") }

    init(text: String) throws {
        suite = TestDefaultsSuite.name("dev.rafu.navigation-repair")
        rootURL = FileManager.default.temporaryDirectory.appending(path: suite)
        store = WorkspaceRestorationStore(
            defaultsSuiteName: suite, bookmarkMaker: { _ in Data([1]) })
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try text.write(to: rootURL.appending(path: "file.swift"), atomically: true, encoding: .utf8)
    }

    @MainActor
    func session() -> WorkspaceSession {
        let session = WorkspaceSession(restorationStore: store)
        session.descriptor = WorkspaceDescriptor(
            displayName: "Repair fixture",
            location: .local(LocalWorkspaceReference(path: rootURL.path)))
        return session
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
        TestDefaultsSuite.remove(suite)
    }
}
