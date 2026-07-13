import AppKit
import SwiftUI

struct CodeEditorView: NSViewRepresentable {
    let document: EditorDocument
    let theme: RafuTheme
    let findState: DocumentFindState?
    let gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)?
    let dropForwarding: EditorDropForwarding?

    init(
        document: EditorDocument,
        theme: RafuTheme,
        findState: DocumentFindState? = nil,
        gitLineChangesProvider: (@MainActor () async -> GitGutterLineChanges?)? = nil,
        dropForwarding: EditorDropForwarding? = nil
    ) {
        self.document = document
        self.theme = theme
        self.findState = findState
        self.gitLineChangesProvider = gitLineChangesProvider
        self.dropForwarding = dropForwarding
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
        scrollView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.backgroundColor = NSColor(rafuHex: theme.editor.background)
        textView.textColor = NSColor(rafuHex: theme.editor.foreground)
        textView.insertionPointColor = NSColor(rafuHex: theme.editor.cursor)
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.loadTask?.cancel()
        coordinator.gitMarkersTask?.cancel()
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.uninstallFindController()
        coordinator.document.saveAction = nil
        coordinator.document.textSnapshotProvider = nil
        coordinator.document.toggleCommentAction = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate, NSTextViewDelegate {
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
        private var loadedRevision: Int?
        private let fileService = WorkspaceFileService()

        init(document: EditorDocument, theme: RafuTheme, findState: DocumentFindState?) {
            self.document = document
            self.theme = theme
            self.findState = findState
        }

        func load() {
            loadTask?.cancel()
            let requestedRevision = document.revision
            loadedRevision = requestedRevision
            isLoading = true
            loadTask = Task(name: "Load \(document.displayName)") { [weak self] in
                guard let self else { return }
                do {
                    let text = try await fileService.readText(at: document.url)
                    try Task.checkCancellation()
                    textView?.string = text
                    gutterRuler?.invalidateLineIndex()
                    highlight()
                    textView?.undoManager?.removeAllActions()
                    recordDiskModificationDate()
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

        func textDidChange(_ notification: Notification) {
            guard !isLoading else { return }
            document.isDirty = true
            findState?.refresh()
        }

        func highlight() {
            let selection = textView?.selectedRanges
            syntaxPipeline?.applyBaseStyleAndInvalidate()
            if let selection { textView?.selectedRanges = selection }
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
                fileName: document.url.lastPathComponent
            )
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
                }
            }
        }
    }
}
