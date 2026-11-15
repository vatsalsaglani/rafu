import Foundation
import Testing

/// Source contracts for the frosted deck (ADR 0038, steps 2 and 3): the deck
/// shadow is cast only outside the card, Solid keeps its opaque fills, every
/// Ensemble node kind shares the one card fill, and the editor and terminal
/// read the window surface from the environment.
@Suite("Frosted deck source contracts")
struct FrostedDeckContractTests {
    @Test("The deck shadow is a ring outside the card; the corner wedges still match it")
    func deckShadowIsOutsideOnly() throws {
        let source = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        let shape = try Self.section(
            of: source, from: "private struct WorkbenchDeckShadowShape: View",
            to: "private struct WorkbenchDeckCornerWedges: View")
        #expect(shape.contains(".rafuShadowOutsideOnly("))
        #expect(shape.contains("static let shadowReach ="))
        // Solid keeps the unmasked shape: the ring is Frosted-only.
        #expect(shape.contains("isActive: windowSurface.isFrosted"))
        // The helper masks with the even-odd rect-minus-outline shape, grown
        // past the frame so the shadow is never cropped.
        let helper = try Self.section(
            of: source, from: "private struct ShadowOutsideOnlyModifier: ViewModifier",
            to: "private nonisolated struct ShadowRingMaskShape: Shape")
        #expect(helper.contains("if isActive {"))
        #expect(helper.contains("ShadowRingMaskShape(inset: reach, radius: cornerRadius)"))
        #expect(helper.contains(".fill(style: FillStyle(eoFill: true))"))
        #expect(helper.contains(".padding(-reach)"))
        let ring = try Self.section(
            of: source, from: "private nonisolated struct ShadowRingMaskShape: Shape",
            to: "/// The four corner regions between")
        #expect(ring.contains("path.addRect(rect)"))
        #expect(ring.contains("rect.insetBy(dx: inset, dy: inset)"))
        // One shape, drawn behind the card and inside the wedges.
        let deck = try Self.section(
            of: source, from: "struct WorkbenchDeckSurface<Content: View>",
            to: "private struct WorkbenchDeckShadowShape: View")
        #expect(
            deck.contains(
                "WorkbenchDeckShadowShape(fill: theme.palette.editorBackground, shadow: shadowColor)"
            ))
        let wedges = try Self.section(
            of: source, from: "private struct WorkbenchDeckCornerWedges: View",
            to: "private struct WorkbenchDeckTopHighlight: View")
        #expect(wedges.contains("WorkbenchDeckShadowShape(fill: fill, shadow: shadow)"))
        // The ring masks only the shadow decoration, never content.
        #expect(!deck.contains(".mask"))
        #expect(!source.contains(".clipShape("))
    }

    @Test("Solid keeps every opaque fill; Frosted paints per region")
    func solidPathUnchanged() throws {
        let source = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        let deck = try Self.section(
            of: source, from: "struct WorkbenchDeckSurface<Content: View>",
            to: "private struct WorkbenchDeckShadowShape: View")
        #expect(
            deck.contains(
                ".background(windowSurface.isFrosted ? Color.clear : theme.palette.editorBackground)"
            ))
        #expect(deck.contains(": theme.palette.appBackground,"))
        let group = try Self.section(
            of: source, from: "struct EditorGroupSurface<Content: View>",
            to: "/// Shared one-row panel header.")
        #expect(group.contains(".rafuDeckFill(theme.palette.editorBackground, .underlay)"))
        #expect(group.contains(": theme.palette.appBackground"))

        // The fill helper returns the colour unchanged when it paints at 1,
        // which every layer but `frostedBase` does in Solid.
        let backdrop = try Self.source("Sources/RafuApp/Views/WindowFrostBackdrop.swift")
        #expect(backdrop.contains("return opacity == 1 ? color : color.opacity(opacity)"))
        let preference = try Self.source(
            "Sources/RafuApp/Settings/WindowSurfacePreference.swift")
        #expect(
            preference.contains("guard let frost else { return layer == .frostedBase ? 0 : 1 }"))
        // The window still resolves per window and injects one environment
        // value; the welcome window stays Solid.
        let window = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        #expect(window.contains("frostsContent: windowSurfaceFrostsContent,"))
        #expect(window.contains("guard !showsWelcome else { return .solid }"))
    }

    @Test("Deck regions paint through rafuDeckFill, so no two translucent fills stack")
    func deckRegionsUseTheSharedFill() throws {
        let expectations: [(String, String)] = [
            (
                "Sources/RafuApp/Views/EditorCanvasView.swift",
                ".rafuDeckFill(theme.palette.tabBarBackground, .deck)"
            ),
            (
                "Sources/RafuApp/Views/EditorCanvasView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, rootFillLayer)"
            ),
            (
                "Sources/RafuApp/Views/EditorBreadcrumbView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .deck)"
            ),
            (
                "Sources/RafuApp/Views/GitDiffCanvasView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .content)"
            ),
            (
                "Sources/RafuApp/Markdown/MarkdownPreviewView.swift",
                ".rafuDeckFill(Color(rafuHex: theme.editor.background), .content)"
            ),
            (
                "Sources/RafuApp/Views/ImagePreviewView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .content)"
            ),
            (
                "Sources/RafuApp/Views/VideoPreviewView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .content)"
            ),
            (
                "Sources/RafuApp/Terminal/EditorTerminalTabContent.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .underlay)"
            ),
            (
                "Sources/RafuApp/Terminal/TerminalGroupView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .underlay)"
            ),
            (
                "Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift",
                ".rafuDeckFill(theme.palette.editorBackground, .deck)"
            ),
        ]
        for (path, needle) in expectations {
            let source = try Self.source(path)
            #expect(source.contains(needle), "\(path) lacks \(needle)")
            #expect(
                !source.contains(".background(theme.palette.editorBackground)"),
                "\(path) paints editorBackground directly")
        }
    }

    @Test("Every Ensemble node kind uses the shell's one card fill")
    func nodeKindsShareTheCardFill() throws {
        let shell = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCardViews.swift")
        #expect(
            shell.contains(
                ".background(windowSurface.fill(theme.palette.elevatedBackground, .boardCard))"))
        #expect(!shell.contains(".background(theme.palette.elevatedBackground)"))
        // The face resolves as Solid inside the opaque card.
        #expect(shell.contains(".environment(\\.rafuWindowSurface, .solid)"))

        // Kind faces paint no second full fill: read faces step aside
        // (`underlay`), editor-like faces follow the content switch.
        let faces: [(String, String)] = [
            ("Sources/RafuApp/Canvas/Adapters/CanvasNoteCard.swift", ".underlay)"),
            ("Sources/RafuApp/Canvas/Adapters/CanvasMarkdownFileCard.swift", ".underlay)"),
            ("Sources/RafuApp/Canvas/Views/CanvasNoteCommands.swift", ".underlay)"),
            ("Sources/RafuApp/Canvas/GeneratedView/GeneratedViewCard.swift", ".underlay)"),
            ("Sources/RafuApp/Canvas/Adapters/CanvasMermaidCard.swift", ".cardContent)"),
            ("Sources/RafuApp/Canvas/Adapters/CanvasNoteEditor.swift", ".cardContent))"),
            ("Sources/RafuApp/Canvas/Adapters/CanvasTerminalCard.swift", ".cardContent)"),
        ]
        for (path, needle) in faces {
            let source = try Self.source(path)
            #expect(source.contains(needle), "\(path) lacks \(needle)")
            #expect(!source.contains(".background(theme.palette.editorBackground)"), "\(path)")
            #expect(!source.contains(".background(jsonTheme.color.surface)"), "\(path)")
        }

        // Board chrome floats opaque, like the cards it lies over.
        let chrome = [
            "Sources/RafuApp/Canvas/Views/CanvasBar.swift",
            "Sources/RafuApp/Canvas/Views/CanvasBoardNoticeView.swift",
            "Sources/RafuApp/Canvas/Views/CanvasMinimapView.swift",
            "Sources/RafuApp/Canvas/Views/CanvasEdgeLayer.swift",
            "Sources/RafuApp/Canvas/Views/CanvasSessionLinksBar.swift",
            "Sources/RafuApp/Canvas/Views/CanvasBoardSilhouetteView.swift",
            "Sources/RafuApp/Canvas/Whiteboard/CanvasToolPalette.swift",
        ]
        for path in chrome {
            let source = try Self.source(path)
            #expect(source.contains("theme.palette.elevatedBackground, .boardCard"), "\(path)")
            #expect(!source.contains("fill(theme.palette.elevatedBackground))"), "\(path)")
            #expect(
                !source.contains(".background(theme.palette.elevatedBackground, in:"), "\(path)")
        }
    }

    @Test("Editor and terminal read the window surface from the environment, guarded")
    func contentReadsTheSurface() throws {
        let editor = try Self.source("Sources/RafuApp/Editor/CodeEditorView.swift")
        #expect(
            editor.contains(
                "coordinator.backgroundAlpha = context.environment.rafuWindowSurface.contentOpacity"
            ))
        #expect(
            editor.contains(
                "let colors = EditorColorSet(theme: theme, backgroundAlpha: backgroundAlpha)"))
        // Still guarded: no AppKit write unless the colour set changed.
        #expect(editor.contains("guard appliedEditorColors != colors else { return false }"))
        #expect(editor.contains("textView.backgroundColor = colors.textBackground"))

        let host = try Self.source("Sources/RafuApp/Terminal/EditorTerminalTabContent.swift")
        #expect(host.contains("WindowSurfacePreference.terminalBackgroundAlpha("))
        #expect(host.contains("context.environment.rafuWindowSurface)"))
        #expect(host.contains("makeOrReuseView(theme: theme, backgroundAlpha: alpha)"))

        let controller = try Self.source(
            "Sources/RafuApp/Terminal/WorkspaceTerminalController.swift")
        // The signature includes the alpha, so a repeat update is a no-op.
        #expect(controller.contains("|\\(backgroundAlpha)\""))
        #expect(controller.contains("guard signature != appliedStyleSignature else { return }"))
    }

    @Test("Settings offers the content switch, disabled when Solid or forced Solid")
    func settingsSwitch() throws {
        let section = try Self.source(
            "Sources/RafuApp/Settings/WindowSurfaceSettingsSection.swift")
        #expect(
            section.contains("Toggle(\"Frost the editor and terminals\", isOn: $frostsContent)"))
        #expect(
            section.contains(
                "@AppStorage(WindowSurfacePreference.frostContentKey) private var frostsContent = true"
            ))
        let toggle = try Self.section(
            of: section, from: "Toggle(\"Frost the editor and terminals\"", to: "} header: {")
        #expect(toggle.contains(".disabled(!isFrostedSelected || forcedSolidReason != nil)"))
    }

    @Test("Card faces keep a frosted base from going grey, and the header button never wraps")
    func cardFaceHardening() throws {
        // A clip view drawing a clear colour paints it over an opaque grey.
        let note = try Self.source("Sources/RafuApp/Canvas/Adapters/CanvasNoteEditor.swift")
        #expect(note.contains("buffer.scrollView.drawsBackground = opaque"))
        #expect(note.contains("buffer.textView.drawsBackground = opaque"))

        let chrome = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCardChrome.swift")
        let button = try Self.section(
            of: chrome, from: "struct CanvasReturnToBoardButton", to: "struct CanvasHeaderBadge")
        #expect(button.contains("ViewThatFits(in: .horizontal)"))
        #expect(button.contains(".lineLimit(1)"))

        // The margin strip fills only its own bounds, never the dirty rect.
        let terminal = try Self.source("Sources/RafuApp/Terminal/RafuTerminalView.swift")
        #expect(!terminal.contains("dirtyRect.fill()"))
        #expect(terminal.contains("bounds.intersection(dirtyRect)"))
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
                    contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
