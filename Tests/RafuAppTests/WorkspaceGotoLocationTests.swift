import Foundation
import RafuCore
import Testing

@testable import RafuApp

@MainActor
@Suite("Workspace CLI goto")
struct WorkspaceGotoLocationTests {
    @Test("Goto computes the caret from a mounted buffer's live text")
    func mountedBufferWinsOverDisk() throws {
        let fixture = try Fixture(diskText: "one\ntwo\n")
        defer { fixture.remove() }
        let session = fixture.session()
        let document = EditorDocument(url: fixture.fileURL)
        document.textSnapshotProvider = { "zero\nlive target\n" }
        session.openDocuments = [document]

        session.openFile(
            atRelativePath: fixture.relativePath,
            selecting: RafuCore.SourceLocation(line: 2, column: 6)
        )

        let controller = SelectionRecorder()
        session.findState(for: document).attach(controller)
        #expect(controller.selectedRange == NSRange(location: 10, length: 0))
        #expect(session.selectedDocument === document)
    }

    @Test("Goto queues a disk-based CRLF selection until an editor mounts")
    func unmountedBufferQueuesDiskSelection() throws {
        let fixture = try Fixture(diskText: "alpha\r\nbeta\n")
        defer { fixture.remove() }
        let session = fixture.session()

        session.openFile(
            atRelativePath: fixture.relativePath,
            selecting: RafuCore.SourceLocation(line: 2, column: 3)
        )

        let document = try #require(session.selectedDocument)
        #expect(document.textSnapshotProvider == nil)
        #expect(document.restoredSelection == NSRange(location: 9, length: 0))
        let controller = SelectionRecorder()
        session.findState(for: document).attach(controller)
        #expect(controller.selectedRange == NSRange(location: 9, length: 0))
    }

    @Test("Goto rematerializes a hibernated tab and retains its pending caret")
    func hibernatedBufferRematerializes() throws {
        let fixture = try Fixture(diskText: "first\nsecond\n")
        defer { fixture.remove() }
        let session = fixture.session()
        let document = EditorDocument(url: fixture.fileURL)
        document.markHibernated()
        session.openDocuments = [document]

        session.openFile(
            atRelativePath: fixture.relativePath,
            selecting: RafuCore.SourceLocation(line: 99, column: 99)
        )

        #expect(document.loadState == .loaded)
        #expect(document.restoredSelection == NSRange(location: 13, length: 0))
        let controller = SelectionRecorder()
        session.findState(for: document).attach(controller)
        #expect(controller.selectedRange == NSRange(location: 13, length: 0))
    }
}

@MainActor
private final class SelectionRecorder: DocumentFindControlling {
    private(set) var selectedRange: NSRange?

    func refresh(using _: DocumentFindState) {}
    func find(_: FindDirection, using _: DocumentFindState) {}
    func replaceCurrent(using _: DocumentFindState) {}
    func replaceAll(using _: DocumentFindState) {}

    func select(_ range: NSRange) {
        selectedRange = range
    }
}

private struct Fixture {
    let rootURL: URL
    let fileURL: URL
    let relativePath = "Sources/main.swift"

    init(diskText: String) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appending(path: "rafu-goto-\(UUID().uuidString)", directoryHint: .isDirectory)
        fileURL = rootURL.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try diskText.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    @MainActor
    func session() -> WorkspaceSession {
        let session = WorkspaceSession()
        session.descriptor = WorkspaceDescriptor(
            displayName: rootURL.lastPathComponent,
            location: .local(LocalWorkspaceReference(path: rootURL.path))
        )
        return session
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
