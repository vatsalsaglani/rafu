import AppKit
import Foundation
import Testing

@testable import RafuApp

/// Design polish round 3: a stock legacy `NSScroller` painted a neutral
/// track the full height of the editor along the deck card's trailing edge
/// (dark grey on Indigo, near-white on Khadi), which broke the card and
/// squared its rounded corners. The editor now installs a themed scroller
/// whose legacy track is the editor background.
@Suite("Editor themed scroller")
@MainActor
struct EditorThemedScrollerTests {
    @Test("The themed scroller stays compatible with overlay scrollers")
    func overlayCompatible() {
        // A drawing subclass is legacy-only by default, which would pin every
        // editor to always-visible scroll bars.
        #expect(EditorThemedScroller.isCompatibleWithOverlayScrollers)
    }

    @Test("Install and apply theme both scrollers and pick a contrasting knob")
    func installAndApply() throws {
        let scrollView = NSScrollView()
        EditorThemedScroller.install(in: scrollView)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        let vertical = try #require(scrollView.verticalScroller as? EditorThemedScroller)
        let horizontal = try #require(scrollView.horizontalScroller as? EditorThemedScroller)

        let dark = NSColor(rafuHex: RafuThemeCatalog.indigo.editor.background)
        EditorThemedScroller.apply(to: scrollView, background: dark, isDark: true)
        #expect(vertical.trackColor == dark)
        #expect(horizontal.trackColor == dark)
        #expect(scrollView.scrollerKnobStyle == .light)

        let light = NSColor(rafuHex: RafuThemeCatalog.khadi.editor.background)
        EditorThemedScroller.apply(to: scrollView, background: light, isDark: false)
        #expect(vertical.trackColor == light)
        #expect(scrollView.scrollerKnobStyle == .dark)
    }

    @Test("The color set carries the theme's appearance for the knob style")
    func colorSetCarriesAppearance() {
        #expect(EditorColorSet(theme: RafuThemeCatalog.indigo).isDark)
        #expect(!EditorColorSet(theme: RafuThemeCatalog.khadi).isDark)
    }

    @Test("The editor scroll view uses the themed scroller and never forces a style")
    func editorScrollViewUsesThemedScroller() throws {
        let editor = try Self.source("Sources/RafuApp/Editor/CodeEditorView.swift")
        let make = try Self.section(
            of: editor, from: "private func makeEditorScrollView(",
            to: "scrollView.documentView = textView")
        let install = try #require(make.range(of: "EditorThemedScroller.install(in: scrollView)"))
        let flags = try #require(make.range(of: "scrollView.hasVerticalScroller = true"))
        #expect(install.lowerBound < flags.lowerBound)
        #expect(!editor.contains("scrollerStyle = .overlay"))
        #expect(!editor.contains("scrollerStyle = .legacy"))

        let apply = try Self.section(
            of: editor, from: "func applyEditorColors(", to: "func syncGuardSuppression(")
        #expect(apply.contains("EditorThemedScroller.apply("))
        #expect(apply.contains("to: scrollView, background: background, isDark: colors.isDark)"))

        let scroller = try Self.source("Sources/RafuApp/Editor/EditorThemedScroller.swift")
        #expect(scroller.contains("final class EditorThemedScroller: NSScroller"))
        #expect(
            scroller.contains(
                "override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool)"))
        #expect(scroller.contains("guard scrollerStyle == .legacy else {"))
        #expect(scroller.contains("scrollView.scrollerKnobStyle = isDark ? .light : .dark"))
        // The fix lives on the scroller, never as a clip or mask over the
        // TextKit viewport.
        #expect(!scroller.contains(".clipShape("))
        #expect(!scroller.contains(".mask("))
    }

    private static func section(of source: String, from start: String, to end: String) throws
        -> String
    {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(
                    contentsOf: directory.appending(path: path),
                    encoding: .utf8
                )
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SourceError.repositoryRootNotFound
    }

    private enum SourceError: Error {
        case repositoryRootNotFound
    }
}
