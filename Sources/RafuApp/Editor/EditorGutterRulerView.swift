import AppKit

/// Theme-resolved colors and font for the editor gutter.
struct EditorGutterStyle: Equatable {
    var backgroundColor: NSColor
    var foregroundColor: NSColor
    var activeForegroundColor: NSColor
    var borderColor: NSColor?
    var addedColor: NSColor
    var modifiedColor: NSColor
    var deletedColor: NSColor
    var font: NSFont

    init(theme: RafuTheme) {
        backgroundColor = theme.editorGutterBackgroundColor
        foregroundColor = theme.editorGutterForegroundColor
        activeForegroundColor = theme.editorGutterActiveForegroundColor
        borderColor = theme.editorRulerBorderColor
        addedColor = theme.gitGutterAddedColor
        modifiedColor = theme.gitGutterModifiedColor
        deletedColor = theme.gitGutterDeletedColor
        font = theme.resolvedEditorFont()
    }
}

/// Line-number gutter for the code editor: numbers, caret-line emphasis, and
/// per-line Git change strips. One edit-driven line index serves line count,
/// lookup, and width. Layout work stays outside text-storage edit processing.
final class EditorGutterRulerView: NSRulerView {
    var style: EditorGutterStyle {
        didSet {
            guard style != oldValue else { return }
            cachedDigitWidth = nil
            thicknessNeedsUpdate = true
            scheduleThicknessUpdate()
            needsDisplay = true
        }
    }

    var gitMarkers: GitGutterLineChanges? {
        didSet {
            guard gitMarkers != oldValue else { return }
            needsDisplay = true
        }
    }

    /// GX2 hunk-peek action, wired by `CodeEditorView.Coordinator`. Invoked
    /// from `mouseDown` with the clicked line's 1-based number, but only
    /// when that line actually carries a git-marker strip — a click
    /// elsewhere in the gutter falls through to `super` unchanged. `nil`
    /// disables gutter-click peeking entirely.
    var peekAction: (@MainActor (Int) -> Void)?

    private weak var textView: NSTextView?
    private var lineIndex: EditorGutterLineIndex
    private var thicknessNeedsUpdate = true
    private var thicknessUpdateIsScheduled = false
    private(set) var thicknessUpdateCount = 0
    private(set) var thicknessRetileCount = 0

    /// Per-buffer counters for tests and debugger measurement; contains no text.
    var lineIndexOperations: EditorGutterLineIndex.Operations { lineIndex.operations }
    var indexedLineCount: Int { lineIndex.lineCount }
    private var cachedDigitWidth: CGFloat?

    private static let stripWidth: CGFloat = 3
    private static let numberGap: CGFloat = 6
    private static let trailingPadding: CGFloat = 6

    init(scrollView: NSScrollView, textView: NSTextView, style: EditorGutterStyle) {
        self.style = style
        self.textView = textView
        if let storage = textView.textStorage {
            lineIndex = EditorGutterLineIndex(content: storage.mutableString)
        } else {
            lineIndex = EditorGutterLineIndex(content: "" as NSString)
        }
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        // NSView.clipsToBounds defaults to false since macOS 14, and AppKit
        // hands rulers a dirty rect wider than their bounds. Without clipping,
        // the background fill below paints over the entire editor content.
        clipsToBounds = true
        clientView = textView
        reservedThicknessForMarkers = 0
        reservedThicknessForAccessoryView = 0
        ruleThickness = ceil(
            Self.stripWidth + Self.numberGap + 2
                * ("8" as NSString)
                .size(withAttributes: [.font: style.font]).width + Self.trailingPadding
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(gutterStorageDidProcessEditing(_:)),
            name: NSTextStorage.didProcessEditingNotification,
            object: textView.textStorage
        )
        textView.postsFrameChangedNotifications = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clientLayoutChanged),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clientLayoutChanged),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        updateThickness()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("EditorGutterRulerView does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    /// Compatibility entry point for explicit buffer loads. Normal edits have
    /// already updated the index through the storage notification. Only repair
    /// a missed storage replacement; do not rescan a correctly indexed load.
    func invalidateLineIndex() {
        if let content = textView?.textStorage?.mutableString,
            content.length != lineIndex.utf16Length
        {
            lineIndex.rebuild(content: content)
        }
        thicknessNeedsUpdate = true
        updateThickness()
        needsDisplay = true
    }

    /// The coordinator can call this inside didProcessEditing. It must never
    /// tile or request TextKit geometry there. The storage notification owns
    /// the edit delta; this compatibility call only requests deferred width.
    func markLineIndexStale() {
        scheduleThicknessUpdate()
        needsDisplay = true
    }

    // Keep a unique selector: NSObject has a deprecated, nonisolated
    // textStorageDidProcessEditing: category method in AppKit.
    @objc private func gutterStorageDidProcessEditing(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage,
            storage === textView?.textStorage,
            storage.editedMask.contains(.editedCharacters)
        else { return }
        lineIndex.applyEdit(
            content: storage.mutableString,
            editedRange: storage.editedRange,
            changeInLength: storage.changeInLength
        )
        thicknessNeedsUpdate = true
        scheduleThicknessUpdate()
        needsDisplay = true
    }

    private func scheduleThicknessUpdate() {
        guard !thicknessUpdateIsScheduled else { return }
        thicknessUpdateIsScheduled = true
        // This AppKit boundary needs an actual next-runloop dispatch. An
        // immediate MainActor call can re-enter TextKit during processEditing.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            thicknessUpdateIsScheduled = false
            updateThickness()
        }
    }

    /// Recomputes the gutter width from the current line count and, when it
    /// changes, re-tiles the scroll view so the document view is inset before
    /// anything draws. Computing thickness lazily inside `draw()` is too late:
    /// the text view is already tiled at the old width and renders under the
    /// numbers.
    func updateThickness() {
        guard thicknessNeedsUpdate else { return }
        thicknessNeedsUpdate = false
        thicknessUpdateCount += 1
        let lines = lineIndex.lineCount
        if cachedDigitWidth == nil {
            cachedDigitWidth = ("8" as NSString).size(withAttributes: [.font: style.font]).width
        }
        let digits = CGFloat(max(2, String(lines).count))
        let needed = ceil(
            Self.stripWidth + Self.numberGap + digits * (cachedDigitWidth ?? 7)
                + Self.trailingPadding
        )
        guard abs(needed - ruleThickness) > 0.5 else { return }
        ruleThickness = needed
        thicknessRetileCount += 1
        // `EditorDropForwardingScrollView.tile()` converts macOS 26's
        // overlay-inset ruler tiling back to classic frame tiling, so after
        // this the clip view starts at the gutter's trailing edge and x = 0
        // is the true horizontal home — see that override for the details.
        enclosingScrollView?.tile()
        enclosingScrollView?.documentView?.needsDisplay = true
    }

    @objc private func clientLayoutChanged() {
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        style.backgroundColor.setFill()
        dirtyRect.fill()
        if let borderColor = style.borderColor {
            borderColor.setFill()
            NSRect(x: bounds.maxX - 1, y: dirtyRect.minY, width: 1, height: dirtyRect.height)
                .fill()
        }

        guard let textView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer
        else { return }
        let contentLength = textView.textStorage?.length ?? 0

        let origin = textView.textContainerOrigin
        let rulerOffset = convert(NSPoint.zero, from: textView)
        var containerRect = textView.visibleRect
        containerRect.origin.x -= origin.x
        containerRect.origin.y -= origin.y
        let glyphRange = layoutManager.glyphRange(forBoundingRect: containerRect, in: container)
        let charRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil)
        let caretLine = lineNumber(forCharacterAt: textView.selectedRange().location)
        let attributes: (NSColor) -> [NSAttributedString.Key: Any] = { color in
            [.font: self.style.font, .foregroundColor: color]
        }

        var rowIndex = lineNumber(forCharacterAt: charRange.location) - 1
        while rowIndex < lineIndex.starts.count {
            let startOffset = lineIndex.starts[rowIndex]
            guard startOffset <= NSMaxRange(charRange) else { break }
            let fragmentRect: NSRect
            if startOffset >= contentLength {
                // Trailing empty line (or empty buffer).
                fragmentRect = layoutManager.extraLineFragmentRect
            } else {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: startOffset)
                fragmentRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex, effectiveRange: nil)
            }
            let y = fragmentRect.minY + origin.y + rulerOffset.y
            let lineNumber = rowIndex + 1

            let label = "\(lineNumber)" as NSString
            let color =
                lineNumber == caretLine ? style.activeForegroundColor : style.foregroundColor
            let labelAttributes = attributes(color)
            let size = label.size(withAttributes: labelAttributes)
            label.draw(
                at: NSPoint(
                    x: bounds.width - Self.trailingPadding - size.width,
                    y: y + (fragmentRect.height - size.height) / 2
                ),
                withAttributes: labelAttributes
            )
            drawGitMarkers(forLine: lineNumber, y: y, height: fragmentRect.height)
            rowIndex += 1
        }
    }

    private func drawGitMarkers(forLine lineNumber: Int, y: CGFloat, height: CGFloat) {
        guard let markers = gitMarkers else { return }
        if markers.added.contains(where: { $0.contains(lineNumber) }) {
            style.addedColor.setFill()
            NSRect(x: 0, y: y, width: Self.stripWidth, height: height).fill()
        } else if markers.modified.contains(where: { $0.contains(lineNumber) }) {
            style.modifiedColor.setFill()
            NSRect(x: 0, y: y, width: Self.stripWidth, height: height).fill()
        }
        if markers.deletedAfter.contains(lineNumber) {
            style.deletedColor.setFill()
            NSRect(x: 0, y: y + height - 1, width: Self.stripWidth + 3, height: 2).fill()
        }
        if lineNumber == 1, markers.deletedAfter.contains(0) {
            style.deletedColor.setFill()
            NSRect(x: 0, y: max(0, y - 1), width: Self.stripWidth + 3, height: 2).fill()
        }
    }

    /// GX2: a click anywhere in the git-marker strip column opens the
    /// hunk-peek popover for that line via `peekAction`; every other click
    /// (line-number column, no marker at that line, no `peekAction` wired)
    /// falls through to the default ruler behavior.
    override func mouseDown(with event: NSEvent) {
        guard let peekAction, let textView else {
            super.mouseDown(with: event)
            return
        }
        let rulerPoint = convert(event.locationInWindow, from: nil)
        guard rulerPoint.x <= Self.stripWidth + 2 else {
            super.mouseDown(with: event)
            return
        }
        let textPoint = textView.convert(event.locationInWindow, from: nil)
        let index = textView.characterIndexForInsertion(at: textPoint)
        let line = lineNumber(forCharacterAt: index)
        guard hasGitMarkerStrip(atLine: line) else {
            super.mouseDown(with: event)
            return
        }
        peekAction(line)
    }

    private func hasGitMarkerStrip(atLine line: Int) -> Bool {
        guard let markers = gitMarkers else { return false }
        return markers.added.contains(where: { $0.contains(line) })
            || markers.modified.contains(where: { $0.contains(line) })
    }

    /// Uses the index updated synchronously by character-edit notifications.
    func lineNumber(forOffset offset: Int) -> Int {
        lineIndex.lineNumber(forOffset: offset)
    }

    private func lineNumber(forCharacterAt offset: Int) -> Int {
        lineIndex.lineNumber(forOffset: offset)
    }
}
