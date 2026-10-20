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
        #expect(source.contains("private struct EditorTerminalGroupTabItem: View"))
        #expect(source.contains("private struct GitDiffTabItem: View"))
        #expect(source.contains("private struct GitStandaloneBlameCanvas: View"))
        #expect(
            source.components(separatedBy: "AttachedWorkbenchTab(isSelected:").count - 1
                == 5
        )
        #expect(
            source.components(separatedBy: "AttachedWorkbenchTabCloseButton(").count - 1
                == 5
        )
        // The selected tab's dashed amber top edge is gone: selection is the
        // raised fill, hairline, shadow, and the isSelected trait.
        #expect(!source.contains("StitchedAccentEdge"))
        #expect(!source.contains("StitchedUnderline"))
    }

    @Test("Selected tabs are a raised card: active-tab fill, hairline border on all four edges")
    func attachedTabGeometryRemainsExact() {
        let selected = AttachedWorkbenchTabPresentation.resolve(isSelected: true)

        #expect(selected.fill == .tabActiveBackground)
        #expect(selected.outline == .borderSubtle)
        #expect(selected.outlineEdges == [.top, .leading, .trailing, .bottom])

        let contrast = AttachedWorkbenchTabPresentation.resolve(
            isSelected: true, contrastIncreased: true)
        #expect(contrast.fill == .tabActiveBackground)
        #expect(contrast.outline == .borderStrong)
        #expect(contrast.outlineEdges == [.top, .leading, .trailing, .bottom])

        let inactive = AttachedWorkbenchTabPresentation.resolve(isSelected: false)
        #expect(inactive.fill == .clear)
        #expect(inactive.outline == .clear)
        #expect(
            AttachedWorkbenchTabPresentation.resolve(isSelected: false, contrastIncreased: true)
                == inactive)
    }

    @Test("The full-width shelf frames the floating cards; the card header has one hairline")
    func shelfFramesFloatingCards() throws {
        let source = try Self.editorCanvasSource()
        let shelf = try Self.section(
            named: "private struct EditorTabShelf<Content: View>",
            until: "private struct TabStripReorderDropDelegate",
            in: source
        )

        #expect(!shelf.contains("SelectedEditorTabBoundsPreferenceKey"))
        #expect(!shelf.contains(".overlayPreferenceValue("))
        #expect(shelf.contains("theme.palette.borderSubtle"))
        #expect(shelf.contains(".frame(height: RafuMetrics.hairline)"))
        #expect(shelf.contains(".allowsHitTesting(false)"))
        #expect(shelf.contains(".accessibilityHidden(true)"))
        #expect(shelf.contains("WorkbenchTextHeightPolicy.tabShelfHeight(forTabHeight:"))
        #expect(!shelf.contains(".clipShape("))
        #expect(!shelf.contains(".mask("))
        // The shelf is the deck card's header row in its own tone
        // (`tabBarBackground`: the card tone in Indigo, one step below it in
        // Khadi), and a fixed height so an overflowing strip cannot grow it.
        #expect(shelf.contains(".background(theme.palette.tabBarBackground)"))
        #expect(!shelf.contains(".background(theme.palette.editorBackground)"))
        #expect(shelf.contains(".frame(height: WorkbenchTextHeightPolicy.tabShelfHeight("))
        #expect(!shelf.contains("minHeight:"))
        // One hairline under the whole card header: the shelf's own hairline
        // is drawn only when no breadcrumb (which has its own) follows.
        #expect(shelf.contains("if showsBottomHairline {"))
        let bar = try Self.section(
            named: "private struct EditorGroupTabBar: View",
            until: "private struct GitStandaloneBlameCanvas: View",
            in: source
        )
        #expect(bar.contains("EditorTabShelf(showsBottomHairline: !breadcrumbFollows)"))

        let breadcrumb = try Self.source("Sources/RafuApp/Views/EditorBreadcrumbView.swift")
        #expect(breadcrumb.contains(".background(theme.palette.editorBackground)"))
        #expect(!breadcrumb.contains("tabBarBackground"))
        #expect(breadcrumb.contains(".frame(height: RafuMetrics.breadcrumbHeight)"))
        #expect(breadcrumb.contains("Divider().overlay(theme.palette.borderSubtle)"))
    }

    @Test("The tab strip keeps the selected tab visible without animation")
    func tabStripRevealsSelectedTab() throws {
        let source = try Self.editorCanvasSource()
        let bar = try Self.section(
            named: "private struct EditorGroupTabBar: View",
            until: "private struct GitStandaloneBlameCanvas: View",
            in: source
        )

        #expect(bar.contains("ScrollViewReader { proxy in"))
        #expect(bar.contains(".id(tab.id)"))
        #expect(bar.contains(".id(auxTab)"))
        #expect(bar.contains(".onChange(of: group.selectedTabID)"))
        #expect(bar.contains(".onChange(of: session.selectedAuxiliaryTab(in: group.id))"))
        #expect(bar.contains("proxy.scrollTo(target, anchor: nil)"))
        #expect(!bar.contains("withAnimation"))
        // Both fades match the shelf's own tone, and the mirrored leading
        // fade shows only once the strip is scrolled.
        #expect(
            bar.components(separatedBy: "theme.palette.tabBarBackground.opacity(0)").count - 1 == 2)
        #expect(!bar.contains("theme.palette.editorBackground.opacity(0)"))
        #expect(bar.contains(".overlay(alignment: .leading) {"))
        #expect(bar.contains("if isStripScrolledFromLeadingEdge {"))
        #expect(bar.contains(".onScrollGeometryChange(for: Bool.self)"))
        // No accent in the strip's controls: both menus draw a neutral tint,
        // and only the overflow menu shows a chevron.
        #expect(
            bar.components(separatedBy: ".tint(theme.palette.textSecondary)").count - 1 == 2)
        #expect(bar.components(separatedBy: ".menuIndicator(.hidden)").count - 1 == 2)
        #expect(bar.contains(".scrollIndicators(.never)"))
        // Design polish round 3: a trailing fade (28 pt; 48 since round 4,
        // so no sharp fragment of the next tab shows) that is also the
        // row's trailing inset (a strip scrolled to its end leaves the last
        // tab clear of it), then 8 pt before the fixed "+" so the controls
        // never sit on a faded tab.
        #expect(bar.contains("private static let trailingFadeWidth: CGFloat = 48"))
        #expect(bar.contains(".frame(width: Self.trailingFadeWidth)"))
        #expect(
            bar.contains(".contentMargins(.trailing, Self.trailingFadeWidth, for: .scrollContent)"))
        #expect(bar.contains("$0 - Self.stripMargin - Self.trailingFadeWidth"))
        let gap = try #require(bar.range(of: ".padding(.trailing, RafuMetrics.space2)"))
        let plus = try #require(bar.range(of: "                newTabMenu\n"))
        #expect(gap.lowerBound < plus.lowerBound)
        #expect(bar.contains(".background(ScrollerHidingConfigurator())"))

        let configurator = try Self.source(
            "Sources/RafuApp/Support/ScrollViewConfigurator.swift")
        #expect(configurator.contains("scrollView.scrollerStyle = .overlay"))
        #expect(configurator.contains("scrollView.hasHorizontalScroller = false"))
        #expect(configurator.contains("override func setFrameSize("))
        #expect(configurator.contains("override func viewDidMoveToWindow()"))
    }

    @Test("An Ensemble has its own glyph, distinct from a Terminal Group's, everywhere")
    func ensembleGlyphIsDistinct() throws {
        let terminalGroupSymbol = "rectangle.3.group"
        #expect(CanvasBoardState.ensembleSymbol != terminalGroupSymbol)

        let tab = try Self.source("Sources/RafuApp/Canvas/Views/CanvasEditorTabItem.swift")
        #expect(!tab.contains(terminalGroupSymbol))
        #expect(
            tab.components(separatedBy: "CanvasBoardState.ensembleSymbol").count - 1 == 2)

        let editor = try Self.editorCanvasSource()
        for line in [
            #"Button("New Ensemble", systemImage: CanvasBoardState.ensembleSymbol)"#,
            #"Button("Move to Ensemble", systemImage: CanvasBoardState.ensembleSymbol)"#,
            "systemImage: CanvasBoardState.ensembleSymbol)",
            "glyph: CanvasBoardState.ensembleSymbol,",
        ] {
            #expect(editor.contains(line))
        }
        // The Terminal Group tab and its New menu entry keep their glyph.
        #expect(
            editor.contains(#"Button("New Terminal Group", systemImage: "rectangle.3.group")"#))

        let switcher = try Self.source("Sources/RafuApp/Views/EditorTabSwitcherView.swift")
        #expect(switcher.contains("symbolName: CanvasBoardState.ensembleSymbol,"))
        let palette = try Self.source("Sources/RafuApp/Views/CommandPaletteView.swift")
        #expect(!palette.contains(#"Ensemble…", symbolName: "rectangle.3.group""#))
        #expect(
            palette.components(separatedBy: "symbolName: CanvasBoardState.ensembleSymbol").count
                - 1 == 3)
        let history = try Self.source("Sources/RafuApp/AgentHistory/AgentHistoryPanelView.swift")
        #expect(
            history.contains(
                #"Button("Resume in Ensemble", systemImage: CanvasBoardState.ensembleSymbol)"#))
        let terminals = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        let badge = try Self.section(
            named: "if row.isCanvasOwned {", until: #"accessibilityLabel("On an Ensemble")"#,
            in: terminals)
        #expect(badge.contains("CanvasBoardState.ensembleSymbol"))
    }

    @Test("Tab labels are plain content, never a Button, so a drag can start on the title")
    func tabLabelsAreNotButtons() throws {
        let source = try Self.editorCanvasSource()
        let sections = [
            try Self.section(
                named: "private struct GitDiffTabItem: View",
                until: "private struct EditorTabItem: View", in: source),
            try Self.section(
                named: "private struct EditorTabItem: View",
                until: "private func terminalAgentActivity(", in: source),
            try Self.section(
                named: "private struct EditorTerminalTabItem: View",
                until: "private struct EditorTerminalGroupTabItem: View", in: source),
            try Self.section(
                named: "private struct EditorTerminalGroupTabItem: View",
                until: "private struct EditorDocumentView: View", in: source),
            try Self.source("Sources/RafuApp/Canvas/Views/CanvasEditorTabItem.swift"),
            try Self.source("Sources/RafuApp/Views/AuxiliaryEditorTab.swift"),
        ]
        for section in sections {
            // A plain-style label button owned the mouse-down over the icon
            // and title, so `.onDrag` started only from the tab's padding.
            #expect(!section.contains(".buttonStyle(.plain)"))
            #expect(!section.contains("Button(action: select)"))
            #expect(!section.contains("} label: {"))
            #expect(!section.contains("Button(board.title)"))
            #expect(section.contains(".workbenchTabLabel("))
        }

        let styles = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        let label = try Self.section(
            named: "struct WorkbenchTabLabelAccessibility: ViewModifier",
            until: "/// Shared detached tab-card chrome", in: styles)
        #expect(label.contains(".accessibilityElement(children: .ignore)"))
        #expect(
            label.contains(
                ".accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)"))
        #expect(label.contains(".accessibilityAction { select() }"))
        #expect(!label.contains("Button("))
        // The whole card stays the single click target that selects.
        #expect(styles.contains(".onTapGesture(perform: select)"))
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
        #expect(resting.identityWidth == 2)
        #expect(resting.identityInset == 1)
        #expect(focused.neutralStructure == .borderStrong)
        #expect(focused.emphasis == .editorFocus)
        #expect(focused.emphasisWidth == 1)
        #expect(focused.showsIdentityAccent)
        #expect(focused.identityWidth == 2)
        #expect(focused.identityInset == 1)
        #expect(focused.identityAndEmphasisDoNotOverlap)
        #expect(focused.drawOrder == [.neutralStructure, .emphasis, .identity])
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
        #expect(source.contains("value: documentTabAccessibilityValue"))
        #expect(source.contains(#"document.isDirty ? "Unsaved changes" : nil"#))
        #expect(
            source.contains("value: terminalTabAccessibilityValue(status:")
        )
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
