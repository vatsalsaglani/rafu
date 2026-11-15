import Foundation
import Testing

@testable import RafuApp

/// The sidebar redesign: the sidebar is one quiet surface. Text and space make
/// the structure; fills are for state (hover, selection, a field), never for
/// decoration, and no control block has a divider under it. These source
/// contracts keep the four panels from growing their slabs and lines back.
@Suite("Sidebar panel redesign contract")
struct SidebarPanelRedesignTests {
    @Test("The one segmented control has no outer border and a non-colour selection")
    func segmentedControlLook() throws {
        let controls = try Self.source("Sources/RafuApp/Support/RafuControlStyles.swift")
        let picker = try Self.section(
            of: controls, from: "struct RafuSegmentedPicker<Item: Hashable>: View",
            to: "extension View {\n    /// Keeps a segment label on one line")
        #expect(picker.contains(".fill(theme.palette.chipBackground)"))
        #expect(picker.contains(".fill(theme.palette.selection)"))
        #expect(!picker.contains(".strokeBorder(theme.palette.borderSubtle)"))
        #expect(!picker.contains("appBackground"))
        // Selection is also weight and a trait; Increase Contrast adds a line.
        #expect(picker.contains("weight: isSelected ? .semibold : .regular"))
        #expect(picker.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(picker.contains("contrast == .increased"))
        // Words first; icons only when the words do not fit.
        #expect(picker.contains("ViewThatFits(in: .horizontal)"))
        #expect(picker.contains(".accessibilityLabel(label)"))
    }

    @Test("Source Control has no slab, no private picker, and an overflow menu")
    func sourceControlPanel() throws {
        let source = try Self.source("Sources/RafuApp/Views/GitInspectorView.swift")
        #expect(!source.contains("GitSectionPicker"))
        let context = try Self.section(
            of: source, from: "private var repositoryContext: some View",
            to: "/// One branch pull-down")
        #expect(!context.contains("elevatedBackground"))
        #expect(!context.contains("RafuMetrics.hairline"))
        #expect(context.contains(".padding(.horizontal, RafuMetrics.sidebarTextInset)"))
        let overflow = try Self.section(
            of: source, from: "private var overflowMenu: some View",
            to: "private var changesViewModeBinding")
        #expect(overflow.contains("RafuPanelHeaderOverflowMenu("))
        #expect(overflow.contains("Button(\"Stash Changes…\", systemImage: \"archivebox\")"))
        #expect(overflow.contains("Picker(\"View as\""))
        // The sync control's counts are its label; no second Refresh glyph.
        #expect(!source.contains("arrow.triangle.2.circlepath"))
        // Section headers carry plain counts, not "Staged (2)".
        #expect(!source.contains("Section(\"Staged ("))
        #expect(source.contains("RafuSidebarSectionHeader("))
    }

    @Test("Search has a full-width field, header actions, and no divider")
    func searchPanel() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let header = try Self.section(
            of: source, from: "private struct WorkspaceSearchHeaderActions: View",
            to: "nonisolated enum SearchFileFilterDisclosure")
        #expect(header.contains("Label(\"Recent Searches\", systemImage: \"clock\")"))
        #expect(header.contains("systemImage: \"arrow.left.arrow.right\""))
        #expect(header.contains("RafuIconButtonStyle(isActive: search.isReplacePresented"))
        let content = try Self.section(
            of: source, from: "private struct WorkspaceSearchContent: View",
            to: "@ViewBuilder\n    private var searchResults: some View")
        #expect(!content.contains("Divider()"))
        #expect(!content.contains("Button(\"Search\", systemImage: \"magnifyingglass\""))
        #expect(!content.contains("chevron.right"))
        #expect(content.contains(".onSubmit(performSearch)"))
        #expect(content.contains(".padding(.horizontal, RafuMetrics.sidebarTextInset)"))
    }

    @Test("History has no divider under its controls")
    func historyPanel() throws {
        let source = try Self.source("Sources/RafuApp/AgentHistory/AgentHistoryPanelView.swift")
        let content = try Self.section(
            of: source, from: "private struct AgentHistoryPanelContent: View",
            to: "@ViewBuilder\n    private var results: some View")
        #expect(!content.contains("Divider()"))
        #expect(source.contains("RafuSegmentedPicker("))
        #expect(source.contains(".padding(.horizontal, RafuMetrics.sidebarTextInset)"))
    }

    @Test("Terminals: no launcher card or divider, rows keep the drag source, one pinned footer")
    func terminalsPanel() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        let body = try Self.section(
            of: panel, from: "struct WorkspaceTerminalsPanelView: View",
            to: "/// Pending rows until the probe resolves")
        #expect(!body.contains("Divider()"))
        #expect(!body.contains("AgentStartMenuView("))
        // The group row stays the Ensemble drag source.
        #expect(panel.contains(".onDrag("))
        #expect(panel.contains("CanvasBoardDragPayload(terminalGroupID: row.id)"))
        // Grip and ⋯ are overlays, not reserved width.
        #expect(panel.contains(".overlay(alignment: .trailing)"))
        #expect(panel.contains(".overlay(alignment: .leading)"))
        // Inline rename stays on every row type.
        #expect(panel.contains("TextField(\"Group name\""))
        #expect(panel.contains("TextField(\"Pane name\""))
        #expect(panel.contains("TextField(\"Name\""))
        // The Saved section collapses when empty. It is a section of the
        // native list, so it scrolls with the rows and has no hairline there;
        // only with no terminals is it a pinned footer, and then the panel
        // draws the one hairline above it. The panel owns the per-window
        // choice because it also sizes that footer.
        let saved = try Self.source("Sources/RafuApp/Views/TerminalGroupSavedLayoutsSection.swift")
        #expect(!saved.contains("Divider().overlay"))
        #expect(saved.contains("TerminalGroupSavedLayoutsPresentation.isExpanded("))
        #expect(saved.contains("Section {"))
        let footer = try Self.section(
            of: panel, from: "private var savedOnlyList: some View",
            to: "private var savedSection: some View")
        #expect(footer.contains("Divider().overlay(theme.palette.borderSubtle)"))
        #expect(footer.contains("TerminalGroupSavedLayoutsPresentation.footerHeight("))
        #expect(panel.contains("@SceneStorage(\"terminals.savedGroups.expanded\")"))
    }

    @Test("Section headers are Title Case with a plain count")
    func sectionHeaderStyle() throws {
        let styles = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        let header = try Self.section(
            of: styles, from: "struct RafuSidebarSectionHeader: View",
            to: "/// Shared lower-emphasis panel state.")
        #expect(header.contains(".font(.system(size: 11, weight: .semibold))"))
        #expect(header.contains(".textCase(nil)"))
        #expect(header.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(!header.contains("RafuChip"))
        #expect(!header.contains("(\\(count))"))
    }

    static func section(of source: String, from start: String, to end: String) throws
        -> String
    {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }

    static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SourceLookupError.repositoryRootNotFound
    }

    private enum SourceLookupError: Error {
        case repositoryRootNotFound
    }
}
