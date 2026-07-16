import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument
    let theme: RafuTheme
    let findState: DocumentFindState?
    let gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)?
    let dropForwarding: EditorDropForwarding?
    let navigate: (@MainActor (NavigationTargetKind) -> Void)?
    let hover: (@MainActor (Int) async -> EditorHoverInfo?)?

    init(
        document: EditorDocument,
        theme: RafuTheme,
        findState: DocumentFindState? = nil,
        gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)? = nil,
        dropForwarding: EditorDropForwarding? = nil,
        navigate: (@MainActor (NavigationTargetKind) -> Void)? = nil,
        hover: (@MainActor (Int) async -> EditorHoverInfo?)? = nil
    ) {
        self.document = document
        self.theme = theme
        self.findState = findState
        self.gitLineChangesProvider = gitLineChangesProvider
        self.dropForwarding = dropForwarding
        self.navigate = navigate
        self.hover = hover
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
        document.toggleCommentAction = { [weak coordinator = context.coordinator] in
            coordinator?.toggleLineComment()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? EditorDropForwardingScrollView)?.dropForwarding = dropForwarding
        context.coordinator.theme = theme
        context.coordinator.gitLineChangesProvider = gitLineChangesProvider
        context.coordinator.updateSyntaxPipeline()
        context.coordinator.updateFindState(findState)
        context.coordinator.applyThemeDecorations()
        context.coordinator.reloadIfNeeded()
        context.coordinator.syncGuardSuppression()
        scrollView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        guard let textView = scrollView.documentView as? RafuTextView else { return }
        textView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        textView.textColor = NSColor(rafuHex: theme.editor.foreground)
        textView.insertionPointColor = NSColor(rafuHex: theme.editor.cursor)
        textView.navigateAction = navigate
        textView.hoverAction = hover
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
        coordinator.tearDownSyntaxPipeline()
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.uninstallFindController()
        coordinator.textView?.dismissHover()
        coordinator.textView?.navigateAction = nil
        coordinator.textView?.hoverAction = nil
        coordinator.document.saveAction = nil
        coordinator.document.textSnapshotProvider = nil
        coordinator.document.selectionProvider = nil
        coordinator.document.toggleCommentAction = nil
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
            refreshSelectionDecorations()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
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
                    // anchored range and payload may no longer be valid).
                    textView?.dismissHover()
                }
                if editedMask.contains(.editedCharacters), !isLoading {
                    document.recordEditDelta(editedRange: editedRange, changeInLength: delta)
                }
            }
        }
    }
}
