/// What the editor canvas is showing. Resolved in ONE pure function from
/// session state, so adding a canvas mode is a new case plus one branch —
/// not an insertion into a chain whose ordering is load-bearing and
/// undocumented.
///
/// The precedence below is a transcription of the `if/else` chain that lived
/// in `EditorCanvasView.body` before this type existed. It is deliberately
/// literal: conditions that look redundant are kept, because the chain's
/// behaviour — not its tidiness — is the contract. See
/// `docs/references/editor-canvas-routing.md`.
nonisolated enum EditorCanvasRoute: Equatable {
    case welcome
    case empty
    case blame
    case standaloneDiff
    case graph
    case runDetail
    case settings
    case editor

    /// The canvas-relevant slice of `WorkspaceSession`, reduced to plain
    /// values so the resolver is testable without a session (and without the
    /// main actor).
    ///
    /// `hasSelectedDocument` and `hasSelectedDocumentID` are separate on
    /// purpose: the blame branch reads `session.selectedDocument` (an open
    /// document *matching* the selected id) while the diff/graph/run branches
    /// read `session.selectedDocumentID`. Those disagree whenever an id is
    /// selected but no open document carries it, and the original chain
    /// treated the two cases differently.
    struct Inputs: Equatable, Sendable {
        var hasDescriptor: Bool
        var hasAnyEditorTabs: Bool
        var hasGitOpenBlame: Bool
        var hasGitOpenDiff: Bool
        var hasConductorRunCanvasID: Bool
        var conductorGraphVisible: Bool
        var settingsVisible: Bool
        var hasSelectedDocument: Bool
        var hasSelectedDocumentID: Bool

        init(
            hasDescriptor: Bool = true,
            hasAnyEditorTabs: Bool = false,
            hasGitOpenBlame: Bool = false,
            hasGitOpenDiff: Bool = false,
            hasConductorRunCanvasID: Bool = false,
            conductorGraphVisible: Bool = false,
            settingsVisible: Bool = false,
            hasSelectedDocument: Bool = false,
            hasSelectedDocumentID: Bool = false
        ) {
            self.hasDescriptor = hasDescriptor
            self.hasAnyEditorTabs = hasAnyEditorTabs
            self.hasGitOpenBlame = hasGitOpenBlame
            self.hasGitOpenDiff = hasGitOpenDiff
            self.hasConductorRunCanvasID = hasConductorRunCanvasID
            self.conductorGraphVisible = conductorGraphVisible
            self.settingsVisible = settingsVisible
            self.hasSelectedDocument = hasSelectedDocument
            self.hasSelectedDocumentID = hasSelectedDocumentID
        }
    }

    /// Pure resolution, first match wins. Order is the contract.
    static func resolve(_ inputs: Inputs) -> EditorCanvasRoute {
        // 1. No workspace at all. Settings is the sole exception: a welcome
        //    window can host it, while no-window routing uses the Settings
        //    scene fallback before this resolver is involved.
        if !inputs.hasDescriptor, !inputs.settingsVisible {
            return .welcome
        }

        // 2. A workspace with nothing whatsoever to render: no tab, and none
        //    of the five tabless canvases is open.
        if !inputs.hasAnyEditorTabs, !inputs.hasGitOpenDiff, !inputs.hasGitOpenBlame,
            !inputs.hasConductorRunCanvasID, !inputs.conductorGraphVisible,
            !inputs.settingsVisible
        {
            return .empty
        }

        // 3. Blame outranks every other canvas, and unlike them it requires a
        //    resolved document (it titles itself with that document's name).
        if inputs.hasGitOpenBlame, inputs.hasSelectedDocument {
            return .blame
        }

        // 4-7. The tabless canvases. Each yields to a selected document id,
        //      so opening a file always returns the canvas to the editor.
        if inputs.hasGitOpenDiff, !inputs.hasSelectedDocumentID {
            return .standaloneDiff
        }
        if inputs.conductorGraphVisible, !inputs.hasSelectedDocumentID {
            return .graph
        }
        if inputs.hasConductorRunCanvasID, !inputs.hasSelectedDocumentID {
            return .runDetail
        }
        if inputs.settingsVisible, !inputs.hasSelectedDocumentID {
            return .settings
        }

        // 8. The editor layout tree.
        return .editor
    }
}

extension EditorCanvasRoute.Inputs {
    /// Reads the canvas-relevant state out of a live session. Kept next to
    /// the resolver so the mapping from session property to input is in one
    /// place; the resolution rules themselves stay session-free.
    @MainActor
    init(session: WorkspaceSession) {
        self.init(
            hasDescriptor: session.descriptor != nil,
            hasAnyEditorTabs: session.hasAnyEditorTabs,
            hasGitOpenBlame: session.gitOpenBlame != nil,
            hasGitOpenDiff: session.gitOpenDiff != nil,
            hasConductorRunCanvasID: session.conductorRunCanvasID != nil,
            conductorGraphVisible: session.conductorGraphVisible,
            settingsVisible: session.settingsVisible,
            hasSelectedDocument: session.selectedDocument != nil,
            hasSelectedDocumentID: session.selectedDocumentID != nil
        )
    }
}
