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
