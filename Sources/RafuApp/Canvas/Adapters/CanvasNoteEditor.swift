import AppKit
import Observation
import SwiftUI

// MARK: Model

/// Small, observable metadata about one note. The note's text never lives here:
/// `NSTextStorage` in `CanvasNoteBuffer` owns it, and this model only holds the
/// mode, a task count, a derived title, and a short excerpt (review 7.8).
///
/// For the card header (W6a): `isEditing`, `progressText` ("3/5", nil when the
/// note has no tasks), `derivedTitle` (first heading), `beginEditing()`,
/// `endEditing()`, and `toggleEditing()`. Get the model with
/// `WorkspaceSession.canvasNoteModel(boardID:card:)`.
@Observable
final class CanvasNoteModel {
    enum Mode: Equatable { case read, edit }

    /// Where Edit mode was left, so Read mode can scroll the same block into
    /// place: the caret's source line and its vertical position in the visible
    /// area as a fraction (0 top, 1 bottom).
    struct ExitAnchor: Equatable {
        let line: Int
        let fraction: CGFloat
    }

    private(set) var mode: Mode = .read
    private(set) var tasksDone = 0
    private(set) var tasksTotal = 0
    /// Text of the first heading, if the note has one.
    private(set) var derivedTitle: String?
    /// First paragraph, plain text, at most 240 characters.
    private(set) var excerpt: String?
    /// Bumped each time Read mode must rebuild its rendering from the buffer.
    private(set) var readRevision: UInt64 = 0
    private(set) var exitAnchor: ExitAnchor?

    @ObservationIgnored weak var buffer: CanvasNoteBuffer?
    /// Current board scale. Set by `CanvasNoteCard`.
    @ObservationIgnored var scale: () -> Double = { 1 }
    /// Zooms the board to this card so Edit mode is allowed. Set by `CanvasNoteCard`.
    @ObservationIgnored var zoomToCard: () -> Void = {}
    /// Focuses this card on the board. Set by `CanvasNoteCard`.
    @ObservationIgnored var focusCard: () -> Void = {}
    @ObservationIgnored private var summaryTask: Task<Void, Never>?

    var isEditing: Bool { mode == .edit }

    /// "3/5" for the header, nil when the note has no task items.
    var progressText: String? { tasksTotal > 0 ? "\(tasksDone)/\(tasksTotal)" : nil }

    /// Enters Edit mode. Below 50% zoom it first asks the board to zoom to the
    /// card; it returns false when editing is still not allowed afterwards.
    /// `line` puts the caret on that source line; `anchorOffset` is the visible
    /// vertical position, in points from the top of the note body, to keep it at.
    @discardableResult
    func beginEditing(atLine line: Int? = nil, anchorOffset: CGFloat? = nil) -> Bool {
        if mode == .edit { return true }
        if !CanvasNoteZoom.canEdit(atScale: scale()) {
            zoomToCard()
            guard CanvasNoteZoom.canEdit(atScale: scale()) else { return false }
        }
        focusCard()
        if let line { buffer?.placeCaret(atLine: line) }
        mode = .edit
        buffer?.setKeyHandling(true)
        Task { [weak self] in
            await Task.yield()
            self?.buffer?.revealCaret(atViewportOffset: anchorOffset)
        }
        return true
    }

    /// Leaves Edit mode and rebuilds the rendered view.
    func endEditing() {
        guard mode == .edit else { return }
        exitAnchor = buffer?.exitAnchor()
        buffer?.setKeyHandling(false)
        mode = .read
        readRevision &+= 1
        refreshSummary()
    }

    func consumeExitAnchor() { exitAnchor = nil }

    func toggleEditing() {
        if isEditing { endEditing() } else { beginEditing() }
    }

    /// Applies a Format command to the selection. Only meaningful in Edit mode.
    func perform(_ command: CanvasNoteFormatCommand) {
        guard isEditing else { return }
        buffer?.perform(command)
    }

    /// Asks Read mode to rebuild after the text changed behind its back.
    func invalidateReadView() {
        readRevision &+= 1
        refreshSummary()
    }

    func refreshSummary() {
        guard let buffer else { return }
        let summary = CanvasNoteMarkdown.summary(of: buffer.textView.string)
        if tasksDone != summary.tasksDone { tasksDone = summary.tasksDone }
        if tasksTotal != summary.tasksTotal { tasksTotal = summary.tasksTotal }
        if derivedTitle != summary.title { derivedTitle = summary.title }
        let short = summary.excerpt.map { String($0.prefix(240)) }
        if excerpt != short { excerpt = short }
    }

    /// Typing path: summary work waits for a pause.
    func scheduleSummaryRefresh() {
        summaryTask?.cancel()
        summaryTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.refreshSummary()
        }
    }
}

extension WorkspaceSession {
    /// The model for a note card, or nil for any other card.
    func canvasNoteModel(boardID: CanvasID, card: CanvasCard) -> CanvasNoteModel? {
        canvasResources[boardID]?.note(for: card)?.model
    }
}

// MARK: Edit style

/// Colours and sizes for Edit mode. Equatable so a theme or size change is the
/// only thing that restyles the whole note.
struct CanvasNoteEditStyle: Equatable {
    var baseSize: CGFloat
    var text: NSColor
    var secondary: NSColor
    var muted: NSColor
    var info: NSColor
    var chip: NSColor

    init(palette: RafuThemePalette, baseSize: CGFloat) {
        self.baseSize = baseSize
        text = NSColor(palette.textPrimary)
        secondary = NSColor(palette.textSecondary)
        muted = NSColor(palette.textMuted)
        info = NSColor(palette.info)
        chip = NSColor(palette.chipBackground)
    }

    var baseFont: NSFont { .systemFont(ofSize: baseSize, weight: .regular) }

    private var paragraph: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let font = baseFont
        let natural = font.ascender - font.descender + font.leading
        style.lineSpacing = max(0, baseSize * 20 / 13 - natural)
        return style
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [
            .font: baseFont, .foregroundColor: text, .paragraphStyle: paragraph,
            .backgroundColor: NSColor.clear,
        ]
    }

    func attributes(for style: CanvasNoteSyntax.Style) -> [NSAttributedString.Key: Any] {
        switch style {
        case .heading(let level):
            let scale: CGFloat = level == 1 ? 1.4 : (level == 2 ? 1.25 : 1.1)
            return [.font: NSFont.systemFont(ofSize: baseSize * scale, weight: .semibold)]
        case .marker:
            return [.foregroundColor: muted]
        case .strong:
            return [.font: NSFont.systemFont(ofSize: baseSize, weight: .semibold)]
        case .emphasis:
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            return [.font: italic]
        case .code:
            return [
                .font: NSFont.monospacedSystemFont(ofSize: baseSize * 0.92, weight: .regular),
                .backgroundColor: chip,
            ]
        case .fencedCode:
            return [.font: NSFont.monospacedSystemFont(ofSize: baseSize * 0.92, weight: .regular)]
        case .link:
            return [.foregroundColor: info]
        case .quote:
            return [.foregroundColor: secondary]
        }
    }
}

// MARK: Buffer

/// Live note text belongs to TextKit, never to observable SwiftUI state.
final class CanvasNoteBuffer: NSObject, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = NSTextView(usingTextLayoutManager: true)
    let model = CanvasNoteModel()
    private let undoOwner = UndoManager()
    var edited: (() -> Void)?
    private(set) var revision: UInt64 = 0
    private var style: CanvasNoteEditStyle?
    private var pendingEdit: NSRange?
    private var fenceSignature: [Int] = []
    private var keyMonitor: Any?

    init(snapshot: String) {
        super.init()
        textView.string = snapshot
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.font = .systemFont(ofSize: 13)
        textView.delegate = self
        scrollView.hasVerticalScroller = true
        scrollView.documentView = textView
        model.buffer = self
        model.refreshSummary()
    }

    func snapshot() throws -> String {
        let value = textView.string
        guard value.utf8.count <= CanvasLimits.noteBytes else { throw CanvasError.invalidDocument }
        return value
    }

    func textView(
        _ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString, let range = Range(affectedCharRange, in: textView.string)
        else { return true }
        let proposed = textView.string.replacingCharacters(in: range, with: replacementString)
        guard proposed.utf8.count <= CanvasLimits.noteBytes else {
            NSSound.beep()
            return false
        }
        let touched = NSRange(
            location: affectedCharRange.location, length: replacementString.utf16.count)
        pendingEdit = pendingEdit.map { NSUnionRange($0, touched) } ?? touched
        return true
    }

    func textDidChange(_ notification: Notification) {
        revision &+= 1
        restyleAfterEdit()
        model.scheduleSummaryRefresh()
        edited?()
    }

    func undoManager(for view: NSTextView) -> UndoManager? { undoOwner }

    // MARK: Programmatic edits

    /// Replaces text through the text view so the edit is one undo step, runs
    /// the size limit, and reaches the save path like typing does.
    @discardableResult
    func replace(
        _ range: NSRange, with string: String, selecting selection: NSRange? = nil,
        actionName: String? = nil
    ) -> Bool {
        // A card that is not focused keeps its text view non-editable for the
        // user, but Read mode still toggles tasks through it.
        let wasEditable = textView.isEditable
        textView.isEditable = true
        defer { textView.isEditable = wasEditable }
        guard NSMaxRange(range) <= (textView.string as NSString).length,
            textView.shouldChangeText(in: range, replacementString: string)
        else { return false }
        textView.textStorage?.replaceCharacters(in: range, with: string)
        if let selection { textView.setSelectedRange(selection) }
        textView.didChangeText()
        if let actionName { undoOwner.setActionName(actionName) }
        return true
    }

    /// Flips the `index`th task marker in the source (Read mode checkbox).
    @discardableResult
    func toggleTask(at index: Int) -> Bool {
        guard let edit = CanvasNoteMarkdown.toggledTask(in: textView.string, at: index)
        else { return false }
        return replace(edit.range, with: edit.replacement, actionName: "Toggle Task")
    }

    func perform(_ command: CanvasNoteFormatCommand) {
        guard
            let result = CanvasNoteFormatting.apply(
                command, to: textView.string, selection: textView.selectedRange())
        else { return }
        replace(
            result.range, with: result.replacement, selecting: result.selection,
            actionName: command.title)
    }

    /// Typing on an empty selected note starts the note with that text.
    func insertInitialText(_ text: String) {
        replace(NSRange(location: 0, length: 0), with: text, selecting: nil)
        textView.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    }

    var isEmpty: Bool { textView.string.isEmpty }

    var markdown: String { textView.string }

    var canUndo: Bool { undoOwner.canUndo }
    var canRedo: Bool { undoOwner.canRedo }

    func undo() { if undoOwner.canUndo { undoOwner.undo() } }
    func redo() { if undoOwner.canRedo { undoOwner.redo() } }

    // MARK: Caret and scroll

    func placeCaret(atLine line: Int) {
        let offset = CanvasNoteMarkdown.offset(ofLine: line, in: textView.string)
        textView.setSelectedRange(NSRange(location: offset, length: 0))
    }

    /// Source line of the caret and where it sits in the visible area.
    func exitAnchor() -> CanvasNoteModel.ExitAnchor {
        let caret = textView.selectedRange().location
        let line = CanvasNoteMarkdown.line(containing: caret, in: textView.string)
        var fraction: CGFloat = 0
        if let local = caretRectInTextView() {
            let clip = scrollView.contentView.bounds
            if clip.height > 0 {
                fraction = min(1, max(0, (local.minY - clip.origin.y) / clip.height))
            }
        }
        return CanvasNoteModel.ExitAnchor(line: line, fraction: fraction)
    }

    private func caretRectInTextView() -> CGRect? {
        guard let window = textView.window else { return nil }
        var actual = NSRange()
        let caret = NSRange(location: textView.selectedRange().location, length: 0)
        let screenRect = textView.firstRect(forCharacterRange: caret, actualRange: &actual)
        return textView.convert(window.convertFromScreen(screenRect), from: nil)
    }

    /// Scrolls so the caret line sits `offset` points below the top of the
    /// visible area, or just keeps the caret visible when `offset` is nil.
    func revealCaret(atViewportOffset offset: CGFloat?) {
        let selection = textView.selectedRange()
        guard let offset, let local = caretRectInTextView() else {
            textView.scrollRangeToVisible(selection)
            return
        }
        let clip = scrollView.contentView
        let maximum = max(0, textView.frame.height - clip.bounds.height)
        let target = min(maximum, max(0, local.minY - offset))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Styling

    func apply(style newStyle: CanvasNoteEditStyle) {
        guard newStyle != style else { return }
        style = newStyle
        textView.font = newStyle.baseFont
        textView.textColor = newStyle.text
        textView.typingAttributes = newStyle.baseAttributes
        fenceSignature = CanvasNoteSyntax.fenceSignature(of: textView.string)
        restyle(range: nil)
    }

    private func restyleAfterEdit() {
        defer { pendingEdit = nil }
        guard style != nil, !textView.hasMarkedText() else { return }
        let signature = CanvasNoteSyntax.fenceSignature(of: textView.string)
        if signature != fenceSignature {
            fenceSignature = signature
            restyle(range: nil)
        } else {
            restyle(range: pendingEdit ?? textView.selectedRange())
        }
    }

    private func restyle(range: NSRange?) {
        guard let style, let storage = textView.textStorage else { return }
        let length = storage.length
        var clipped = range
        if let range {
            let location = min(range.location, length)
            clipped = NSRange(location: location, length: min(range.length, length - location))
        }
        let result = CanvasNoteSyntax.runs(in: storage.string, restrictedTo: clipped)
        guard NSMaxRange(result.covered) <= length else { return }
        storage.beginEditing()
        storage.setAttributes(style.baseAttributes, range: result.covered)
        for run in result.runs where NSMaxRange(run.range) <= length {
            storage.addAttributes(style.attributes(for: run.style), range: run.range)
        }
        storage.endEditing()
        textView.typingAttributes = style.baseAttributes
    }

    // MARK: Keyboard

    /// While a note is in Edit mode its formatting shortcuts run before the main
    /// menu sees the key, because ⌘B (Toggle Sidebar) and ⇧⌘L (Select All
    /// Occurrences) already belong to the workbench menus.
    func setKeyHandling(_ enabled: Bool) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard enabled else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, model.isEditing, let window = textView.window,
                event.window === window, window.firstResponder === textView,
                !textView.hasMarkedText()
            else { return event }
            return handle(event) ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        let control = flags.contains(.control)
        if CanvasNoteShortcuts.exitsEditing(
            keyCode: event.keyCode, command: command, shift: shift, option: option,
            control: control)
        {
            model.endEditing()
            return true
        }
        if let action = CanvasNoteShortcuts.command(
            keyCode: event.keyCode, command: command, shift: shift, option: option,
            control: control)
        {
            perform(action)
            return true
        }
        return false
    }

    isolated deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        textView.delegate = nil
        undoOwner.removeAllActions()
    }
}

// MARK: Edit view

struct CanvasNoteEditor: NSViewRepresentable {
    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var noteFontSize: CGFloat = 13
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession
    let presentationID: UUID?
    let isCurrentPresentation: Bool

    func makeNSView(context: Context) -> NativeContentMount { NativeContentMount() }
    func updateNSView(_ view: NativeContentMount, context: Context) {
        guard isCurrentPresentation, let resources = session.canvasResources[board.id],
            resources.board === board, resources.canPresent(owner: presentationID),
            let buffer = resources.note(for: card)
        else {
            view.detach()
            return
        }
        view.mount(buffer.scrollView)
        buffer.apply(style: CanvasNoteEditStyle(palette: theme.palette, baseSize: noteFontSize))
        buffer.textView.backgroundColor = NSColor(theme.palette.editorBackground)
        buffer.textView.insertionPointColor = NSColor(theme.palette.accent)
        buffer.scrollView.backgroundColor = NSColor(theme.palette.editorBackground)
        let active = board.contentIsActive && board.focusedCardID == card.id
        buffer.textView.isEditable = active
        buffer.textView.isSelectable = active
        let owner = presentationID
        let cardID = card.id
        view.onWindowAttached = { [weak board, weak resources, weak buffer, weak view] in
            guard let board, let buffer, let view, board.contentIsActive,
                board.focusedCardID == cardID,
                resources?.canPresent(owner: owner) == true,
                buffer.scrollView.superview === view
            else { return }
            view.window?.makeFirstResponder(buffer.textView)
        }
        if active, view.window?.firstResponder !== buffer.textView {
            view.onWindowAttached?()
        }
    }
    static func dismantleNSView(_ view: NativeContentMount, coordinator: ()) { view.detach() }
}
