import AppKit
import SwiftTerm
import Testing

@testable import RafuApp

/// UX Round A moved the bundled `warning` hue to orange. ANSI yellow must not
/// follow it: it derives from `git.modified` first, which keeps the terminal's
/// yellow a yellow in both bundled themes.
@MainActor
struct TerminalAnsiPaletteTests {
    private func components(_ hex: String) -> (UInt16, UInt16, UInt16) {
        let color = NSColor(rafuHex: hex).usingColorSpace(.sRGB) ?? .black
        return (
            UInt16(max(0, min(1, color.redComponent)) * 65535),
            UInt16(max(0, min(1, color.greenComponent)) * 65535),
            UInt16(max(0, min(1, color.blueComponent)) * 65535)
        )
    }

    private func expectYellow(_ theme: RafuTheme, equals hex: String) {
        let palette = WorkspaceTerminalController.ansiPalette(for: theme)
        #expect(palette.count == 16)
        let expected = components(hex)
        for index in [3, 11] {
            let color = palette[index]
            #expect(color.red == expected.0, "\(theme.name) ANSI \(index) red")
            #expect(color.green == expected.1, "\(theme.name) ANSI \(index) green")
            #expect(color.blue == expected.2, "\(theme.name) ANSI \(index) blue")
        }
    }

    @Test("Indigo ANSI yellow is the git-modified yellow, not the new orange warning")
    func indigoYellow() {
        expectYellow(RafuThemeCatalog.indigo, equals: "#D2B958")
    }

    @Test("Khadi ANSI yellow keeps its previous value")
    func khadiYellow() {
        expectYellow(RafuThemeCatalog.khadi, equals: "#8F6A10")
    }
}
