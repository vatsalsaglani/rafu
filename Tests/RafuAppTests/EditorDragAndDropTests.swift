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

@Test("TabStripDrop.insertionIndex resolves gaps, edges, and empty/degenerate strips")
func tabStripDropInsertionIndexResolvesGapsAndEdges() {
    let frames = [
        CGRect(x: 0, y: 0, width: 100, height: 28),
        CGRect(x: 100, y: 0, width: 100, height: 28),
        CGRect(x: 200, y: 0, width: 100, height: 28),
    ]

    // Before the first tab's midpoint.
    #expect(TabStripDrop.insertionIndex(forX: 10, tabFrames: frames) == 0)
    // In the gap between the first and second tabs.
    #expect(TabStripDrop.insertionIndex(forX: 150, tabFrames: frames) == 1)
    // In the gap between the second and third tabs.
    #expect(TabStripDrop.insertionIndex(forX: 250, tabFrames: frames) == 2)
    // Past the last tab's midpoint.
    #expect(TabStripDrop.insertionIndex(forX: 290, tabFrames: frames) == 3)

    // An empty strip always resolves to the only valid index, 0.
    #expect(TabStripDrop.insertionIndex(forX: 42, tabFrames: []) == 0)

    // Degenerate (zero-width) frames still resolve without crashing.
    let degenerate = [CGRect(x: 0, y: 0, width: 0, height: 0)]
    #expect(TabStripDrop.insertionIndex(forX: 0, tabFrames: degenerate) == 0)
    #expect(TabStripDrop.insertionIndex(forX: 1, tabFrames: degenerate) == 1)
}

@MainActor
@Test("reorderOrMoveEditorTab reorders within a group and moves across groups at an index")
func reorderOrMoveEditorTabHandlesSameGroupAndCrossGroup() throws {
    let tabA = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/a.swift")))
    let tabB = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/b.swift")))
    let tabC = EditorTabState(resource: .file(URL(fileURLWithPath: "/tmp/c.swift")))
    let group = EditorGroupState(tabs: [tabA, tabB, tabC], selectedTabID: tabB.id)
    let layout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)

    let session = WorkspaceSession()
    session.editorLayout = layout

    // Same-group reorder: move A (index 0) to insertion index 2 (between
    // B and C), which should land it immediately after B.
    session.reorderOrMoveEditorTab(tabA.id, to: group.id, atInsertionIndex: 2)
    #expect(
        session.editorLayout.group(id: group.id)?.tabs.map(\.id) == [tabB.id, tabA.id, tabC.id])
    // Selection is untouched by a pure reorder.
    #expect(session.editorLayout.group(id: group.id)?.selectedTabID == tabB.id)

    // Cross-group move: split off a second group, then reorder-or-move A
    // into it at a specific index.
    let splitResult = session.editorLayout.split(group: group.id, at: .trailing, moving: tabC.id)
    let secondGroupID = try #require(splitResult)
    session.reorderOrMoveEditorTab(tabA.id, to: secondGroupID, atInsertionIndex: 0)

    #expect(session.editorLayout.group(id: group.id)?.tabs.map(\.id) == [tabB.id])
    #expect(session.editorLayout.group(id: secondGroupID)?.tabs.map(\.id) == [tabA.id, tabC.id])
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

// MARK: - Finder file drop classification (EditorDragKind)

@Test("EditorDragKind gives rafuEditorDrag precedence over a coincidentally-present file URL")
func editorDragKindPrefersInternalPayloadOverFileURL() {
    let identifiers: Set<String> = [
        UTType.rafuEditorDrag.identifier,
        UTType.fileURL.identifier,
    ]
    #expect(EditorDragKind.classify(typeIdentifiers: identifiers) == .internalPayload)
}

@Test("EditorDragKind gives rafuEditorDrag precedence over a coincidentally-present string")
func editorDragKindPrefersInternalPayloadOverString() {
    let identifiers: Set<String> = [
        UTType.rafuEditorDrag.identifier,
        UTType.utf8PlainText.identifier,
    ]
    #expect(EditorDragKind.classify(typeIdentifiers: identifiers) == .internalPayload)
}

@Test("EditorDragKind classifies a Finder drop (file URL + string) as externalFiles")
func editorDragKindClassifiesFinderDropAsExternalFiles() {
    let identifiers: Set<String> = [
        UTType.fileURL.identifier,
        UTType.utf8PlainText.identifier,
    ]
    #expect(EditorDragKind.classify(typeIdentifiers: identifiers) == .externalFiles)
}

@Test("EditorDragKind classifies a bare file URL as externalFiles")
func editorDragKindClassifiesBareFileURLAsExternalFiles() {
    #expect(
        EditorDragKind.classify(typeIdentifiers: [UTType.fileURL.identifier]) == .externalFiles)
    #expect(
        EditorDragKind.classify(typeIdentifiers: ["NSFilenamesPboardType"]) == .externalFiles)
}

@Test("EditorDragKind classifies a string-only drag as text (in-editor selection drag)")
func editorDragKindClassifiesStringOnlyAsText() {
    #expect(
        EditorDragKind.classify(typeIdentifiers: [UTType.utf8PlainText.identifier]) == .text)
    #expect(EditorDragKind.classify(typeIdentifiers: []) == .text)
}

// MARK: - Finder multi-file drop routing

@MainActor
@Test("handleEditorFileDrops opens every path, applying the edge only to the first")
func handleEditorFileDropsOpensAllWithEdgeOnFirstOnly() throws {
    let session = WorkspaceSession()
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    // Seed the original group with an already-open file first — mirroring
    // every real drop target, which only offers a meaningful (non-`nil`)
    // split edge once its group has visible content and a laid-out size.
    // Splitting a genuinely EMPTY group (no real UI path can hover-resolve
    // a non-nil edge over one) immediately collapses back via
    // `EditorLayoutState.insert(_:in:)`'s empty-sibling collapse, which is
    // pre-existing behavior this test intentionally does not exercise.
    let existingURL = tempDir.appending(path: "existing.txt")
    try "existing".write(to: existingURL, atomically: true, encoding: .utf8)
    let originalGroupID = session.editorLayout.focusedGroupID
    session.handleEditorFileDrop(path: existingURL.path, on: originalGroupID, edge: nil)

    let firstURL = tempDir.appending(path: "first.txt")
    let secondURL = tempDir.appending(path: "second.txt")
    try "one".write(to: firstURL, atomically: true, encoding: .utf8)
    try "two".write(to: secondURL, atomically: true, encoding: .utf8)

    session.handleEditorFileDrops(
        paths: [firstURL.path, secondURL.path], on: originalGroupID, edge: .trailing)

    // The first file's edge split a new group; both files land together in
    // that new group rather than splitting twice.
    #expect(Set(session.openDocuments.map(\.url)) == [existingURL, firstURL, secondURL])
    #expect(session.editorLayout.groupIDs.count == 2)
    #expect(
        session.editorLayout.group(id: originalGroupID)?.tabs.map(\.resource) == [
            .file(existingURL)
        ])
    let newGroupID = session.editorLayout.groupIDs.first { $0 != originalGroupID }
    let newGroupTabURLs = newGroupID.flatMap { session.editorLayout.group(id: $0) }?.tabs
        .compactMap { tab -> URL? in
            guard case .file(let url) = tab.resource else { return nil }
            return url
        }
    #expect(Set(newGroupTabURLs ?? []) == [firstURL, secondURL])
}

@MainActor
@Test("handleEditorFileDrops rejects a directory path while opening the rest")
func handleEditorFileDropsRejectsDirectoryAmongValidPaths() throws {
    let session = WorkspaceSession()
    let tempDir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appending(path: "note.txt")
    try "hello".write(to: fileURL, atomically: true, encoding: .utf8)

    let groupID = session.editorLayout.focusedGroupID
    session.handleEditorFileDrops(paths: [tempDir.path, fileURL.path], on: groupID, edge: nil)

    #expect(session.openDocuments.map(\.url) == [fileURL])
}

@MainActor
@Test("handleEditorFileDrops is a no-op for an empty path list")
func handleEditorFileDropsNoOpForEmptyList() {
    let session = WorkspaceSession()
    let groupID = session.editorLayout.focusedGroupID
    session.handleEditorFileDrops(paths: [], on: groupID, edge: nil)
    #expect(session.openDocuments.isEmpty)
}

// MARK: - EditorDocument.isVideo

@MainActor
@Test("EditorDocument.isVideo detects mp4/mov/m4v and rejects other extensions")
func editorDocumentIsVideoDetectsVideoExtensions() {
    for ext in ["mp4", "mov", "m4v", "MP4", "Mov"] {
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/clip.\(ext)"))
        #expect(document.isVideo, "expected .\(ext) to be classified as a video")
    }
    for ext in ["txt", "png", "svg", "avi", "mkv"] {
        let document = EditorDocument(url: URL(fileURLWithPath: "/tmp/clip.\(ext)"))
        #expect(!document.isVideo, "did not expect .\(ext) to be classified as a video")
    }
}
