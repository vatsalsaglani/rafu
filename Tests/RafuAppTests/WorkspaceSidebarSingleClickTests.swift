import Foundation
import SwiftUI
import Testing

@testable import RafuApp

@MainActor
@Suite("Sidebar file activation")
struct WorkspaceSidebarSingleClickTests {
    @Test("One file action selects and opens the file")
    func oneActionOpensFile() throws {
        let fixture = SidebarSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let node = fileNode()

        item(session: session, node: node).activateRow()

        #expect(session.selectedTreePath == node.url.path)
        #expect(session.openDocuments.count == 1)
        let document = try #require(session.selectedDocument)
        #expect(document.url == node.url)
    }

    @Test("Activating an open file reuses its dirty document")
    func repeatedActionPreservesDirtyDocument() throws {
        let fixture = SidebarSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let node = fileNode()
        let row = item(session: session, node: node)
        row.activateRow()
        let document = try #require(session.selectedDocument)
        document.isDirty = true
        document.pendingDirtyText = "unsaved text"
        session.newUntitledDocument()

        row.activateRow()

        #expect(session.selectedDocument === document)
        #expect(session.openDocuments.count == 2)
        #expect(document.isDirty)
        #expect(document.pendingDirtyText == "unsaved text")
    }

    @Test("Folder selection preserves the editor and folder expansion")
    func folderSelectionDoesNotOpenFile() throws {
        let fixture = SidebarSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        session.newUntitledDocument()
        let document = try #require(session.selectedDocument)
        let node = WorkspaceFileNode(
            url: URL(filePath: "/tmp/sidebar-folder"), relativePath: "sidebar-folder",
            isDirectory: true)
        session.expandedDirectories = [node.relativePath]

        item(session: session, node: node).activateRow()

        #expect(session.selectedTreePath == node.url.path)
        #expect(session.selectedDocument === document)
        #expect(session.openDocuments.count == 1)
        #expect(session.expandedDirectories == [node.relativePath])
    }

    @Test("File activation belongs to its workspace window")
    func windowSelectionIsIndependent() {
        let firstFixture = SidebarSessionFixture()
        let secondFixture = SidebarSessionFixture()
        defer {
            firstFixture.remove()
            secondFixture.remove()
        }
        let first = firstFixture.session
        let second = secondFixture.session
        let node = fileNode()

        item(session: first, node: node).activateRow()

        #expect(first.selectedTreePath == node.url.path)
        #expect(second.selectedTreePath == nil)
        #expect(second.openDocuments.isEmpty)
    }

    @Test("Command and Shift activation select without opening")
    func modifiedActivationDoesNotOpen() {
        let fixture = SidebarSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let first = fileNode()
        let second = fileNode()

        item(session: session, node: first).activateRow(.toggle)
        item(session: session, node: second).activateRow(.toggle)

        #expect(session.selectedTreePaths == [first.url.path, second.url.path])
        #expect(session.openDocuments.isEmpty)

        item(session: session, node: first).activateRow(.extend)
        #expect(session.openDocuments.isEmpty)
    }

    @Test("A plain activation after a multi-selection opens and collapses it")
    func plainActivationCollapsesSelection() throws {
        let fixture = SidebarSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let first = fileNode()
        let second = fileNode()
        item(session: session, node: first).activateRow(.toggle)
        item(session: session, node: second).activateRow(.toggle)

        item(session: session, node: first).activateRow(.none)

        #expect(session.selectedTreePaths == [first.url.path])
        #expect(try #require(session.selectedDocument).url == first.url)
    }

    @Test("Reveal and editor selection collapse a multi-selection")
    func revealCollapsesSelection() {
        let fixture = SidebarSessionFixture()
        defer { fixture.remove() }
        let session = fixture.session
        let first = fileNode()
        let second = fileNode()
        item(session: session, node: first).activateRow(.toggle)
        item(session: session, node: second).activateRow(.toggle)

        session.revealInSidebar(path: "/tmp/sidebar-folder")

        #expect(session.selectedTreePaths == ["/tmp/sidebar-folder"])
        #expect(session.selectedTreePath == "/tmp/sidebar-folder")
    }

    private func fileNode() -> WorkspaceFileNode {
        WorkspaceFileNode(
            url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".txt"),
            relativePath: "notes.txt", isDirectory: false)
    }

    private func item(session: WorkspaceSession, node: WorkspaceFileNode) -> WorkspaceFileTreeItem {
        WorkspaceFileTreeItem(
            session: session, node: node, renameNode: .constant(nil), renameText: .constant(""))
    }
}

@MainActor
private struct SidebarSessionFixture {
    let session: WorkspaceSession
    private let suite: String

    init() {
        suite = TestDefaultsSuite.name("dev.rafu.sidebar-single-click")
        session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(defaultsSuiteName: suite))
    }

    func remove() {
        session.descriptor = nil
        TestDefaultsSuite.remove(suite)
    }
}
