import AppKit

/// Pre-resolved `NSColor`s for the AppKit editor decorations (gutter, current
/// line, indent guides, bracket match, find highlights, Git strips). Fallbacks
/// mirror `RafuThemePalette` so optional tokens degrade to the same colors the
/// SwiftUI chrome uses.
extension RafuTheme {
    var editorLineHighlightColor: NSColor {
        NSColor(rafuHex: editor.lineHighlight)
    }

    var editorGutterBackgroundColor: NSColor {
        NSColor(rafuHex: editor.gutterBackground ?? editor.background)
    }

    var editorGutterForegroundColor: NSColor {
        NSColor(rafuHex: editor.gutterForeground ?? ui.textMuted ?? ui.textSecondary)
    }

    var editorGutterActiveForegroundColor: NSColor {
        NSColor(rafuHex: editor.gutterActiveForeground ?? ui.textSecondary)
    }

    var editorIndentGuideColor: NSColor {
        NSColor(rafuHex: editor.indentGuide ?? ui.borderSubtle)
    }

    var editorMatchingBracketBorderColor: NSColor {
        NSColor(rafuHex: editor.matchingBracketBorder ?? ui.accent)
    }

    var editorFindMatchBackgroundColor: NSColor {
        NSColor(rafuHex: editor.findMatchBackground ?? ui.accent + "3D")
    }

    var editorFindMatchActiveBackgroundColor: NSColor {
        NSColor(rafuHex: editor.findMatchActiveBackground ?? ui.accent + "66")
    }

    /// `nil` when the theme declares no explicit ruler border; the gutter
    /// then draws no separator line.
    var editorRulerBorderColor: NSColor? {
        editor.rulerBorder.map { NSColor(rafuHex: $0) }
    }

    var gitGutterAddedColor: NSColor {
        NSColor(rafuHex: git?.added ?? ui.success ?? "#7CC08A")
    }

    var gitGutterModifiedColor: NSColor {
        NSColor(rafuHex: git?.modified ?? ui.warning ?? "#D4A24E")
    }

    var gitGutterDeletedColor: NSColor {
        NSColor(rafuHex: git?.deleted ?? ui.error ?? "#E06C75")
    }

    /// GX1 inline-blame ghost-text color — the same `textMuted` token the
    /// SwiftUI chrome uses, so the annotation reads as quiet metadata rather
    /// than a competing accent.
    var editorInlineBlameColor: NSColor {
        NSColor(rafuHex: ui.textMuted ?? ui.textSecondary)
    }
}

/// The editor's theme-derived AppKit colors, compared by their resolved hex
/// so `CodeEditorView.Coordinator.applyEditorColors` can skip AppKit entirely
/// when the theme has not changed. Hex comparison rather than `NSColor`
/// equality: `NSColor(rafuHex:)` round trips are not guaranteed to compare
/// equal across colorspace representations, which would silently defeat the
/// guard.
nonisolated struct EditorColorSet: Equatable, Sendable {
    let background: String
    let foreground: String
    let cursor: String
    /// Picks the scroller knob style (light knob on a dark theme).
    let isDark: Bool
    /// The editor base's alpha: 1, or the frosted deck's content opacity
    /// (`WindowSurfacePreference.Resolved.contentOpacity`).
    let backgroundAlpha: Double

    init(theme: RafuTheme, backgroundAlpha: Double = 1) {
        background = theme.editor.background
        foreground = theme.editor.foreground
        cursor = theme.editor.cursor
        isDark = theme.isDark
        self.backgroundAlpha = min(1, max(0, backgroundAlpha))
    }

    /// Frosted: the editor's base paints at an alpha below 1.
    var isTranslucent: Bool { backgroundAlpha < 1 }

    /// The scroll view's (clip view's) background: the one translucent base
    /// under the whole viewport, including below the last line.
    var scrollBackground: NSColor {
        let color = NSColor(rafuHex: background)
        return isTranslucent ? color.withAlphaComponent(CGFloat(backgroundAlpha)) : color
    }

    /// The text view's own background. Translucent: clear, so it does not
    /// stack on the scroll view's base. `drawsBackground` stays on, because
    /// the text view draws the current line, indent guides and bracket
    /// borders in `drawBackground(in:)`; those keep their theme colours.
    var textBackground: NSColor {
        isTranslucent ? .clear : NSColor(rafuHex: background)
    }
}
