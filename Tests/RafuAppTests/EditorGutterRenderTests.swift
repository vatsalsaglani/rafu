import AppKit
import Testing

@testable import RafuApp

/// Regression: the gutter ruler must never obscure editor text. Since
/// macOS 14 `NSView.clipsToBounds` defaults to false and AppKit passes rulers
/// a dirty rect wider than their bounds; an unclipped background fill paints
/// over the entire editor (invisible text, tabs, breadcrumbs).
@Test("Gutter ruler leaves editor glyphs visible")
@MainActor
func gutterRulerLeavesGlyphsVisible() {
    let theme = RafuThemeCatalog.indigo
    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    scrollView.drawsBackground = true
    scrollView.backgroundColor = NSColor(rafuHex: theme.editor.background)

    let textView = RafuTextView.makeTextKit1()
    textView.autoresizingMask = [.width]
    textView.textContainerInset = NSSize(width: 16, height: 14)
    textView.font = theme.resolvedEditorFont()
    textView.backgroundColor = NSColor(rafuHex: theme.editor.background)
    textView.textColor = NSColor(rafuHex: theme.editor.foreground)
    scrollView.documentView = textView

    let gutter = EditorGutterRulerView(
        scrollView: scrollView,
        textView: textView,
        style: EditorGutterStyle(theme: theme)
    )
    scrollView.verticalRulerView = gutter
    scrollView.hasVerticalRuler = true
    scrollView.rulersVisible = true

    textView.string = String(
        repeating: "let alpha = beta + gamma // marker line of source text\n",
        count: 30
    )
    gutter.invalidateLineIndex()
    scrollView.layoutSubtreeIfNeeded()
    textView.layoutManager?.ensureLayout(for: textView.textContainer!)

    guard let rep = scrollView.bitmapImageRepForCachingDisplay(in: scrollView.bounds) else {
        Issue.record("no bitmap rep")
        return
    }
    scrollView.cacheDisplay(in: scrollView.bounds, to: rep)

    let background = NSColor(rafuHex: theme.editor.background).usingColorSpace(.sRGB)!
    var glyphPixels = 0
    let startX = Int(gutter.ruleThickness) + 24
    for x in stride(from: startX, to: 780, by: 7) {
        for y in stride(from: 20, to: 580, by: 7) {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let delta =
                abs(color.redComponent - background.redComponent)
                + abs(color.greenComponent - background.greenComponent)
                + abs(color.blueComponent - background.blueComponent)
            if delta > 0.08 { glyphPixels += 1 }
        }
    }
    #expect(glyphPixels > 300, "editor glyphs must remain visible with the gutter installed")

    // The gutter must widen past the NSRulerView default (17) for real line
    // numbers, and the text view must be tiled to start at that width so
    // glyphs never render under the numbers.
    #expect(gutter.ruleThickness > 24, "gutter must size to fit line numbers")
    let textOriginX = textView.convert(NSPoint.zero, to: scrollView).x
    #expect(
        textOriginX >= gutter.ruleThickness - 0.5,
        "text view must be inset by the full gutter width, got \(textOriginX)")
}
