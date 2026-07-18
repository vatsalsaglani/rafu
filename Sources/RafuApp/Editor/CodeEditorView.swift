import AppKit
import SwiftUI

/// Bundled GX2 hunk-peek and blame-hover wiring for `CodeEditorView`,
/// threaded from `EditorCanvasView` down to `CodeEditorView.Coordinator`.
/// Bundled into one value (rather than several separate init parameters) so
/// `CodeEditorView`'s initializer stays readable. Copy SHA needs no session
/// access (plain `NSPasteboard`) and is built directly by the Coordinator.
struct GitPeekActions {
    let workingTreeDiffProvider: @MainActor () async -> GitFileDiff?
    let stageHunk: @MainActor (GitDiffHunk, GitFileDiff) async -> Void
    let openFullDiff: @MainActor () -> Void
    let showCommitInHistory: @MainActor (GitBlameLine) -> Void
    let openBlameCanvas: @MainActor () -> Void
    let isBusy: @MainActor () -> Bool

    init(
        workingTreeDiffProvider: @escaping @MainActor () async -> GitFileDiff?,
        stageHunk: @escaping @MainActor (GitDiffHunk, GitFileDiff) async -> Void,
        openFullDiff: @escaping @MainActor () -> Void,
        showCommitInHistory: @escaping @MainActor (GitBlameLine) -> Void,
        openBlameCanvas: @escaping @MainActor () -> Void,
        isBusy: @escaping @MainActor () -> Bool
    ) {
        self.workingTreeDiffProvider = workingTreeDiffProvider
        self.stageHunk = stageHunk
        self.openFullDiff = openFullDiff
        self.showCommitInHistory = showCommitInHistory
        self.openBlameCanvas = openBlameCanvas
        self.isBusy = isBusy
    }
}

struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument
    let theme: RafuTheme
    let findState: DocumentFindState?
    let gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)?
    /// Invoked after a successful save so the workspace can refresh Git state
    /// (sidebar badges, Source Control panel). Rafu's FSEvents watcher ignores
    /// its own writes, so a self-save is otherwise invisible to Git refresh.
    let requestGitRefresh: (@MainActor () -> Void)?
    let dropForwarding: EditorDropForwarding?
    let navigate: (@MainActor (NavigationTargetKind) -> Void)?
    let hover: (@MainActor (Int) async -> EditorHoverInfo?)?
    /// GX1: whether the inline-blame ghost annotation is on for this window.
    let inlineBlameEnabled: Bool
    /// GX1: resolves (or returns cached) blame for the active document.
    let inlineBlameProvider: (@MainActor () async -> GitBlame?)?
    /// AI tab-completion mode for this window (explicit opt-in toggle).
    let aiCompletionEnabled: Bool
    /// Resolves a completion for (prefix, suffix) around the caret.
    let aiCompletionProvider: (@MainActor (String, String) async -> String?)?
    /// GX2: hunk-peek and blame-hover wiring. `nil` disables both.
    let gitPeekActions: GitPeekActions?

    init(
        document: EditorDocument,
        theme: RafuTheme,
        findState: DocumentFindState? = nil,
        gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)? = nil,
        requestGitRefresh: (@MainActor () -> Void)? = nil,
        dropForwarding: EditorDropForwarding? = nil,
        navigate: (@MainActor (NavigationTargetKind) -> Void)? = nil,
        hover: (@MainActor (Int) async -> EditorHoverInfo?)? = nil,
        inlineBlameEnabled: Bool = false,
        inlineBlameProvider: (@MainActor () async -> GitBlame?)? = nil,
        aiCompletionEnabled: Bool = false,
        aiCompletionProvider: (@MainActor (String, String) async -> String?)? = nil,
        gitPeekActions: GitPeekActions? = nil
    ) {
        self.document = document
        self.theme = theme
        self.findState = findState
        self.gitLineChangesProvider = gitLineChangesProvider
        self.requestGitRefresh = requestGitRefresh
        self.dropForwarding = dropForwarding
        self.navigate = navigate
        self.hover = hover
        self.inlineBlameEnabled = inlineBlameEnabled
        self.inlineBlameProvider = inlineBlameProvider
        self.aiCompletionEnabled = aiCompletionEnabled
        self.aiCompletionProvider = aiCompletionProvider
        self.gitPeekActions = gitPeekActions
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, theme: theme, findState: findState)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = EditorDropForwardingScrollView()
        scrollView.dropForwarding = dropForwarding
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(rafuHex: theme.editor.background)

        let textView = RafuTextView.makeTextKit1()
        textView.autoresizingMask = [.width]
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainerInset = NSSize(width: 16, height: 14)
        textView.font = theme.resolvedEditorFont()
        textView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        textView.textColor = NSColor(rafuHex: theme.editor.foreground)
        textView.insertionPointColor = NSColor(rafuHex: theme.editor.cursor)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(rafuHex: theme.editor.selectionBackground)
        ]
        textView.delegate = context.coordinator
        textView.navigateAction = navigate
        textView.hoverAction = hover
        textView.hoverTheme = theme
        scrollView.documentView = textView

        let gutter = EditorGutterRulerView(
            scrollView: scrollView,
            textView: textView,
            style: EditorGutterStyle(theme: theme)
        )
        scrollView.verticalRulerView = gutter
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.textView = textView
        context.coordinator.gutterRuler = gutter
        context.coordinator.gitLineChangesProvider = gitLineChangesProvider
        context.coordinator.requestGitRefresh = requestGitRefresh
        context.coordinator.inlineBlameEnabled = inlineBlameEnabled
        context.coordinator.inlineBlameProvider = inlineBlameProvider
        context.coordinator.aiCompletionEnabled = aiCompletionEnabled
        context.coordinator.aiCompletionProvider = aiCompletionProvider
        context.coordinator.gitPeekActions = gitPeekActions
        gutter.peekAction = { [weak coordinator = context.coordinator] line in
            coordinator?.presentHunkPeek(atLine: line)
        }
        textView.blameHoverAction = { [weak coordinator = context.coordinator] in
            coordinator?.presentBlameHover()
        }
        context.coordinator.installSyntaxPipeline(for: textView)
        textView.textStorage?.delegate = context.coordinator
        context.coordinator.installFindController(for: textView)
        context.coordinator.applyThemeDecorations()
        context.coordinator.load()
        document.saveAction = { [weak coordinator = context.coordinator] in coordinator?.save() }
        document.textSnapshotProvider = { [weak textView] in textView?.string ?? "" }
        document.selectionProvider = { [weak textView] in
            textView?.selectedRange() ?? NSRange(location: 0, length: 0)
        }
        document.peekChangeAtCaretAction = { [weak coordinator = context.coordinator] in
            coordinator?.presentHunkPeekAtCaretLine()
        }
        document.toggleCommentAction = { [weak coordinator = context.coordinator] in
            coordinator?.toggleLineComment()
        }
        document.selectNextOccurrenceAction = { [weak textView] in
            textView?.selectNextOccurrence()
        }
        document.selectAllOccurrencesAction = { [weak textView] in
            textView?.selectAllOccurrences()
        }
        document.addCaretAboveAction = { [weak textView] in
            textView?.addCaret(direction: .above)
        }
        document.addCaretBelowAction = { [weak textView] in
            textView?.addCaret(direction: .below)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? EditorDropForwardingScrollView)?.dropForwarding = dropForwarding
        context.coordinator.theme = theme
        context.coordinator.gitLineChangesProvider = gitLineChangesProvider
        context.coordinator.requestGitRefresh = requestGitRefresh
        context.coordinator.gitPeekActions = gitPeekActions
        context.coordinator.updateSyntaxPipeline()
        context.coordinator.updateFindState(findState)
        context.coordinator.applyThemeDecorations()
        context.coordinator.reloadIfNeeded()
        context.coordinator.syncGuardSuppression()
        context.coordinator.updateInlineBlame(
            enabled: inlineBlameEnabled, provider: inlineBlameProvider)
        context.coordinator.updateAICompletion(
            enabled: aiCompletionEnabled, provider: aiCompletionProvider)
        scrollView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        guard let textView = scrollView.documentView as? RafuTextView else { return }
        textView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        textView.textColor = NSColor(rafuHex: theme.editor.foreground)
        textView.insertionPointColor = NSColor(rafuHex: theme.editor.cursor)
        textView.refreshMultiCaretOverlay()
        textView.navigateAction = navigate
        textView.hoverAction = hover
        textView.hoverTheme = theme
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        // Capture selection and scroll BEFORE tearing anything down so a
        // hibernation remount restores where the user was. Safe on any
        // dismantle (hibernation, close, window teardown); a dirty document
        // is never hibernated, so its live text is never released here.
        coordinator.captureViewState(from: nsView)
        // A dirty document can still be torn down by a STRUCTURAL SwiftUI
        // remount (splitting or moving a tab reshapes the erased view tree
        // and rebuilds every editor in it, not just the tab that moved — see
        // `EditorDocument.pendingDirtyText`). Hand off the live text so the
        // next `load()` seeds from it instead of disk, preserving the
        // unsaved edits that would otherwise be silently discarded.
        if coordinator.document.isDirty {
            coordinator.document.pendingDirtyText = coordinator.textView?.string
        }
        coordinator.loadTask?.cancel()
        coordinator.gitMarkersTask?.cancel()
        coordinator.clearInlineBlame()
        coordinator.clearAICompletion()
        coordinator.tearDownSyntaxPipeline()
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.uninstallFindController()
        coordinator.textView?.dismissHover()
        coordinator.textView?.closePeekPopover()
        coordinator.textView?.navigateAction = nil
        coordinator.textView?.hoverAction = nil
        coordinator.textView?.hoverTheme = nil
        coordinator.textView?.blameHoverAction = nil
        coordinator.gutterRuler?.peekAction = nil
        coordinator.document.saveAction = nil
        coordinator.document.textSnapshotProvider = nil
        coordinator.document.selectionProvider = nil
        coordinator.document.peekChangeAtCaretAction = nil
        coordinator.document.toggleCommentAction = nil
        coordinator.document.selectNextOccurrenceAction = nil
        coordinator.document.selectAllOccurrencesAction = nil
        coordinator.document.addCaretAboveAction = nil
        coordinator.document.addCaretBelowAction = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
        /// Cap on retained undo groups per editor. Bounds the memory a single
        /// long-lived buffer's undo stack can consume without meaningfully
        /// limiting interactive undo.
        static let undoLevelCap = 200

        let document: EditorDocument
        var theme: RafuTheme
        weak var textView: RafuTextView?
        weak var gutterRuler: EditorGutterRulerView?
        var loadTask: Task<Void, Never>?
        var gitMarkersTask: Task<Void, Never>?
        var gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)?
        var requestGitRefresh: (@MainActor () -> Void)?
        var inlineBlameEnabled = false
        var inlineBlameProvider: (@MainActor () async -> GitBlame?)?
        var aiCompletionEnabled = false
        var aiCompletionProvider: (@MainActor (String, String) async -> String?)?
        private var aiCompletionTask: Task<Void, Never>?
        /// Caret captured when the pending/shown completion was scheduled;
        /// any selection change away from it clears the ghost.
        private var aiCompletionCaret: Int?
        /// Bumped on every text change so a stale completion reply can never
        /// install a ghost over newer text (document.revision only changes
        /// on save/reload, so it cannot serve this purpose).
        private var editGeneration = 0
        private static let aiCompletionDebounce = Duration.milliseconds(500)
        var gitPeekActions: GitPeekActions?
        /// The in-flight (or debouncing) GX1 blame lookup for the caret's
        /// current line. Cancelled and replaced whenever the caret line
        /// changes; NEVER started while `document.isDirty` — see
        /// `scheduleInlineBlame()`'s doc comment for the typing-path proof.
        private var inlineBlameTask: Task<Void, Never>?
        /// The 1-based line number the currently shown/pending inline-blame
        /// annotation targets, or `nil` when none is scheduled/shown.
        /// Compared on every selection change so an unchanged caret line
        /// never restarts the debounce, and a changed line clears the stale
        /// annotation immediately (synchronously, before any async work).
        private var inlineBlameLine: Int?
        /// The most recently fetched `GitBlameLine` for `inlineBlameLine`,
        /// read synchronously by `presentBlameHover()` — hovering the ghost
        /// annotation never re-fetches blame.
        private var cachedInlineBlameLine: GitBlameLine?
        private static let inlineBlameDebounce = Duration.milliseconds(300)
        private(set) var findState: DocumentFindState?
        private var findController: NSTextViewFindController?
        private var syntaxPipeline: NeonSyntaxHighlightingPipeline?
        private var isLoading = true
        private var canSave = true
        /// Cached mirror of `document.suppressesSyntax`, compared by
        /// `syncGuardSuppression()` to detect a banner override.
        private var appliedSuppression = false
        private var loadedRevision: Int?
        private let fileService = WorkspaceFileService()

        /// Capped undo manager vended to the text view via
        /// `undoManager(for:)`. Lazily built so its `levelsOfUndo` cap is set
        /// once and shared for this editor's lifetime.
        private lazy var cappedUndoManager: UndoManager = {
            let manager = UndoManager()
            manager.levelsOfUndo = Self.undoLevelCap
            return manager
        }()

        init(document: EditorDocument, theme: RafuTheme, findState: DocumentFindState?) {
            self.document = document
            self.theme = theme
            self.findState = findState
        }

        /// Supplies the capped undo manager so the buffer's undo stack cannot
        /// grow without bound. Named action support (`⌘Z` labels, the ⌘/
        /// comment action name) works unchanged through this manager.
        func undoManager(for view: NSTextView) -> UndoManager? {
            cappedUndoManager
        }

        func load() {
            loadTask?.cancel()
            let requestedRevision = document.revision
            loadedRevision = requestedRevision
            isLoading = true
            loadTask = Task(name: "Load \(document.displayName)") { [weak self] in
                guard let self else { return }
                do {
                    // A pending dirty hand-off (see `EditorDocument.pendingDirtyText`)
                    // always wins over the disk read: it means this mount is
                    // rebuilding a still-dirty document after a structural
                    // remount, and reading disk here would silently discard
                    // unsaved edits. The disk read is skipped entirely in
                    // that case, so no late-arriving disk content can clobber
                    // the seeded text.
                    let seededDirtyText = document.pendingDirtyText
                    let text: String
                    if let seededDirtyText {
                        text = seededDirtyText
                    } else {
                        text = try await fileService.readText(at: document.url)
                    }
                    try Task.checkCancellation()
                    // Computed once per load, off-main; never re-evaluated
                    // per keystroke. Only an explicit banner override or the
                    // next load changes guard state afterward. Runs on the
                    // seeded dirty text too, so guard mode still reflects
                    // what's actually in the buffer.
                    let decision = await DocumentGuardPolicy.decide(for: text)
                    try Task.checkCancellation()
                    textView?.string = text
                    gutterRuler?.invalidateLineIndex()
                    document.applyGuardDecision(decision)
                    highlight()
                    textView?.undoManager?.removeAllActions()
                    restoreViewState()
                    recordDiskModificationDate()
                    if seededDirtyText != nil {
                        // Keep the document dirty (its content still differs
                        // from disk) and clear the hand-off immediately so it
                        // can never leak into a later, unrelated load.
                        document.isDirty = true
                        document.pendingDirtyText = nil
                    }
                    isLoading = false
                    findState?.refresh()
                    refreshSelectionDecorations()
                    refreshGitMarkers()
                    scheduleInlineBlame()
                } catch is CancellationError {
                    return
                } catch {
                    textView?.string = "Unable to open this file.\n\n\(error.localizedDescription)"
                    textView?.isEditable = false
                    canSave = false
                    isLoading = false
                }
            }
        }

        /// Records the current selection and vertical scroll fraction on the
        /// document so a later reload can restore them. Called from
        /// `dismantleNSView` before teardown.
        func captureViewState(from scrollView: NSScrollView) {
            guard let textView else { return }
            if textView.hasMultipleCarets {
                document.captureViewState(
                    selection: textView.primaryCaretRange,
                    scrollFraction: Self.scrollFraction(of: scrollView)
                )
                return
            }
            document.captureViewState(
                selection: textView.selectedRange(),
                scrollFraction: Self.scrollFraction(of: scrollView)
            )
        }

        /// Vertical scroll position as a [0, 1] fraction of the scrollable
        /// range: `visibleOrigin.y / max(1, contentHeight - visibleHeight)`.
        private static func scrollFraction(of scrollView: NSScrollView) -> CGFloat {
            let visible = scrollView.documentVisibleRect
            let contentHeight = scrollView.documentView?.bounds.height ?? 0
            let denominator = max(1, contentHeight - visible.height)
            return min(max(visible.origin.y / denominator, 0), 1)
        }

        /// Reapplies the document's saved selection (clamped to the reloaded
        /// text) and scroll fraction after `load()` replaces the buffer, then
        /// clears them so a later external reload does not resurrect a stale
        /// position. Fixes the cursor/scroll reset on a hibernation remount.
        private func restoreViewState() {
            guard let textView else { return }
            let selection = document.restoredSelection
            let scrollFraction = document.restoredScrollFraction
            document.captureViewState(selection: nil, scrollFraction: nil)

            let textLength = (textView.string as NSString).length
            if let clamped = EditorDocument.clampSelection(selection, textLength: textLength) {
                textView.setSelectedRange(clamped)
                textView.scrollRangeToVisible(clamped)
            }
            if let scrollFraction, let scrollView = textView.enclosingScrollView {
                applyScrollFraction(scrollFraction, in: scrollView)
            }
        }

        private func applyScrollFraction(_ fraction: CGFloat, in scrollView: NSScrollView) {
            guard let documentView = scrollView.documentView else { return }
            let contentHeight = documentView.bounds.height
            let visibleHeight = scrollView.contentView.bounds.height
            let maxOffset = max(0, contentHeight - visibleHeight)
            let y = min(max(fraction, 0), 1) * maxOffset
            documentView.scroll(NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading else { return }
            document.isDirty = true
            findState?.refresh()
            editGeneration += 1
            scheduleAICompletion()
        }

        func highlight() {
            let selection = textView?.selectedRanges
            syncGuardSuppression(forceRepaint: true)
            if let selection { textView?.selectedRanges = selection }
        }

        /// Single chokepoint for guard-mode suppression. Reads
        /// `document.suppressesSyntax`; when it differs from the cached
        /// value (or `forceRepaint` is set, as at load), flips
        /// `syntaxPipeline.isSuppressed` and repaints: base style only when
        /// suppression turns on, base style plus a full re-tokenize when it
        /// turns off (the banner's "Enable Highlighting" override) or when
        /// forced (a fresh load's new content). Called from the end of
        /// `load()` via `highlight()` and from `updateNSView`, so an
        /// override made through `EditorDocumentView`'s banner button is
        /// picked up on the next SwiftUI update pass.
        func syncGuardSuppression(forceRepaint: Bool = false) {
            let suppressed = document.suppressesSyntax
            guard forceRepaint || suppressed != appliedSuppression else { return }
            appliedSuppression = suppressed
            syntaxPipeline?.isSuppressed = suppressed
            syntaxPipeline?.applyBaseStyleAndInvalidate()
        }

        func save() {
            guard canSave, let text = textView?.string else { return }
            let url = document.url
            let document = document
            let fileService = fileService
            Task(name: "Save \(document.displayName)") {
                do {
                    try await fileService.writeText(text, to: url)
                    document.isDirty = false
                    document.revision += 1
                    loadedRevision = document.revision
                    recordDiskModificationDate()
                    refreshGitMarkers()
                    scheduleInlineBlame()
                    requestGitRefresh?()
                } catch {
                    document.errorMessage = error.localizedDescription
                }
            }
        }

        func reloadIfNeeded() {
            guard !document.isDirty, loadedRevision != document.revision else { return }
            load()
        }

        /// Records the file's on-disk modification date after a successful
        /// load or save so the workspace watcher can tell external edits
        /// apart from Rafu's own writes.
        private func recordDiskModificationDate() {
            document.knownDiskModificationDate =
                (try? FileManager.default.attributesOfItem(atPath: document.url.path))?[
                    .modificationDate] as? Date
        }

        func installSyntaxPipeline(for textView: NSTextView) {
            syntaxPipeline = NeonSyntaxHighlightingPipeline(
                textView: textView,
                theme: theme,
                fileExtension: document.url.pathExtension.lowercased(),
                fileName: document.url.lastPathComponent,
                grammarRegistry: .shared
            )
        }

        /// Cancels the grammar actor bring-up, any in-flight reparse, and
        /// releases the parser/tree. Called from `dismantleNSView` so a
        /// closed, hibernated, or structurally remounted editor does not leak
        /// syntax work.
        func tearDownSyntaxPipeline() {
            syntaxPipeline?.tearDown()
        }

        func updateSyntaxPipeline() {
            syntaxPipeline?.update(
                theme: theme,
                fileExtension: document.url.pathExtension.lowercased(),
                fileName: document.url.lastPathComponent
            )
        }

        func installFindController(for textView: NSTextView) {
            let controller = NSTextViewFindController(textView: textView)
            controller.matchHighlightColor = theme.editorFindMatchBackgroundColor
            controller.activeMatchHighlightColor = theme.editorFindMatchActiveBackgroundColor
            findController = controller
            findState?.attach(controller)
        }

        func updateFindState(_ newState: DocumentFindState?) {
            guard findState !== newState else { return }
            if let findState, let findController {
                findState.detach(findController)
                findController.clearHighlights()
            }
            findState = newState
            if let newState, let findController {
                newState.attach(findController)
            }
        }

        func uninstallFindController() {
            if let findState, let findController {
                findState.detach(findController)
                findController.clearHighlights()
            }
            findController = nil
        }

        /// Pushes theme-derived decoration colors to the text view, gutter,
        /// and find controller. All targets no-op when values are unchanged.
        func applyThemeDecorations() {
            if let textView {
                textView.currentLineHighlightColor = theme.editorLineHighlightColor
                textView.indentGuideColor = theme.editorIndentGuideColor
                textView.bracketBorderColor = theme.editorMatchingBracketBorderColor
                textView.inlineBlameColor = theme.editorInlineBlameColor
                textView.inlineCompletionGhostColor = theme.editorInlineBlameColor
            }
            gutterRuler?.style = EditorGutterStyle(theme: theme)
            if let findController {
                let matchColor = theme.editorFindMatchBackgroundColor
                let activeColor = theme.editorFindMatchActiveBackgroundColor
                let changed =
                    findController.matchHighlightColor != matchColor
                    || findController.activeMatchHighlightColor != activeColor
                findController.matchHighlightColor = matchColor
                findController.activeMatchHighlightColor = activeColor
                if changed, findState?.isActive == true {
                    findState?.refresh()
                }
            }
        }

        func toggleLineComment() {
            guard let textView, textView.isEditable,
                let prefix = LineCommenter.prefix(
                    forExtension: document.url.pathExtension.lowercased(),
                    fileName: document.url.lastPathComponent
                )
            else { return }
            let content = textView.string as NSString
            let selection = textView.selectedRange()
            let lineRange = content.lineRange(for: selection)
            let lines = content.substring(with: lineRange)
            let result = LineCommenter.toggle(lines: lines, prefix: prefix)
            guard result.replacement != lines,
                textView.shouldChangeText(in: lineRange, replacementString: result.replacement)
            else { return }
            textView.textStorage?.replaceCharacters(in: lineRange, with: result.replacement)
            textView.didChangeText()
            textView.undoManager?.setActionName(
                result.didComment ? "Comment Lines" : "Uncomment Lines")
            let newLength = (result.replacement as NSString).length
            if selection.length == 0 {
                let shifted = selection.location + newLength - lineRange.length
                let caret = min(max(shifted, lineRange.location), lineRange.location + newLength)
                textView.setSelectedRange(NSRange(location: caret, length: 0))
            } else {
                textView.setSelectedRange(NSRange(location: lineRange.location, length: newLength))
            }
        }

        func refreshGitMarkers() {
            gitMarkersTask?.cancel()
            guard let gitLineChangesProvider else {
                gutterRuler?.gitMarkers = nil
                return
            }
            let requestedRevision = document.revision
            gitMarkersTask = Task(name: "Git gutter \(document.displayName)") { [weak self] in
                guard let self else { return }
                let changes = await gitLineChangesProvider()
                guard !Task.isCancelled, document.revision == requestedRevision else { return }
                gutterRuler?.gitMarkers = changes
            }
        }

        // MARK: - GX1 inline blame

        /// Flips inline blame on/off and re-wires the provider from
        /// `updateNSView`. A no-op when neither changed; toggling ON
        /// schedules a fresh lookup for the caret's current line, toggling
        /// OFF clears immediately.
        func updateInlineBlame(
            enabled: Bool, provider: (@MainActor () async -> GitBlame?)?
        ) {
            let wasEnabled = inlineBlameEnabled
            inlineBlameEnabled = enabled
            inlineBlameProvider = provider
            guard enabled != wasEnabled else { return }
            if enabled {
                scheduleInlineBlame()
            } else {
                clearInlineBlame()
            }
        }

        /// Schedules (or cancels) the GX1 ghost-text annotation for the
        /// caret's current line. Called from `textViewDidChangeSelection`
        /// and after load/save.
        ///
        /// TYPING-PATH PROOF: while the user is typing, `document.isDirty`
        /// is `true` (set by `textDidChange`, which fires before AppKit's
        /// following selection-change notification for the same keystroke),
        /// so the very first guard below always short-circuits BEFORE the
        /// 300ms debounce is even scheduled — no `git blame` process is ever
        /// spawned between keystrokes. Only a caret move on a SAVED
        /// (non-dirty) buffer reaches the debounce.
        func scheduleInlineBlame() {
            guard inlineBlameEnabled, !document.isDirty, let textView, let inlineBlameProvider
            else {
                clearInlineBlame()
                return
            }
            let caret = textView.selectedRange().location
            let caretLine = gutterRuler?.lineNumber(forOffset: caret) ?? 1
            guard caretLine != inlineBlameLine else { return }
            inlineBlameLine = caretLine
            cachedInlineBlameLine = nil
            textView.inlineBlameAnnotation = nil
            inlineBlameTask?.cancel()
            let requestedRevision = document.revision
            inlineBlameTask = Task(name: "Inline blame \(document.displayName)") { [weak self] in
                try? await Task.sleep(for: Self.inlineBlameDebounce)
                if Task.isCancelled { return }
                // Re-check BEFORE calling the provider (not only after): a
                // keystroke resuming mid-debounce already flipped
                // `document.isDirty` synchronously (see `textDidChange`), so
                // this is the guard that keeps a typing burst from ever
                // reaching `WorkspaceSession.inlineBlame(for:)` — and the
                // process it would spawn — at all.
                guard let self, self.document.revision == requestedRevision,
                    self.inlineBlameLine == caretLine,
                    !self.document.isDirty
                else { return }
                guard let blame = await inlineBlameProvider() else { return }
                if Task.isCancelled { return }
                guard self.document.revision == requestedRevision,
                    self.inlineBlameLine == caretLine,
                    !self.document.isDirty
                else { return }
                guard let line = blame.lines.first(where: { $0.lineNumber == caretLine }) else {
                    self.textView?.inlineBlameAnnotation = nil
                    return
                }
                self.cachedInlineBlameLine = line
                let formatted = InlineBlameFormatter.format(line, referenceDate: Date())
                self.textView?.inlineBlameAnnotation = InlineBlameAnnotation(
                    lineNumber: caretLine, text: formatted)
            }
        }

        /// Cancels any pending/in-flight inline-blame lookup and clears the
        /// shown annotation. Called when inline blame is toggled off and
        /// from `dismantleNSView`.
        func clearInlineBlame() {
            inlineBlameTask?.cancel()
            inlineBlameTask = nil
            inlineBlameLine = nil
            cachedInlineBlameLine = nil
            textView?.inlineBlameAnnotation = nil
        }

        // MARK: - AI inline completion

        func updateAICompletion(
            enabled: Bool, provider: (@MainActor (String, String) async -> String?)?
        ) {
            let wasEnabled = aiCompletionEnabled
            aiCompletionEnabled = enabled
            aiCompletionProvider = provider
            if wasEnabled, !enabled { clearAICompletion() }
        }

        /// Schedules an AI tab-completion for the caret position after a
        /// typing pause. Unlike inline blame this deliberately RUNS on dirty
        /// buffers — completing unsaved text is the feature — but everything
        /// stays off the typing path: each keystroke only cancels the prior
        /// debounce task and clears the ghost; the provider is reached only
        /// after 500ms of quiet, and its reply is dropped unless the buffer
        /// revision and caret are still exactly where they were.
        func scheduleAICompletion() {
            guard aiCompletionEnabled, let textView, let aiCompletionProvider,
                !isLoading, !document.suppressesSyntax,
                !textView.hasMarkedText(), !textView.hasMultipleCarets,
                textView.selectedRange().length == 0
            else {
                clearAICompletion()
                return
            }
            aiCompletionTask?.cancel()
            textView.inlineCompletionGhost = nil
            let caret = textView.selectedRange().location
            aiCompletionCaret = caret
            let generation = editGeneration
            aiCompletionTask = Task(name: "AI completion \(document.displayName)") { [weak self] in
                try? await Task.sleep(for: Self.aiCompletionDebounce)
                if Task.isCancelled { return }
                guard let self, let textView = self.textView,
                    self.editGeneration == generation,
                    self.aiCompletionCaret == caret,
                    !textView.hasMarkedText(), !textView.hasMultipleCarets
                else { return }
                let content = textView.string as NSString
                let boundedCaret = min(caret, content.length)
                let prefix = content.substring(to: boundedCaret)
                let suffix = content.substring(from: boundedCaret)
                guard let suggestion = await aiCompletionProvider(prefix, suffix) else { return }
                if Task.isCancelled { return }
                guard self.editGeneration == generation, self.aiCompletionCaret == caret,
                    textView.selectedRange().location == caret
                else { return }
                textView.inlineCompletionGhost = suggestion
            }
        }

        func clearAICompletion() {
            aiCompletionTask?.cancel()
            aiCompletionTask = nil
            aiCompletionCaret = nil
            textView?.inlineCompletionGhost = nil
        }

        // MARK: - GX2 hunk peek / blame hover

        /// Builds and presents the hunk-peek card for `line`, sliced from
        /// the working-tree diff via `HunkPeekSlice`. A no-op when there is
        /// no wiring, no matching hunk at `line`, or the underlying diff
        /// fetch declines (no repository / not a tracked change).
        func presentHunkPeek(atLine line: Int) {
            guard let gitPeekActions else { return }
            let capturedTheme = theme
            Task { [weak self] in
                guard let self else { return }
                guard let diff = await gitPeekActions.workingTreeDiffProvider() else { return }
                guard let slice = HunkPeekSlice.slice(diff, atLine: line) else { return }
                let card = GitHunkPeekCard(
                    hunk: slice.hunk,
                    rows: slice.rows,
                    isTruncated: slice.isTruncated,
                    theme: capturedTheme,
                    isBusy: gitPeekActions.isBusy(),
                    stageHunk: { [weak self] in
                        Task {
                            await gitPeekActions.stageHunk(slice.hunk, diff)
                            self?.textView?.closePeekPopover()
                        }
                    },
                    openFullDiff: { [weak self] in
                        gitPeekActions.openFullDiff()
                        self?.textView?.closePeekPopover()
                    }
                )
                let hostingController = NSHostingController(rootView: card)
                hostingController.sizingOptions = [.preferredContentSize]
                self.textView?.presentPeekPopover(hostingController, atLine: line)
            }
        }

        /// The "Peek Change at Line" command's editor-side entry point:
        /// resolves the caret's current line and delegates to
        /// `presentHunkPeek(atLine:)`.
        func presentHunkPeekAtCaretLine() {
            guard let textView else { return }
            let caret = textView.selectedRange().location
            let line = gutterRuler?.lineNumber(forOffset: caret) ?? 1
            presentHunkPeek(atLine: line)
        }

        /// Builds and presents the blame-hover card from the cached blame
        /// line for the currently shown inline-blame annotation — hovering
        /// never re-fetches blame. A no-op when there is no cached line, no
        /// wiring, or no annotation currently shown.
        func presentBlameHover() {
            guard let gitPeekActions, let line = cachedInlineBlameLine, let textView,
                let annotationLine = textView.inlineBlameAnnotation?.lineNumber
            else { return }
            let capturedTheme = theme
            let card = GitBlameHoverCard(
                line: line,
                theme: capturedTheme,
                copySHA: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(line.commitID, forType: .string)
                },
                showInHistory: { gitPeekActions.showCommitInHistory(line) },
                openBlameCanvas: { gitPeekActions.openBlameCanvas() }
            )
            let hostingController = NSHostingController(rootView: card)
            hostingController.sizingOptions = [.preferredContentSize]
            textView.presentPeekPopover(hostingController, atLine: annotationLine)
        }

        private func refreshSelectionDecorations() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            textView.matchedBracketRanges =
                selection.length == 0
                ? BracketMatcher.matchedRanges(
                    in: textView.string, caretLocation: selection.location) ?? []
                : []
            // Redraw the visible background (caret line moved) and the
            // gutter's active line number.
            textView.setNeedsDisplay(textView.visibleRect)
            gutterRuler?.needsDisplay = true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isLoading else { return }
            (notification.object as? RafuTextView)?.collapseCaretSetToNativeSelectionIfNeeded()
            refreshSelectionDecorations()
            scheduleInlineBlame()
            // A caret move away from the scheduled/shown completion position
            // invalidates the ghost (typing re-schedules via textDidChange,
            // which runs before this notification and updates the caret).
            if let pendingCaret = aiCompletionCaret,
                textView?.selectedRange().location != pendingCaret
            {
                clearAICompletion()
            }
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            if let textView = textView as? RafuTextView,
                textView.isPerformingMultiCaretEdit
            {
                return true
            }
            // Auto-indent typed newlines only: a plain "\n" landing at the
            // caret with no marked text (IME) in play. Programmatic edits and
            // find-and-replace pass through untouched.
            guard replacementString == "\n",
                !textView.hasMarkedText(),
                affectedCharRange == textView.selectedRange()
            else { return true }
            let insertion = AutoIndenter.newlineInsertion(
                forCaretAt: affectedCharRange.location,
                in: textView.string,
                fileExtension: document.url.pathExtension.lowercased()
            )
            guard insertion != "\n" else { return true }
            textView.insertText(insertion, replacementRange: affectedCharRange)
            return false
        }

        nonisolated func textStorage(
            _ textStorage: NSTextStorage,
            didProcessEditing editedMask: NSTextStorageEditActions,
            range editedRange: NSRange,
            changeInLength delta: Int
        ) {
            MainActor.assumeIsolated {
                syntaxPipeline?.didProcessEditing(
                    editedMask: editedMask,
                    editedRange: editedRange,
                    changeInLength: delta
                )
                if editedMask.contains(.editedCharacters) {
                    gutterRuler?.invalidateLineIndex()
                    // A text edit invalidates any shown hover tooltip (its
                    // anchored range and payload may no longer be valid) and
                    // any shown GX2 peek popover (its anchored line/hunk may
                    // have shifted).
                    textView?.dismissHover()
                    textView?.closePeekPopover()
                }
                if editedMask.contains(.editedCharacters), !isLoading {
                    document.recordEditDelta(editedRange: editedRange, changeInLength: delta)
                }
            }
        }
    }
}
