import Testing

@testable import RafuApp

/// These encode the `EditorCanvasView` chain as it behaved *before* the route
/// existed, transcribed branch by branch. They are a regression fence, not a
/// statement of what the precedence ought to be: if a rule here looks wrong,
/// the fix is a deliberate behaviour change with its own test edit, never a
/// quiet tidy-up.
@Suite("Editor canvas route")
struct EditorCanvasRouteTests {
    private typealias Inputs = EditorCanvasRoute.Inputs

    // MARK: - One case per route

    @Test("No descriptor routes to welcome")
    func welcome() {
        #expect(EditorCanvasRoute.resolve(Inputs(hasDescriptor: false)) == .welcome)
    }

    @Test("Descriptor with nothing open routes to empty")
    func empty() {
        #expect(EditorCanvasRoute.resolve(Inputs()) == .empty)
    }

    @Test("Blame plus a resolved document routes to blame")
    func blame() {
        let inputs = Inputs(
            hasGitOpenBlame: true, hasSelectedDocument: true, hasSelectedDocumentID: true)
        #expect(EditorCanvasRoute.resolve(inputs) == .blame)
    }

    @Test("Open diff with no selected document routes to the standalone diff")
    func standaloneDiff() {
        #expect(EditorCanvasRoute.resolve(Inputs(hasGitOpenDiff: true)) == .standaloneDiff)
    }

    @Test("Visible Settings with no selected document routes to settings")
    func settings() {
        #expect(EditorCanvasRoute.resolve(Inputs(settingsVisible: true)) == .settings)
    }

    @Test("Tabs with no canvas open route to the editor")
    func editor() {
        #expect(EditorCanvasRoute.resolve(Inputs(hasAnyEditorTabs: true)) == .editor)
    }

    // MARK: - Welcome outranks everything

    @Test("Welcome wins over every other state")
    func welcomeBeatsEverything() {
        let inputs = Inputs(
            hasDescriptor: false,
            hasAnyEditorTabs: true,
            hasGitOpenBlame: true,
            hasGitOpenDiff: true,
            hasSelectedDocument: true,
            hasSelectedDocumentID: true
        )
        #expect(EditorCanvasRoute.resolve(inputs) == .welcome)
    }

    // MARK: - The emptiness guard's exact condition set

    /// The guard fires only when the layout has no tab AND every tabless
    /// canvas is closed. Each condition is load-bearing: flipping any one of
    /// them alone must take the route out of `.empty`.
    @Test(
        "Any single open surface defeats the emptiness guard",
        arguments: [
            Inputs(hasAnyEditorTabs: true),
            Inputs(hasGitOpenBlame: true),
            Inputs(hasGitOpenDiff: true),
            Inputs(settingsVisible: true),
        ]
    )
    func emptinessGuardConditions(inputs: EditorCanvasRoute.Inputs) {
        #expect(EditorCanvasRoute.resolve(inputs) != .empty)
    }

    /// Blame without a resolved document still defeats the emptiness guard
    /// even though the blame branch itself cannot fire — the guard reads
    /// `gitOpenBlame`, the branch reads `selectedDocument`. The chain landed
    /// this state on the editor tree, and so does the route.
    @Test("Blame without a document escapes empty and falls through to the editor")
    func blameWithoutDocumentFallsThroughToEditor() {
        #expect(EditorCanvasRoute.resolve(Inputs(hasGitOpenBlame: true)) == .editor)
    }

    /// A selected id with no matching open document is the same shape: not
    /// empty, and not blame, because `selectedDocument` is what blame reads.
    @Test("Blame with a dangling selected id routes to the editor, not blame")
    func blameWithDanglingSelectionRoutesToEditor() {
        let inputs = Inputs(
            hasGitOpenBlame: true, hasSelectedDocument: false, hasSelectedDocumentID: true)
        #expect(EditorCanvasRoute.resolve(inputs) == .editor)
    }

    // MARK: - Precedence between the canvases

    @Test("Blame beats an open diff")
    func blameBeatsDiff() {
        let inputs = Inputs(
            hasGitOpenBlame: true,
            hasGitOpenDiff: true,
            hasSelectedDocument: true,
            hasSelectedDocumentID: true
        )
        #expect(EditorCanvasRoute.resolve(inputs) == .blame)
    }

    @Test("Blame beats Settings")
    func blameBeatsSettings() {
        let inputs = Inputs(
            hasGitOpenBlame: true,
            settingsVisible: true,
            hasSelectedDocument: true,
            hasSelectedDocumentID: true
        )
        #expect(EditorCanvasRoute.resolve(inputs) == .blame)
    }

    @Test("Diff beats Settings when nothing is selected")
    func diffBeatsSettings() {
        let inputs = Inputs(hasGitOpenDiff: true, settingsVisible: true)
        #expect(EditorCanvasRoute.resolve(inputs) == .standaloneDiff)
    }

    // MARK: - A selected document beats every tabless canvas

    @Test(
        "A selected document id defeats every tabless canvas",
        arguments: [
            Inputs(hasGitOpenDiff: true, hasSelectedDocumentID: true),
            Inputs(settingsVisible: true, hasSelectedDocumentID: true),
        ]
    )
    func selectedDocumentBeatsCanvases(inputs: EditorCanvasRoute.Inputs) {
        #expect(EditorCanvasRoute.resolve(inputs) == .editor)
    }

    @Test("A selected document beats every tabless canvas at once")
    func selectedDocumentBeatsEveryCanvas() {
        let inputs = Inputs(
            hasAnyEditorTabs: true,
            hasGitOpenDiff: true,
            settingsVisible: true,
            hasSelectedDocument: true,
            hasSelectedDocumentID: true
        )
        #expect(EditorCanvasRoute.resolve(inputs) == .editor)
    }

    /// Blame is the exception: it is the one canvas a selected document does
    /// *not* dismiss, because blame is about the selected document.
    @Test("A selected document does not dismiss blame")
    func selectedDocumentDoesNotDismissBlame() {
        let inputs = Inputs(
            hasAnyEditorTabs: true,
            hasGitOpenBlame: true,
            hasSelectedDocument: true,
            hasSelectedDocumentID: true
        )
        #expect(EditorCanvasRoute.resolve(inputs) == .blame)
    }
}
