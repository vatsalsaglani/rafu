import Foundation
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

@Test("EditorDragPayload round-trips through JSON for tab and file cases")
func editorDragPayloadJSONRoundTrip() throws {
    let tabPayload = EditorDragPayload.tab(id: "AAAA-BBBB")
    let decodedTab = try EditorDragPayload(data: tabPayload.encodedData())
    #expect(decodedTab == tabPayload)

    let filePayload = EditorDragPayload.file(path: "/tmp/example.swift")
    let decodedFile = try EditorDragPayload(data: filePayload.encodedData())
    #expect(decodedFile == filePayload)
}

@Test("EditorDragPayload register→loadDataRepresentation round trip carries the payload")
func editorDragPayloadItemProviderRoundTrip() async throws {
    let payload = EditorDragPayload.file(path: "/tmp/dropped-file.swift")
    let provider = payload.makeItemProvider()

    #expect(provider.hasItemConformingToTypeIdentifier(UTType.rafuEditorDrag.identifier))

    let data = try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Data, Error>) in
        _ = provider.loadDataRepresentation(for: .rafuEditorDrag) { data, error in
            if let data {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown))
            }
        }
    }

    let decoded = try EditorDragPayload(data: data)
    #expect(decoded == payload)
}

@Test("Editor drop geometry resolves the nearest edge band on all four sides")
func editorDropGeometryResolvesEdges() {
    let size = CGSize(width: 400, height: 300)
    #expect(EditorDropGeometry.target(at: CGPoint(x: 5, y: 150), in: size) == .leading)
    #expect(EditorDropGeometry.target(at: CGPoint(x: 395, y: 150), in: size) == .trailing)
    #expect(EditorDropGeometry.target(at: CGPoint(x: 200, y: 5), in: size) == .top)
    #expect(EditorDropGeometry.target(at: CGPoint(x: 200, y: 295), in: size) == .bottom)
}

@Test("Editor drop geometry reports the center dead zone as nil")
func editorDropGeometryResolvesCenter() {
    let size = CGSize(width: 400, height: 300)
    #expect(EditorDropGeometry.target(at: CGPoint(x: 200, y: 150), in: size) == nil)
}

@Test("Editor drop geometry degrades to nil instead of crashing on degenerate sizes")
func editorDropGeometryHandlesDegenerateSizes() {
    #expect(EditorDropGeometry.target(at: .zero, in: .zero) == nil)
    #expect(
        EditorDropGeometry.target(
            at: CGPoint(x: 0, y: 100), in: CGSize(width: 0, height: 200)) == nil)
}

@Test("Splitting a group and inserting a dropped tab focuses the new group and restores")
func editorLayoutSplitThenInsertFocusesNewGroup() throws {
    let existingTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/existing.swift")))
    let initialGroup = EditorGroupState(tabs: [existingTab])
    var layout = EditorLayoutState(root: .group(initialGroup), focusedGroupID: initialGroup.id)

    let splitResult = layout.split(group: initialGroup.id, at: .trailing, moving: nil)
    let newGroupID = try #require(splitResult)
    let droppedTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/dropped.swift")))
    layout.insert(droppedTab, in: newGroupID)
    layout.select(droppedTab.id, in: newGroupID)

    #expect(layout.focusedGroupID == newGroupID)
    #expect(layout.group(id: newGroupID)?.tabs.map(\.id) == [droppedTab.id])
    #expect(layout.group(id: newGroupID)?.selectedTabID == droppedTab.id)
    #expect(layout.group(id: initialGroup.id)?.tabs.map(\.id) == [existingTab.id])

    let encoded = try JSONEncoder().encode(EditorLayoutRestoration(layout: layout))
    let decoded = try JSONDecoder().decode(EditorLayoutRestoration.self, from: encoded)
    let restored = try decoded.restoredLayout()

    #expect(restored == layout)
}

@MainActor
@Test("handleEditorFileDrop opens a new file in place, reuses its tab, and can split it")
func handleEditorFileDropOpensReusesAndSplits() throws {
    let session = WorkspaceSession()
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let fileURL = tempDir.appending(path: "note.txt")
    try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

    let originalGroupID = session.editorLayout.focusedGroupID
    session.handleEditorFileDrop(path: fileURL.path, on: originalGroupID, edge: nil)

    #expect(session.openDocuments.map(\.url) == [fileURL])
    #expect(session.editorLayout.group(id: originalGroupID)?.tabs.count == 1)
    #expect(session.selectedDocumentID == session.openDocuments.first?.id)

    // Dropping the already-open file again with an edge reuses its tab (no
    // duplicate document) and splits a new pane for it.
    session.handleEditorFileDrop(path: fileURL.path, on: originalGroupID, edge: .trailing)

    #expect(session.openDocuments.count == 1)
    #expect(session.editorLayout.groupIDs.count == 2)
}

@MainActor
@Test("handleEditorFileDrop rejects directories")
func handleEditorFileDropRejectsDirectories() throws {
    let session = WorkspaceSession()
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let groupID = session.editorLayout.focusedGroupID
    session.handleEditorFileDrop(path: tempDir.path, on: groupID, edge: nil)

    #expect(session.openDocuments.isEmpty)
}

@MainActor
@Test("handleEditorTabDrop with a nil edge moves the tab and is a no-op within the same group")
func handleEditorTabDropNilEdgeMovesOrNoOps() throws {
    let firstTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/first.swift")))
    let secondTab = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/second.swift")))
    let firstGroup = EditorGroupState(tabs: [firstTab])
    let secondGroup = EditorGroupState(tabs: [secondTab])
    var layout = EditorLayoutState(
        root: .split(
            id: EditorSplitID(),
            axis: .horizontal,
            fraction: 0.5,
            first: .group(firstGroup),
            second: .group(secondGroup)
        ),
        focusedGroupID: firstGroup.id
    )

    let session = WorkspaceSession()
    session.editorLayout = layout

    // Same-group drop with a nil edge is a no-op.
    session.handleEditorTabDrop(firstTab.id.rawValue.uuidString, on: firstGroup.id, edge: nil)
    #expect(session.editorLayout.group(id: firstGroup.id)?.tabs.map(\.id) == [firstTab.id])

    // Cross-group drop with a nil edge moves the tab without splitting.
    session.handleEditorTabDrop(firstTab.id.rawValue.uuidString, on: secondGroup.id, edge: nil)
    layout = session.editorLayout
    #expect(layout.groupIDs == [secondGroup.id])
    #expect(layout.group(id: secondGroup.id)?.tabs.map(\.id) == [secondTab.id, firstTab.id])
}
