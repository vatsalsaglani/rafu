import Foundation
import Testing

@testable import RafuApp

/// Pins the G7 finding (`docs/references/ensemble-memory-profile.md`): a
/// document under a selected Ensemble board is already outside the visible
/// set, and the hibernation policy keeps it loaded only by the newest-N grace.
@Suite("Ensemble hidden document")
struct EnsembleHiddenDocumentTests {
    @MainActor
    @Test("A group whose selected tab is a board contributes no visible document")
    func boardSelectionHidesDocument() {
        let session = WorkspaceSession()
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let document = EditorDocument(url: url)
        session.openDocuments = [document]

        let fileTab = EditorTabState(resource: .file(url))
        let boardTab = EditorTabState(resource: .canvas(CanvasID()))
        let group = EditorGroupState(tabs: [fileTab, boardTab], selectedTabID: fileTab.id)
        session.editorLayout = EditorLayoutState(root: .group(group), focusedGroupID: group.id)
        #expect(session.visibleDocumentIDs == Set([document.id]))

        let boardSelected = EditorGroupState(
            id: group.id, tabs: [fileTab, boardTab], selectedTabID: boardTab.id)
        session.editorLayout = EditorLayoutState(
            root: .group(boardSelected), focusedGroupID: boardSelected.id)
        #expect(session.visibleDocumentIDs.isEmpty)
    }

    @Test("A recent clean document that is not visible stays loaded; pressure releases it")
    func policyKeepsRecentHiddenDocumentLoaded() {
        let hidden = DocumentHibernationInput(
            id: UUID(), isVisible: false, isDirty: false, accessSequence: 10)
        let dirty = DocumentHibernationInput(
            id: UUID(), isVisible: false, isDirty: true, accessSequence: 1)

        #expect(DocumentHibernationPolicy.hibernating(documents: [hidden, dirty]).isEmpty)
        #expect(
            DocumentHibernationPolicy.hibernating(
                documents: [hidden, dirty], underMemoryPressure: true) == Set([hidden.id]))
    }
}
