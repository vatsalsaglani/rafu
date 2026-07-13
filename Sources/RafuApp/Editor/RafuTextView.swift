import AppKit

/// TextKit 1 editor text view that draws Rafu's per-buffer decorations —
/// current-line highlight, indent guides, and matched-bracket boxes — in
/// `drawBackground(in:)`. Decorations never touch `NSTextStorage` attributes,
/// so the Neon syntax pipeline can re-apply storage attributes freely.
final class RafuTextView: NSTextView {
    /// Strong reference to the text storage. In a hand-built TextKit 1 stack
    /// NOTHING retains the storage (`NSLayoutManager.textStorage` is an
    /// `assign` reference and the view only retains its container), so the
    /// caller must own it or the stack reads through a dangling pointer and
    /// glyph drawing silently breaks.
    private var ownedTextStorage: NSTextStorage?

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
