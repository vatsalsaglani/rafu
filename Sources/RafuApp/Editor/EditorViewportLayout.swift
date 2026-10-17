import AppKit
import OSLog

/// Counts app requests, not the extra work TextKit can choose to perform.
/// No source text, file identity, or document paths enter telemetry.
final class EditorViewportLayoutMetrics {
    private(set) var viewportRequests = 0
    private(set) var characterGeometryRequests = 0
    private(set) var rejectedGeometryRequests = 0
    private(set) var lastCharacterRange: NSRange?

    func reset() {
        viewportRequests = 0
        characterGeometryRequests = 0
        rejectedGeometryRequests = 0
        lastCharacterRange = nil
    }

    fileprivate func requestedViewport() { viewportRequests += 1 }
    fileprivate func rejectedGeometry() { rejectedGeometryRequests += 1 }
    fileprivate func requestedGeometry(_ range: NSRange) {
        characterGeometryRequests += 1
        lastCharacterRange = range
    }
}

/// A single-pass TextKit 1 viewport. Never retain this across storage, font,
/// container, or scroll changes. A fresh pass uses the current layout state.
struct EditorViewportLayout {
    private static let signposter = OSSignposter(
        subsystem: "dev.vatsalsaglani.rafu", category: "editor-layout")

    let characterRange: NSRange
    let viewRect: NSRect
    let origin: NSPoint
    private let glyphRange: NSRange
    private let contentLength: Int
    private let lineHeight: CGFloat
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private let metrics: EditorViewportLayoutMetrics

    init?(textView: NSTextView, rect: NSRect, metrics: EditorViewportLayoutMetrics) {
        guard !textView.isHiddenOrHasHiddenAncestor,
            let layoutManager = textView.layoutManager,
            let textContainer = textView.textContainer
        else { return nil }
        let viewRect = rect.intersection(textView.visibleRect)
        guard !viewRect.isEmpty else { return nil }
        self.viewRect = viewRect
        origin = textView.textContainerOrigin
        self.layoutManager = layoutManager
        self.textContainer = textContainer
        self.metrics = metrics
        contentLength = textView.textStorage?.length ?? 0
        lineHeight = layoutManager.defaultLineHeight(
            for: textView.font
                ?? .monospacedSystemFont(
                    ofSize: NSFont.systemFontSize, weight: .regular))
        let containerRect = viewRect.offsetBy(dx: -origin.x, dy: -origin.y)
        metrics.requestedViewport()
        let interval = Self.signposter.beginInterval("ViewportLayout")
        layoutManager.ensureLayout(forBoundingRect: containerRect, in: textContainer)
        Self.signposter.endInterval("ViewportLayout", interval)
        glyphRange = layoutManager.glyphRange(
            forBoundingRectWithoutAdditionalLayout: containerRect, in: textContainer)
        characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange, actualGlyphRange: nil)
    }

    func containsInsertion(at location: Int) -> Bool {
        guard location >= 0, location <= contentLength else { return false }
        if location < contentLength { return NSLocationInRange(location, characterRange) }
        if let extra = extraLineRect { return extra.intersects(viewRect) }
        return characterRange.length > 0 && NSMaxRange(characterRange) == contentLength
    }

    /// Reject first, then translate only the visible UTF-16 intersection.
    /// TextKit can expand a character range for a surrogate pair or ligature;
    /// intersect the resulting glyph range with the viewport again.
    private func visibleGlyphs(for range: NSRange) -> NSRange? {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
            range.location <= contentLength, range.length <= contentLength - range.location
        else {
            metrics.rejectedGeometry()
            return nil
        }
        let visible = NSIntersectionRange(range, characterRange)
        guard visible.length > 0 else {
            metrics.rejectedGeometry()
            return nil
        }
        metrics.requestedGeometry(visible)
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: visible, actualCharacterRange: nil)
        let clipped = NSIntersectionRange(glyphs, glyphRange)
        return clipped.length > 0 ? clipped : nil
    }

    func boundingRect(for range: NSRange) -> NSRect? {
        guard let glyphs = visibleGlyphs(for: range) else { return nil }
        let interval = Self.signposter.beginInterval("VisibleGeometry")
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        Self.signposter.endInterval("VisibleGeometry", interval)
        return rect.offsetBy(dx: origin.x, dy: origin.y)
    }

    private var extraLineRect: NSRect? {
        if layoutManager.extraLineFragmentTextContainer === textContainer,
            layoutManager.extraLineFragmentRect.height > 0
        {
            return layoutManager.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
        }
        // Empty storage can have no generated extra fragment yet. No glyph
        // lookup is needed to place its sole insertion point.
        guard contentLength == 0 else { return nil }
        return NSRect(
            x: origin.x + textContainer.lineFragmentPadding, y: origin.y,
            width: 1, height: lineHeight)
    }

    func caretRect(at location: Int) -> NSRect? {
        guard containsInsertion(at: location) else {
            metrics.rejectedGeometry()
            return nil
        }
        var rect: NSRect
        if location == contentLength, let extra = extraLineRect {
            rect = extra
        } else if location < contentLength {
            guard let glyphRect = boundingRect(for: NSRange(location: location, length: 1)) else {
                return nil
            }
            rect = glyphRect
        } else if contentLength > 0 {
            guard
                let glyphRect = boundingRect(
                    for: NSRange(location: contentLength - 1, length: 1))
            else { return nil }
            rect = glyphRect
            rect.origin.x = glyphRect.maxX
        } else {
            return nil
        }
        rect.size.width = 1
        rect.size.height = max(lineHeight, rect.height)
        guard rect.height > 0, rect.intersects(viewRect) else { return nil }
        return rect
    }

    /// Use the final visual fragment, not the union of all wrapped fragments.
    /// A line whose end is offscreen has no visible blame annotation.
    func lineEndRect(for range: NSRange) -> NSRect? {
        guard range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= contentLength, range.length <= contentLength - range.location
        else {
            metrics.rejectedGeometry()
            return nil
        }
        if range.length == 0 { return caretRect(at: range.location) }
        guard
            let glyphs = visibleGlyphs(
                for: NSRange(location: NSMaxRange(range) - 1, length: 1))
        else { return nil }
        let interval = Self.signposter.beginInterval("VisibleGeometry")
        let rect = layoutManager.lineFragmentUsedRect(
            forGlyphAt: glyphs.location, effectiveRange: nil
        )
        .offsetBy(dx: origin.x, dy: origin.y)
        Self.signposter.endInterval("VisibleGeometry", interval)
        return rect.height > 0 && rect.intersects(viewRect) ? rect : nil
    }
}
