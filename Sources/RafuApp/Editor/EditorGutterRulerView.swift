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
/// per-line Git change strips. State is per open buffer; the line-start index
/// is invalidated on every edit and rebuilt lazily on the next draw.
final class EditorGutterRulerView: NSRulerView {
    var style: EditorGutterStyle {
        didSet {
            guard style != oldValue else { return }
            cachedDigitWidth = nil
            updateThickness()
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
    private var lineStartOffsets: [Int] = [0]
    private var lineIndexIsValid = false
    private var cachedDigitWidth: CGFloat?

    private static let stripWidth: CGFloat = 3
    private static let numberGap: CGFloat = 6
    private static let trailingPadding: CGFloat = 6

    init(scrollView: NSScrollView, textView: NSTextView, style: EditorGutterStyle) {
        self.style = style
        self.textView = textView
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
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("EditorGutterRulerView does not support NSCoder")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var isFlipped: Bool { true }

    func invalidateLineIndex() {
        lineIndexIsValid = false
        updateThickness()
        needsDisplay = true
    }

    /// Recomputes the gutter width from the current line count and, when it
    /// changes, re-tiles the scroll view so the document view is inset before
    /// anything draws. Computing thickness lazily inside `draw()` is too late:
    /// the text view is already tiled at the old width and renders under the
    /// numbers.
    func updateThickness() {
        guard let content = textView?.string as NSString? else { return }
        let lines = max(1, lineCount(in: content))
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
        enclosingScrollView?.tile()
        clampHorizontalScrollIfNeeded()
        enclosingScrollView?.documentView?.needsDisplay = true
    }

    /// The editor wraps to its width (`widthTracksTextView`), so the document
    /// is never wider than the clip view and the horizontal scroll offset must
    /// stay 0. AppKit's ruler re-tiling can leave the clip view scrolled by
    /// the gutter's width delta after a thickness change (opening a file, the
    /// line count gaining a digit), which renders the start of every line
    /// underneath the gutter until the user manually scrolls it back — clamp
    /// the offset instead.
    private func clampHorizontalScrollIfNeeded() {
        guard let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return }
        let clip = scrollView.contentView
        guard clip.bounds.origin.x != 0,
            documentView.frame.width <= clip.bounds.width + 0.5
        else { return }
        clip.setBoundsOrigin(NSPoint(x: 0, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Fast newline count (no offsets array); used only for thickness sizing.
    private func lineCount(in content: NSString) -> Int {
        var count = 1
        var index = 0
        while index < content.length {
            var lineEnd = 0
            content.getLineStart(
                nil, end: &lineEnd, contentsEnd: nil,
                for: NSRange(location: index, length: 0))
            if lineEnd <= index { break }
            if lineEnd < content.length { count += 1 }
            index = lineEnd
        }
        return count
    }

    @objc private func clientLayoutChanged() {
        clampHorizontalScrollIfNeeded()
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
        let content = textView.string as NSString
        rebuildLineIndexIfNeeded(content: content)

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

        var lineIndex = lineNumber(forCharacterAt: charRange.location) - 1
        while lineIndex < lineStartOffsets.count {
            let startOffset = lineStartOffsets[lineIndex]
            guard startOffset <= NSMaxRange(charRange) else { break }
            let fragmentRect: NSRect
            if startOffset >= content.length {
                // Trailing empty line (or empty buffer).
                fragmentRect = layoutManager.extraLineFragmentRect
            } else {
                let glyphIndex = layoutManager.glyphIndexForCharacter(at: startOffset)
                fragmentRect = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex, effectiveRange: nil)
            }
            let y = fragmentRect.minY + origin.y + rulerOffset.y
            let lineNumber = lineIndex + 1

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
            lineIndex += 1
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
        let content = textView.string as NSString
        rebuildLineIndexIfNeeded(content: content)
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

    /// 1-based line number of the line containing an arbitrary character
    /// offset in the client text view's CURRENT content, rebuilding the
    /// cached line-start index first if it was invalidated (e.g. by a
    /// recent edit). Used outside `draw()` — by GX1's caret-line detection
    /// (`CodeEditorView.Coordinator.scheduleInlineBlame()`) — so callers
    /// never read a stale index the way a raw `lineNumber(forCharacterAt:)`
    /// call could.
    func lineNumber(forOffset offset: Int) -> Int {
        if let content = textView?.string as NSString? {
            rebuildLineIndexIfNeeded(content: content)
        }
        return lineNumber(forCharacterAt: offset)
    }

    /// 1-based line number of the line containing `offset`.
    private func lineNumber(forCharacterAt offset: Int) -> Int {
        var low = 0
        var high = lineStartOffsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStartOffsets[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    private func rebuildLineIndexIfNeeded(content: NSString) {
        guard !lineIndexIsValid else { return }
        var offsets: [Int] = [0]
        var location = 0
        while location < content.length {
            var lineEnd = 0
            var contentsEnd = 0
            content.getLineStart(
                nil, end: &lineEnd, contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            if lineEnd >= content.length {
                // A trailing newline yields one final empty line.
                if contentsEnd < lineEnd { offsets.append(lineEnd) }
                break
            }
            offsets.append(lineEnd)
            location = lineEnd
        }
        lineStartOffsets = offsets
        lineIndexIsValid = true
    }

}
