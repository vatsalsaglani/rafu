import AppKit
import SwiftUI

/// TextKit 1 editor text view that draws Rafu's per-buffer decorations —
/// current-line highlight, indent guides, and matched-bracket boxes — in
/// `drawBackground(in:)`. Decorations never touch `NSTextStorage` attributes,
/// so the Neon syntax pipeline can re-apply storage attributes freely.
final class RafuTextView: NSTextView {
    enum CaretDirection {
        case above
        case below
    }

    /// Strong reference to the text storage. In a hand-built TextKit 1 stack
    /// NOTHING retains the storage (`NSLayoutManager.textStorage` is an
    /// `assign` reference and the view only retains its container), so the
    /// caller must own it or the stack reads through a dangling pointer and
    /// glyph drawing silently breaks.
    private var ownedTextStorage: NSTextStorage?

    /// Authoritative multi-caret state. AppKit is allowed to retain only the
    /// ranges it can represent; zero-length ranges it drops are rendered by
    /// `MultiCaretOverlayView` instead.
    private var caretRanges = [NSRange(location: 0, length: 0)]
    private var primaryCaretIndex = 0
    private var isSynchronizingNativeSelection = false
    private var multiCaretOverlay: MultiCaretOverlayView?

    private(set) var isPerformingMultiCaretEdit = false

    var hasMultipleCarets: Bool { caretRanges.count > 1 }

    var currentCaretRanges: [NSRange] {
        hasMultipleCarets ? caretRanges : [super.selectedRange()]
    }

    var primaryCaretRange: NSRange {
        hasMultipleCarets ? caretRanges[primaryCaretIndex] : super.selectedRange()
    }

    var currentCaretModel: MultiCaretModel {
        MultiCaretModel(
            ranges: currentCaretRanges,
            primaryIndex: hasMultipleCarets ? primaryCaretIndex : 0,
            textLength: (string as NSString).length
        )
    }

    /// Builds the TextKit 1 stack explicitly (storage → layout manager →
    /// container) so the view is deterministically TextKit 1;
    /// `NSTextView(frame:)` may create a TextKit 2 view that silently falls
    /// back when `layoutManager` is touched.
    static func makeTextKit1() -> RafuTextView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            containerSize: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        let textView = RafuTextView(frame: .zero, textContainer: container)
        textView.ownedTextStorage = storage
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // `acceptableDragTypes` is overridden below to refuse file/URL
        // drags; `updateDragTypeRegistration()` refreshes the view's
        // registered pasteboard types from that override immediately
        // (NSTextView normally calls it on property changes like
        // `isEditable`, not on init).
        textView.updateDragTypeRegistration()
        return textView
    }

    /// Refuses file and URL drags (from Finder or the sidebar's private
    /// editor-drag type) so dropping a file onto the text view never inserts
    /// its path as text. String/RTF types stay registered so in-editor text
    /// drag-and-drop keeps working.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        let excluded: Set<NSPasteboard.PasteboardType> = [
            .fileURL,
            .URL,
            NSPasteboard.PasteboardType("NSFilenamesPboardType"),
        ]
        return super.acceptableDragTypes.filter { !excluded.contains($0) }
    }

    var currentLineHighlightColor: NSColor? {
        didSet { if oldValue != currentLineHighlightColor { needsDisplay = true } }
    }

    var indentGuideColor: NSColor? {
        didSet { if oldValue != indentGuideColor { needsDisplay = true } }
    }

    var bracketBorderColor: NSColor? {
        didSet { if oldValue != bracketBorderColor { needsDisplay = true } }
    }

    var matchedBracketRanges: [NSRange] = [] {
        didSet { if oldValue != matchedBracketRanges { setNeedsDisplay(visibleRect) } }
    }

    /// Caret-driven navigation entry point, shared by ⌘-click and the editor
    /// context menu. Called after the caret has been moved to the clicked
    /// character, with the requested `NavigationTargetKind`. `nil` (the
    /// default) leaves ⌘-click as an ordinary click and suppresses the
    /// navigation context-menu items, e.g. for a document type
    /// `CodeEditorView` never wires this for.
    var navigateAction: (@MainActor (NavigationTargetKind) -> Void)?

    /// Resolves an LSP hover for the identifier at a UTF-16 offset, for the
    /// hover tooltip. `nil` (the default) disables hover entirely — no
    /// tracking-area tooltip machinery runs. LSP-only: it returns `nil` when
    /// no live, trusted server answers, so the tooltip silently no-ops.
    var hoverAction: (@MainActor (Int) async -> EditorHoverInfo?)?

    /// The theme the hover tooltip renders with. `CodeEditorView` sets this
    /// from its own `theme` on `makeNSView`/`updateNSView`; `NSHostingController`
    /// does not inherit the SwiftUI environment, so `EditorHoverTooltipView`
    /// cannot read `\.rafuTheme` and needs the value passed explicitly. `nil`
    /// (before the first `updateNSView`, or after teardown) falls back to a
    /// sensible default theme rather than rendering unthemed.
    var hoverTheme: RafuTheme?

    // MARK: - Hover tooltip state

    /// The single in-flight hover debounce task. Cancelled and replaced on
    /// every pointer move so only the latest hover position is ever resolved
    /// (no repeating timer).
    private var hoverDebounceTask: Task<Void, Never>?
    /// The UTF-16 offset the pending/shown hover targets, compared after the
    /// async resolve so a stale result never shows over a newer position.
    private var hoverTargetOffset: Int?
    private var hoverPopover: NSPopover?
    private var hoverTrackingArea: NSTrackingArea?
    /// Observer on the enclosing clip view's bounds, so any scroll (including
    /// inertial/programmatic, which `scrollWheel` alone would miss) dismisses
    /// the tooltip.
    private var hoverClipObserver: NSObjectProtocol?

    private static let hoverDelay = Duration.milliseconds(450)

    /// ⌥-click toggles a caret and ⌘-click invokes "go to definition" when an
    /// action is wired. Marked-text composition and every other click (plain,
    /// drag, other modifiers) fall through to `super`, so command-drag
    /// selection and ordinary editing are unaffected. Any click also dismisses
    /// a shown hover tooltip.
    override func mouseDown(with event: NSEvent) {
        dismissHover()
        guard !hasMarkedText() else {
            super.mouseDown(with: event)
            return
        }
        if event.modifierFlags.contains(.option),
            !event.modifierFlags.contains(.command)
        {
            let point = convert(event.locationInWindow, from: nil)
            let index = characterIndexForInsertion(at: point)
            let model = currentCaretModel.togglingCaret(
                at: index,
                textLength: (string as NSString).length
            )
            applyCaretRanges(model)
            scrollRangeToVisible(NSRange(location: index, length: 0))
            return
        }
        guard event.modifierFlags.contains(.command), let navigateAction else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        setSelectedRange(NSRange(location: index, length: 0))
        navigateAction(.definition)
    }

    // MARK: - Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
            self.hoverTrackingArea = nil
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard hoverAction != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        scheduleHover(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        // Only cancel a still-pending resolve. A SHOWN tooltip is left to the
        // popover's `.semitransient` behavior (outside click / scroll), so the
        // pointer can travel into it to reach the "Go to Declaration" button.
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
        hoverTargetOffset = nil
    }

    override func keyDown(with event: NSEvent) {
        // Any keystroke (including Escape) dismisses a shown tooltip before the
        // edit/command is processed.
        dismissHover()
        if event.keyCode == 53, hasMultipleCarets, !hasMarkedText() {
            collapseToPrimaryCaret()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Multi-caret ownership

    func applyCaretRanges(_ ranges: [NSRange], primaryIndex: Int = 0) {
        let model = MultiCaretModel(
            ranges: ranges,
            primaryIndex: primaryIndex,
            textLength: (string as NSString).length
        )
        applyCaretRanges(model)
    }

    func applyCaretRanges(_ model: MultiCaretModel) {
        let normalized = model.normalized(textLength: (string as NSString).length)
        caretRanges = normalized.ranges
        primaryCaretIndex = normalized.primaryIndex
        synchronizeNativeSelection()
        setNeedsDisplay(visibleRect)
    }

    /// Called from the text-view delegate after an ordinary AppKit selection
    /// change. Internal `setSelectedRanges` notifications are ignored; a real
    /// click or drag collapses the authoritative set to the new native range.
    func collapseCaretSetToNativeSelectionIfNeeded() {
        guard hasMultipleCarets,
            !isSynchronizingNativeSelection,
            !isPerformingMultiCaretEdit
        else { return }
        caretRanges = [super.selectedRange()]
        primaryCaretIndex = 0
        updateMultiCaretOverlay()
        setNeedsDisplay(visibleRect)
    }

    func refreshMultiCaretOverlay() {
        guard hasMultipleCarets else { return }
        updateMultiCaretOverlay()
    }

    func selectNextOccurrence() {
        guard !hasMarkedText() else { return }
        let previousRanges = currentCaretModel.ranges
        let result = currentCaretModel.selectingNextOccurrence(in: string)
        applyCaretRanges(result)
        let newest = result.ranges.first { !previousRanges.contains($0) } ?? result.primaryRange
        scrollRangeToVisible(newest)
    }

    func selectAllOccurrences() {
        guard !hasMarkedText() else { return }
        let result = currentCaretModel.selectingAllOccurrences(in: string)
        applyCaretRanges(result)
        scrollRangeToVisible(result.primaryRange)
    }

    func addCaret(direction: CaretDirection) {
        guard !hasMarkedText() else { return }
        let content = string as NSString
        let model = currentCaretModel
        let primaryLine = content.lineRange(
            for: NSRange(location: model.primaryRange.location, length: 0)
        )
        let goalColumn = min(
            model.primaryRange.location - primaryLine.location,
            lineContentLength(primaryLine, in: content)
        )
        let anchor = direction == .above ? model.ranges[0] : model.ranges[model.ranges.count - 1]
        let anchorLine = content.lineRange(
            for: NSRange(location: anchor.location, length: 0)
        )

        let targetLine: NSRange
        switch direction {
        case .above:
            guard anchorLine.location > 0 else { return }
            targetLine = content.lineRange(
                for: NSRange(location: anchorLine.location - 1, length: 0)
            )
        case .below:
            let nextLineStart = NSMaxRange(anchorLine)
            if nextLineStart < content.length {
                targetLine = content.lineRange(
                    for: NSRange(location: nextLineStart, length: 0)
                )
            } else if nextLineStart == content.length,
                anchorLine.location < content.length,
                lineContentLength(anchorLine, in: content) < anchorLine.length
            {
                targetLine = NSRange(location: content.length, length: 0)
            } else {
                return
            }
        }

        let location = MultiCaretModel.caretLocation(
            lineStartOffset: targetLine.location,
            lineLength: lineContentLength(targetLine, in: content),
            goalColumn: goalColumn
        )
        applyCaretRanges(model.addingCaret(at: location, textLength: content.length))
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    func collapseToPrimaryCaret() {
        guard hasMultipleCarets, !hasMarkedText() else { return }
        let collapsed = currentCaretModel.collapsedToPrimary(
            textLength: (string as NSString).length
        )
        applyCaretRanges(collapsed)
        scrollRangeToVisible(collapsed.primaryRange)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard hasMultipleCarets, !hasMarkedText() else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let replacement: String
        if let string = insertString as? String {
            replacement = string
        } else if let attributedString = insertString as? NSAttributedString {
            replacement = attributedString.string
        } else {
            NSSound.beep()
            return
        }
        performMultiCaretEdit(
            currentCaretModel.applyingReplacement(
                replacement,
                at: (string as NSString).length
            )
        )
    }

    override func deleteBackward(_ sender: Any?) {
        guard hasMultipleCarets, !hasMarkedText() else {
            super.deleteBackward(sender)
            return
        }
        performMultiCaretEdit(currentCaretModel.applyingDeletion(.backward, in: string))
    }

    override func deleteForward(_ sender: Any?) {
        guard hasMultipleCarets, !hasMarkedText() else {
            super.deleteForward(sender)
            return
        }
        performMultiCaretEdit(currentCaretModel.applyingDeletion(.forward, in: string))
    }

    override func paste(_ sender: Any?) {
        guard hasMultipleCarets, !hasMarkedText() else {
            super.paste(sender)
            return
        }
        guard let replacement = NSPasteboard.general.string(forType: .string) else {
            NSSound.beep()
            return
        }
        performMultiCaretEdit(
            currentCaretModel.applyingReplacement(
                replacement,
                at: (string as NSString).length
            )
        )
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        guard hasMultipleCarets, !hasMarkedText() else { return }
        multiCaretOverlay?.frame = bounds
        updateMultiCaretOverlay()
    }

    private func synchronizeNativeSelection() {
        isSynchronizingNativeSelection = true
        defer { isSynchronizingNativeSelection = false }

        let primary = caretRanges[primaryCaretIndex]
        let requestedRanges: [NSRange]
        if caretRanges.allSatisfy({ $0.length == 0 }) {
            // Spike A: AppKit sorts and coalesces multiple empty ranges down
            // to the earliest one. Supplying only the logical primary keeps
            // the native blinking caret at the correct location.
            requestedRanges = [primary]
        } else {
            // AppKit retains multiple non-empty selections. In a mixed set it
            // drops empty ranges; the overlay discovers and draws those below.
            requestedRanges = caretRanges
        }
        super.setSelectedRanges(
            requestedRanges.map(NSValue.init(range:)),
            affinity: .downstream,
            stillSelecting: false
        )
        updateMultiCaretOverlay()
    }

    private func performMultiCaretEdit(_ result: MultiCaretEditResult) {
        guard isEditable, let textStorage else { return }
        let edits = result.edits.filter { $0.range.length > 0 || !$0.replacement.isEmpty }
        guard !edits.isEmpty else {
            applyCaretRanges(result.model)
            return
        }

        let undoManager = undoManager
        isPerformingMultiCaretEdit = true
        undoManager?.beginUndoGrouping()

        var appliedCount = 0
        for edit in edits {
            guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else {
                break
            }
            textStorage.replaceCharacters(in: edit.range, with: edit.replacement)
            didChangeText()
            appliedCount += 1
        }

        if appliedCount > 0 {
            // AppKit raises an invalid-group exception when a closed explicit
            // undo group is named, so this must precede `endUndoGrouping()`.
            undoManager?.setActionName("Multi-Cursor Edit")
        }
        undoManager?.endUndoGrouping()
        isPerformingMultiCaretEdit = false

        if appliedCount == edits.count {
            applyCaretRanges(result.model)
        } else {
            // Rafu's delegate accepts every multi-caret sub-edit. If a future
            // delegate rejects one after earlier reverse-order edits applied,
            // do not install caret coordinates computed for the full batch.
            collapseCaretSetToNativeSelectionIfNeeded()
        }
    }

    private func updateMultiCaretOverlay() {
        guard hasMultipleCarets else {
            multiCaretOverlay?.removeFromSuperview()
            multiCaretOverlay = nil
            return
        }

        let retainedEmptyRanges = Set(
            super.selectedRanges.map(\.rangeValue).filter { $0.length == 0 }
        )
        let overlayRanges = caretRanges.filter {
            $0.length == 0 && !retainedEmptyRanges.contains($0)
        }
        let rects = overlayRanges.compactMap(caretRect(for:))
        guard !rects.isEmpty else {
            multiCaretOverlay?.removeFromSuperview()
            multiCaretOverlay = nil
            return
        }

        let overlay: MultiCaretOverlayView
        if let multiCaretOverlay {
            overlay = multiCaretOverlay
        } else {
            overlay = MultiCaretOverlayView(frame: bounds)
            overlay.autoresizingMask = [.width, .height]
            addSubview(overlay, positioned: .above, relativeTo: nil)
            multiCaretOverlay = overlay
        }
        overlay.frame = bounds
        overlay.update(
            caretRects: rects,
            color: insertionPointColor,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private func caretRect(for range: NSRange) -> NSRect? {
        guard range.length == 0, let layoutManager, let textContainer else { return nil }
        layoutManager.ensureLayout(for: textContainer)
        let contentLength = (string as NSString).length
        let location = min(max(range.location, 0), contentLength)
        let origin = textContainerOrigin
        let lineHeight = layoutManager.defaultLineHeight(
            for: font
                ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        )

        var caretRect: NSRect
        if location == contentLength,
            layoutManager.extraLineFragmentTextContainer === textContainer,
            layoutManager.extraLineFragmentRect.height > 0
        {
            caretRect = layoutManager.extraLineFragmentRect
        } else if location < contentLength {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: location, length: 1),
                actualCharacterRange: nil
            )
            caretRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            caretRect.size.width = 1
        } else if contentLength > 0 {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: NSRange(location: contentLength - 1, length: 1),
                actualCharacterRange: nil
            )
            let glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            caretRect = NSRect(
                x: glyphRect.maxX, y: glyphRect.minY, width: 1, height: glyphRect.height)
        } else {
            caretRect = NSRect(
                x: textContainer.lineFragmentPadding,
                y: 0,
                width: 1,
                height: lineHeight
            )
        }
        caretRect.origin.x += origin.x
        caretRect.origin.y += origin.y
        caretRect.size.width = max(1, caretRect.width)
        caretRect.size.height = max(lineHeight, caretRect.height)
        return caretRect
    }

    private func lineContentLength(_ lineRange: NSRange, in content: NSString) -> Int {
        var end = NSMaxRange(lineRange)
        while end > lineRange.location {
            let character = content.character(at: end - 1)
            guard
                character == unichar(UInt8(ascii: "\n"))
                    || character == unichar(UInt8(ascii: "\r"))
            else { break }
            end -= 1
        }
        return end - lineRange.location
    }

    /// Debounced hover resolve. Cancels the prior task, then — only when the
    /// pointer is actually over an identifier — schedules a `hoverDelay` wait
    /// followed by an LSP resolve. Cancellation is checked after the sleep AND
    /// after the resolve, and the resolved offset is compared against the still-
    /// current target, so a superseded position never shows a tooltip.
    private func scheduleHover(at point: NSPoint) {
        hoverDebounceTask?.cancel()
        guard let hoverAction else { return }
        let index = characterIndexForInsertion(at: point)
        let length = (string as NSString).length
        guard index >= 0, index <= length,
            IdentifierUnderCaret.word(in: string, at: index) != nil
        else {
            hoverTargetOffset = nil
            return
        }
        hoverTargetOffset = index
        hoverDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDelay)
            if Task.isCancelled { return }
            guard let self, self.hoverTargetOffset == index else { return }
            let info = await hoverAction(index)
            if Task.isCancelled { return }
            guard let info, self.hoverTargetOffset == index else { return }
            self.showHoverTooltip(info, at: index)
        }
    }

    private func showHoverTooltip(_ info: EditorHoverInfo, at offset: Int) {
        guard let layoutManager, let textContainer,
            let word = IdentifierUnderCaret.word(in: string, at: offset)
        else { return }
        let range = NSRange(location: word.position, length: (word.word as NSString).length)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range, actualCharacterRange: nil)
        var anchorRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        let origin = textContainerOrigin
        anchorRect.origin.x += origin.x
        anchorRect.origin.y += origin.y

        closeHoverPopover()

        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let tooltip = EditorHoverTooltipView(
            info: info, theme: hoverTheme ?? RafuThemeCatalog.indigo
        ) { [weak self] in
            self?.goToDeclarationFromHover(at: offset)
        }
        let hostingController = NSHostingController(rootView: tooltip)
        // Track the SwiftUI view's ideal size so the popover sizes itself to
        // content (small for a short signature, capped by the tooltip's own
        // scroll-when-long layout for a long one) instead of inflating to
        // whatever a greedy child view would otherwise claim.
        hostingController.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hostingController
        popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
        hoverPopover = popover
        observeClipViewForHoverDismissal()
    }

    private func goToDeclarationFromHover(at offset: Int) {
        dismissHover()
        setSelectedRange(NSRange(location: offset, length: 0))
        navigateAction?(.declaration)
    }

    /// Dismisses the tooltip and cancels any pending resolve. Called on edit
    /// (from the storage delegate), keystroke, scroll, click, and teardown.
    func dismissHover() {
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
        hoverTargetOffset = nil
        closeHoverPopover()
    }

    private func closeHoverPopover() {
        // Synchronous `close()` rather than the animated `performClose(_:)`:
        // this also runs from `dismantleNSView`, and an in-flight close
        // animation could outlive the positioning view (this text view) as
        // SwiftUI drops the scroll view during teardown.
        hoverPopover?.close()
        hoverPopover = nil
        if let hoverClipObserver {
            NotificationCenter.default.removeObserver(hoverClipObserver)
            self.hoverClipObserver = nil
        }
    }

    private func observeClipViewForHoverDismissal() {
        guard let clipView = enclosingScrollView?.contentView else { return }
        clipView.postsBoundsChangedNotifications = true
        hoverClipObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissHover() }
        }
    }

    // MARK: - Context menu

    /// Augments the default editor context menu (copy/paste/lookup, from
    /// `super`) with Go to Definition / Declaration / Find References at the
    /// top, followed by a separator. The clicked character is selected first so
    /// the caret-driven `navigateAction` targets the symbol under the pointer,
    /// exactly like ⌘-click. The items are only inserted when a `navigateAction`
    /// is wired AND the click landed on an identifier, so a right-click on
    /// whitespace or in a non-navigable editor shows only the default menu.
    override func menu(for event: NSEvent) -> NSMenu? {
        let baseMenu = super.menu(for: event)
        guard navigateAction != nil else { return baseMenu }
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        guard IdentifierUnderCaret.word(in: string, at: index) != nil else { return baseMenu }
        setSelectedRange(NSRange(location: index, length: 0))

        let menu = baseMenu ?? NSMenu()
        let items = [
            navigationMenuItem(title: "Go to Definition", kind: .definition, keyEquivalent: "j"),
            navigationMenuItem(title: "Go to Declaration", kind: .declaration, keyEquivalent: ""),
            navigationMenuItem(title: "Find References", kind: .references, keyEquivalent: "r"),
        ]
        var insertionIndex = 0
        for item in items {
            menu.insertItem(item, at: insertionIndex)
            insertionIndex += 1
        }
        menu.insertItem(.separator(), at: insertionIndex)
        return menu
    }

    private func navigationMenuItem(
        title: String, kind: NavigationTargetKind, keyEquivalent: String
    ) -> NSMenuItem {
        let item = NSMenuItem(
            title: title, action: #selector(navigateMenuItem(_:)), keyEquivalent: keyEquivalent)
        if !keyEquivalent.isEmpty {
            item.keyEquivalentModifierMask = [.control, .command]
        }
        item.target = self
        item.representedObject = kind
        return item
    }

    @objc private func navigateMenuItem(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? NavigationTargetKind else { return }
        navigateAction?(kind)
    }

    private static let indentColumns = 4
    private static let tabColumns = 4

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCurrentLineHighlight(in: rect)
        drawIndentGuides(in: rect)
        drawBracketBorders()
    }

    private func drawCurrentLineHighlight(in rect: NSRect) {
        guard let currentLineHighlightColor,
            let layoutManager, let textContainer,
            !hasMultipleCarets,
            selectedRange().length == 0
        else { return }
        let content = string as NSString
        let caret = min(selectedRange().location, content.length)
        let lineRange = content.lineRange(for: NSRange(location: caret, length: 0))
        let origin = textContainerOrigin

        let lineRect: NSRect
        if lineRange.length == 0 {
            // Caret on the trailing empty line (or an empty document).
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }
        guard lineRect.height > 0 else { return }
        let highlightRect = NSRect(
            x: rect.minX,
            y: lineRect.minY + origin.y,
            width: rect.width,
            height: lineRect.height
        )
        guard highlightRect.intersects(rect) else { return }
        currentLineHighlightColor.setFill()
        highlightRect.intersection(rect).fill()
    }

    // Indent guides use the plain `indentGuide` token for every stop. The
    // `indentGuideActive` variant (brightening the guides that enclose the
    // caret's block) needs a block-scope walk on every selection change and
    // is intentionally not implemented yet.
    private func drawIndentGuides(in rect: NSRect) {
        guard let indentGuideColor, let layoutManager, let textContainer, let font else { return }
        let content = string as NSString
        guard content.length > 0 else { return }

        let origin = textContainerOrigin
        var containerRect = rect
        containerRect.origin.x -= origin.x
        containerRect.origin.y -= origin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: textContainer)
        let charRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil)
        let columnWidth = (" " as NSString).size(withAttributes: [.font: font]).width
        guard columnWidth > 0 else { return }
        let leftInset = origin.x + textContainer.lineFragmentPadding

        indentGuideColor.setFill()
        var location = charRange.location
        while location < NSMaxRange(charRange) {
            let lineRange = content.lineRange(for: NSRange(location: location, length: 0))
            defer { location = NSMaxRange(lineRange) }
            guard let columns = leadingWhitespaceColumns(of: lineRange, in: content),
                columns > 0
            else { continue }

            let lineGlyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange, actualCharacterRange: nil)
            let lineRect = layoutManager.boundingRect(
                forGlyphRange: lineGlyphRange, in: textContainer)
            var column = 0
            while column < columns {
                let x = leftInset + CGFloat(column) * columnWidth
                NSRect(x: x, y: lineRect.minY + origin.y, width: 1, height: lineRect.height)
                    .fill()
                column += Self.indentColumns
            }
        }
    }

    /// Leading-whitespace column count of a line, or `nil` for blank lines
    /// (whitespace-only lines draw no guides so runs look stitched, matching
    /// the skipped-blank-line behavior of most editors' simple mode).
    private func leadingWhitespaceColumns(of lineRange: NSRange, in content: NSString) -> Int? {
        var columns = 0
        var index = lineRange.location
        let end = NSMaxRange(lineRange)
        while index < end {
            switch content.character(at: index) {
            case unichar(UInt8(ascii: " ")):
                columns += 1
            case unichar(UInt8(ascii: "\t")):
                columns += Self.tabColumns - columns % Self.tabColumns
            case unichar(UInt8(ascii: "\n")), unichar(UInt8(ascii: "\r")):
                return nil
            default:
                return columns
            }
            index += 1
        }
        return nil
    }

    private func drawBracketBorders() {
        guard let bracketBorderColor, let layoutManager, let textContainer,
            !hasMultipleCarets,
            !matchedBracketRanges.isEmpty
        else { return }
        let length = (string as NSString).length
        let origin = textContainerOrigin
        bracketBorderColor.setStroke()
        for range in matchedBracketRanges {
            guard NSMaxRange(range) <= length else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range, actualCharacterRange: nil)
            var glyphRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            glyphRect.origin.x += origin.x
            glyphRect.origin.y += origin.y
            let path = NSBezierPath(rect: glyphRect.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }
}
