import Foundation
import Testing

@testable import RafuApp

private func input(
    _ id: UUID = UUID(),
    visible: Bool = false,
    dirty: Bool = false,
    access: Int = 0
) -> DocumentHibernationInput {
    DocumentHibernationInput(id: id, isVisible: visible, isDirty: dirty, accessSequence: access)
}

@Test("A visible document is never hibernated, even beyond the limit")
func hibernationNeverReleasesVisible() {
    let visible = input(visible: true, access: 0)
    let filler = (0..<20).map { input(access: $0 + 1) }
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: [visible] + filler, keepLoadedLimit: 2)
    #expect(!hibernating.contains(visible.id))
}

@Test("A dirty document is never hibernated, even as the oldest tab")
func hibernationNeverReleasesDirty() {
    let dirty = input(dirty: true, access: 0)
    let newer = (0..<20).map { input(access: $0 + 1) }
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: [dirty] + newer, keepLoadedLimit: 2)
    #expect(!hibernating.contains(dirty.id))
}

@Test("With open count at or below the limit, nothing hibernates")
func hibernationKeepsAllWithinLimit() {
    let documents = (0..<8).map { input(access: $0) }
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: documents, keepLoadedLimit: 8)
    #expect(hibernating.isEmpty)
}

@Test("Beyond the limit, the oldest non-visible non-dirty documents hibernate")
func hibernationReleasesOldestBeyondLimit() {
    // access 0...9, newest (highest access) kept: 5..9 with a limit of 5.
    let documents = (0..<10).map { input(access: $0) }
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: documents, keepLoadedLimit: 5)
    let hibernatedAccesses = Set(
        documents.filter { hibernating.contains($0.id) }.map(\.accessSequence))
    #expect(hibernatedAccesses == Set(0...4))
}

@Test("The newest-N kept set is chosen by access order, not array order")
func hibernationKeepsNewestByAccessOrder() {
    // Deliberately shuffle access ranks against array order.
    let a = input(access: 3)
    let b = input(access: 100)
    let c = input(access: 7)
    let d = input(access: 1)
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: [a, b, c, d], keepLoadedLimit: 2)
    // Newest two by access are b (100) and c (7); a (3) and d (1) hibernate.
    #expect(hibernating == Set([a.id, d.id]))
}

@Test("Under memory pressure, every non-visible non-dirty document hibernates")
func hibernationMemoryPressureReleasesAllEligible() {
    let visible = input(visible: true, access: 50)
    let dirty = input(dirty: true, access: 40)
    let idle = (0..<5).map { input(access: $0 + 100) }
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: [visible, dirty] + idle,
        keepLoadedLimit: 8,
        underMemoryPressure: true)
    #expect(hibernating == Set(idle.map(\.id)))
    #expect(!hibernating.contains(visible.id))
    #expect(!hibernating.contains(dirty.id))
}

@Test("Mixed visible, dirty, newest, and idle documents resolve correctly")
func hibernationMixedCombination() {
    let visible = input(visible: true, access: 1)
    let dirtyOld = input(dirty: true, access: 2)
    let newest = input(access: 99)
    let secondNewest = input(access: 98)
    let idleA = input(access: 10)
    let idleB = input(access: 11)
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: [visible, dirtyOld, newest, secondNewest, idleA, idleB],
        keepLoadedLimit: 2)
    // Kept: visible, dirtyOld (dirty), and the newest two (99, 98). The two
    // idle documents (10, 11) fall outside the newest-2 grace and hibernate.
    #expect(hibernating == Set([idleA.id, idleB.id]))
}

@Test("An empty document set produces no hibernation")
func hibernationEmptyInput() {
    #expect(DocumentHibernationPolicy.hibernating(documents: []).isEmpty)
}

@Test("A zero keep-loaded limit still spares visible and dirty documents")
func hibernationZeroLimitSparesVisibleAndDirty() {
    let visible = input(visible: true, access: 0)
    let dirty = input(dirty: true, access: 1)
    let idle = input(access: 2)
    let hibernating = DocumentHibernationPolicy.hibernating(
        documents: [visible, dirty, idle], keepLoadedLimit: 0)
    #expect(hibernating == Set([idle.id]))
}

@MainActor
@Test("clampSelection: nil passes through, in-range preserved, stale range clamped")
func clampSelectionBounds() {
    #expect(EditorDocument.clampSelection(nil, textLength: 100) == nil)

    let within = NSRange(location: 10, length: 5)
    #expect(EditorDocument.clampSelection(within, textLength: 100) == within)

    // A range past a shrunken text is clamped into [0, length].
    let stale = NSRange(location: 90, length: 40)
    let clamped = EditorDocument.clampSelection(stale, textLength: 50)
    #expect(clamped == NSRange(location: 50, length: 0))

    // A caret just inside the new end stays a zero-length caret.
    let caret = NSRange(location: 200, length: 0)
    #expect(
        EditorDocument.clampSelection(caret, textLength: 50) == NSRange(location: 50, length: 0))

    // Empty text clamps everything to the origin without crashing.
    #expect(
        EditorDocument.clampSelection(NSRange(location: 5, length: 5), textLength: 0)
            == NSRange(location: 0, length: 0))
}

@MainActor
@Test("A first-load dirty seed wins over real disk content and clears after load")
func pendingDirtyTextWinsOverDiskAndClearsAfterRestore() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try Data("disk contents".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let document = EditorDocument(url: url)
    defer { document.editorResources?.release() }
    document.isDirty = true
    document.pendingDirtyText = "unsaved edits"

    let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
    let coordinator = editor.makeCoordinator()
    let initialLoad = try #require(coordinator.loadTask)
    await initialLoad.value

    #expect(document.textSnapshotProvider?() == "unsaved edits")
    #expect(document.isDirty)
    #expect(document.pendingDirtyText == nil)
    #expect(try String(contentsOf: url, encoding: .utf8) == "disk contents")

    // A clean hibernation must release the seed-backed editor. The next
    // actual load must read disk instead of restoring the consumed seed.
    document.isDirty = false
    document.markHibernated()
    #expect(document.editorResources == nil)
    document.markLoaded()
    let reloadedCoordinator = editor.makeCoordinator()
    let diskLoad = try #require(reloadedCoordinator.loadTask)
    await diskLoad.value
    #expect(reloadedCoordinator !== coordinator)
    #expect(document.textSnapshotProvider?() == "disk contents")
    #expect(!document.isDirty)
    #expect(document.pendingDirtyText == nil)
}

@MainActor
@Test("A clean host teardown retains resources without a seed; hibernation releases them")
func pendingDirtyTextNeverCapturedForCleanDocument() async throws {
    let document = EditorDocument(untitledNumber: 1)
    let editor = CodeEditorView(document: document, theme: RafuThemeCatalog.indigo)
    let coordinator = editor.makeCoordinator()
    let load = try #require(coordinator.loadTask)
    await load.value
    let resources = try #require(document.editorResources)
    let host = editor.makeHost(coordinator: coordinator)
    #expect(resources.activeHost === host)

    CodeEditorView.dismantleNSView(host, coordinator: coordinator)
    #expect(document.editorResources === resources)
    #expect(resources.activeHost == nil)
    #expect(document.textSnapshotProvider?() == "")
    #expect(document.saveAction != nil)
    #expect(!document.isDirty)
    #expect(document.pendingDirtyText == nil)

    document.markHibernated()
    #expect(document.loadState == .hibernated)
    #expect(document.editorResources == nil)
    #expect(document.textSnapshotProvider == nil)
    #expect(document.saveAction == nil)
    #expect(document.pendingDirtyText == nil)
}
