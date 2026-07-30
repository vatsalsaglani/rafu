import Foundation
import Testing

@testable import RafuApp

@Suite("Editor tab and group presentation")
@MainActor
struct EditorTabAndGroupPresentationTests {
    @Test("The divider-aware split compensation produces one four-point band")
    func splitBandIncludesNativeDivider() {
        let nativeDividerWidth: CGFloat = 1
        let compensation = EditorGroupSplitPresentation.compensatingInset(
            nativeDividerWidth: nativeDividerWidth
        )

        #expect(compensation == 3)
        #expect(compensation + nativeDividerWidth == RafuMetrics.editorGroupGapTarget)
        #expect(
            EditorGroupSplitPresentation.compensatingInset(nativeDividerWidth: 4) == 0
        )
        #expect(
            EditorGroupSplitPresentation.compensatingInset(nativeDividerWidth: 5) == 0
        )
    }

    @Test("Every editor-owned tab route consumes the shared attached cap")
    func everyEditorTabUsesAttachedCap() throws {
        let source = try Self.editorCanvasSource()

        #expect(source.contains("private struct EditorTabItem: View"))
        #expect(source.contains("private struct EditorTerminalTabItem: View"))
        #expect(source.contains("private struct GitDiffTabItem: View"))
        #expect(source.contains("private struct GitStandaloneBlameCanvas: View"))
        #expect(
            source.components(separatedBy: "AttachedWorkbenchTab(isSelected:").count - 1
                == 4
        )
        #expect(
            source.components(separatedBy: "AttachedWorkbenchTabCloseButton(").count - 1
                == 4
        )
        #expect(source.contains("StitchedAccentEdge"))
        #expect(!source.contains("StitchedUnderline"))
    }

    @Test("Selected tabs retain attached fill, top-side outline, and no bottom edge")
    func attachedTabGeometryRemainsExact() {
        let selected = AttachedWorkbenchTabPresentation.resolve(isSelected: true)

        #expect(selected.fill == .tabActiveBackground)
        #expect(selected.outline == .borderStrong)
        #expect(selected.outlineEdges == [.top, .leading, .trailing])
        #expect(!selected.outlineEdges.contains(.bottom))
        #expect(selected.masksBottomSeam)
    }

    @Test("The full-width shelf owns an inert selected-cap seam overlay")
    func shelfOwnsSelectedSeam() throws {
        let source = try Self.editorCanvasSource()
        let shelf = try Self.section(
            named: "private struct EditorTabShelf<Content: View>",
            until: "private struct TabStripReorderDropDelegate",
            in: source
        )

        #expect(shelf.contains("SelectedEditorTabBoundsPreferenceKey"))
        #expect(shelf.contains(".overlayPreferenceValue("))
        #expect(shelf.contains("theme.palette.tabActiveBackground"))
        #expect(shelf.contains(".frame(height: RafuMetrics.hairline)"))
        #expect(shelf.contains(".allowsHitTesting(false)"))
        #expect(shelf.contains(".accessibilityHidden(true)"))
        #expect(!shelf.contains(".clipShape("))
        #expect(!shelf.contains(".mask("))
    }

    @Test("Recursive groups keep native split topology and compensate only the first leaf")
    func recursiveGroupFramingPreservesTopology() throws {
        let source = try Self.editorCanvasSource()
        let tree = try Self.section(
            named: "private struct EditorLayoutTreeView: View",
            until: "private struct EditorGroupView: View",
            in: source
        )

        #expect(tree.contains("HSplitView"))
        #expect(tree.contains("VSplitView"))
        #expect(tree.contains(".frame(minWidth: 220)"))
        #expect(tree.contains(".frame(minHeight: 150)"))
        #expect(tree.contains(".padding(.trailing, compensatingInset)"))
        #expect(tree.contains(".padding(.bottom, compensatingInset)"))
        #expect(tree.contains(".background(theme.palette.appBackground)"))
        #expect(!tree.contains(".clipShape("))
        #expect(!tree.contains(".mask("))
    }

    @Test("One group surface surrounds tab and content with one terminal perimeter")
    func groupOwnsOnlyTerminalPerimeter() throws {
        let editor = try Self.editorCanvasSource()
        let terminal = try Self.source(
            "Sources/RafuApp/Terminal/EditorTerminalTabContent.swift"
        )

        #expect(editor.components(separatedBy: "EditorGroupSurface(").count - 1 == 1)
        #expect(editor.contains("isFocused: session.isFocusedGroup(group.id)"))
        #expect(editor.contains("terminalIdentityColor: selectedTerminalIdentity?.color"))
        #expect(editor.contains("EditorTerminalTabContent(controller: terminalController)"))
        #expect(!editor.contains(".rafuTerminalSurfaceBorder("))
        #expect(!terminal.contains(".rafuTerminalSurfaceBorder("))
        #expect(!terminal.contains(".clipShape("))
        #expect(!terminal.contains(".mask("))
    }

    @Test("Background-matching terminal identity retains structure and focus")
    func matchingIdentityKeepsNeutralAndFocusedSignals() {
        let resting = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false),
            identity: .assigned(matchesEditorBackground: true),
            contrast: .normal
        )
        let focused = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true),
            identity: .assigned(matchesEditorBackground: true),
            contrast: .normal
        )

        #expect(resting.neutralStructure == .borderSubtle)
        #expect(resting.neutralWidth == 1)
        #expect(resting.showsIdentityAccent)
        #expect(focused.neutralStructure == .borderStrong)
        #expect(focused.emphasis == .editorFocus)
        #expect(focused.emphasisWidth == 2)
        #expect(focused.showsIdentityAccent)
    }

    @Test("Drag frames, drop scoping, overflow, and Markdown controls remain in place")
    func tabInteractionContractsRemain() throws {
        let source = try Self.editorCanvasSource()

        #expect(source.contains("TabStripFramePreferenceKey"))
        #expect(source.contains(#".coordinateSpace(.named(Self.coordinateSpaceName))"#))
        #expect(source.contains("TabStripReorderDropDelegate("))
        #expect(source.contains("of: [.rafuEditorDrag]"))
        #expect(source.contains("overlay(alignment: .topLeading) { insertionIndicator }"))
        #expect(source.contains("private var overflowTabMenu: some View"))
        #expect(source.contains("MarkdownModeControl("))
        #expect(source.contains("document.supportsPresentationModes"))
    }

    @Test("Tab labels and close actions expose full non-color state")
    func tabAccessibilityRemainsTextual() throws {
        let source = try Self.editorCanvasSource()

        #expect(source.contains(".help(document.displayName)"))
        #expect(source.contains(".accessibilityValue(documentTabAccessibilityValue)"))
        #expect(source.contains(#"document.isDirty ? "Unsaved changes" : nil"#))
        #expect(source.contains(".accessibilityValue(terminalTabAccessibilityValue)"))
        #expect(source.contains(#""Shell exited" : nil"#))
        #expect(source.contains(#"accessibilityLabel: "Close \(document.displayName)""#))
        #expect(source.contains(#"accessibilityLabel: "Close \(title)""#))
    }

    @Test("Tab selection and focus chrome add no decorative animation")
    func tabChromeIsImmediate() throws {
        let source = try Self.editorCanvasSource()
        let tabs = try Self.section(
            named: "private struct EditorTabItem: View",
            until: "private struct EditorDocumentView: View",
            in: source
        )

        #expect(!tabs.contains(".animation("))
        #expect(!tabs.contains("withAnimation("))
    }

    private static func editorCanvasSource() throws -> String {
        try source("Sources/RafuApp/Views/EditorCanvasView.swift")
    }

    private static func section(named start: String, until end: String, in source: String) throws
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
        throw EditorTabAndGroupPresentationError.repositoryRootNotFound
    }

    private enum EditorTabAndGroupPresentationError: Error {
        case repositoryRootNotFound
    }
}
