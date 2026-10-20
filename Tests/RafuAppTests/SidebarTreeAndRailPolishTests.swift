import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// Design polish round 2: the Files tree's tight chevron and indent guides,
/// the rail's app tile, and the Files header's single `plus` menu.
@MainActor
@Suite("Sidebar tree and rail polish")
struct SidebarTreeAndRailPolishTests {
    @Test("Tree geometry: tight leading inset, 26 pt rows, 14 pt indent, radius 6")
    func treeGeometry() {
        #expect(WorkspaceFileTreeItem.rowInsets.leading == 4)
        #expect(WorkspaceFileTreeItem.rowInsets.top == 0)
        #expect(WorkspaceFileTreeItem.rowInsets.bottom == 0)
        #expect(WorkspaceFileTreeItem.rowInsets.trailing == 8)
        #expect(FileTreeMetrics.iconSlot == 16)
        #expect(FileTreeMetrics.iconLabelGap == 4)
        #expect(FileTreeMetrics.rowHeight == 26)
        #expect(FileTreeMetrics.indentStep == 14)
        #expect(FileTreeMetrics.selectionRadius == 6)
    }

    @Test("Depth defaults to the root level and is passed explicitly to rows")
    func depthIsStoredOnTheItem() {
        let suite = TestDefaultsSuite.name("dev.rafu.sidebar-depth")
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(defaultsSuiteName: suite))
        defer {
            session.descriptor = nil
            TestDefaultsSuite.remove(suite)
        }
        let node = WorkspaceFileNode(
            url: URL(filePath: "/tmp/depth/notes.txt"), relativePath: "a/b/notes.txt",
            isDirectory: false)

        let root = WorkspaceFileTreeItem(
            session: session, node: node, renameNode: .constant(nil), renameText: .constant(""))
        let nested = WorkspaceFileTreeItem(
            session: session, node: node, renameNode: .constant(nil), renameText: .constant(""),
            depth: 3)

        // The relative path has two slashes; depth is never derived from it.
        #expect(root.depth == 0)
        #expect(nested.depth == 3)
    }

    @Test("Depth flows down the recursion and the item never parses paths")
    func depthFlowsThroughRecursion() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        let item = try Self.section(
            of: source, from: "struct WorkspaceFileTreeItem: View",
            to: "private struct FileCreationSheet")
        #expect(item.contains("depth: depth + 1"))
        #expect(item.contains("FileTreePlaceholderRow(depth: depth + 1)"))
        #expect(item.contains("depth: depth,"))
        for parse in ["split(separator", "components(separatedBy", "pathComponents", "\"/\""] {
            #expect(!item.contains(parse), Comment(rawValue: parse))
        }
        let row = try Self.section(
            of: source, from: "private struct FileTreeRow: View", to: "private var nameColor")
        #expect(!row.contains("relativePath.split"))
        #expect(!row.contains("pathComponents"))
    }

    @Test("Folders use the flat disclosure style and keep keyboard and VoiceOver paths")
    func folderDisclosureContract() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        #expect(source.contains(".disclosureGroupStyle(RafuFileTreeDisclosureStyle())"))
        #expect(source.contains("struct RafuFileTreeDisclosureStyle: DisclosureGroupStyle"))
        // Lazy loading still starts from the group's expansion binding, with
        // the placeholder as a fallback for off-screen expansion.
        #expect(source.contains(".onChange(of: expandedBinding.wrappedValue, initial: true)"))
        #expect(source.contains(".onAppear { loadChildren() }"))
        // The chevron: 9 pt, muted, no motion under Reduce Motion.
        #expect(source.contains("Image(systemName: \"chevron.right\")"))
        #expect(source.contains(".font(.system(size: 9, weight: .semibold))"))
        #expect(source.contains(".foregroundStyle(theme.palette.textMuted)"))
        #expect(source.contains("reduceMotion ? nil : RafuMotion.pressRelease"))
        // Guides: borderSubtle, with borderStrong beside the selected child.
        #expect(source.contains("? theme.palette.borderStrong : theme.palette.borderSubtle"))
        // Folder rows announce and toggle their expansion state.
        #expect(source.contains(".accessibilityValue(isExpanded ? \"Expanded\" : \"Collapsed\")"))
        #expect(source.contains(".accessibilityAction { toggleExpansion() }"))
        #expect(source.contains(".onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow])"))
        // Selection stays drawn per row, never through `List(selection:)`.
        #expect(!source.contains("List(selection: $"))
    }

    @Test("The rail opens with a hidden, non-interactive 28 pt themed app tile")
    func railAppTile() throws {
        #expect(RafuRailAppTile.size == 28)
        #expect(RafuRailAppTile.cornerRadius == 8)
        #expect(RafuRailAppTile.glyphSize == 16)
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let tile = try Self.section(
            of: source, from: "struct RafuRailAppTile: View",
            to: "struct WorkspaceSearchNavigatorView")
        // Design polish round 3: a theme-coloured tile (selected-tab fill,
        // hairline) holding the seam glyph in textPrimary, not the dark
        // bundle icon, so it belongs to both the Khadi and Indigo frames.
        #expect(!tile.contains("applicationIconImage"))
        #expect(tile.contains(".fill(theme.palette.tabActiveBackground)"))
        #expect(tile.contains(".strokeBorder(theme.palette.borderSubtle, lineWidth: 1)"))
        #expect(tile.contains("RafuSeamGlyph.Panes()"))
        #expect(tile.contains("RafuSeamGlyph.Thread()"))
        #expect(tile.contains("theme.palette.textPrimary"))
        #expect(!tile.contains(".clipShape("))
        #expect(tile.contains(".accessibilityHidden(true)"))
        #expect(tile.contains(".allowsHitTesting(false)"))
        #expect(!tile.contains("Button("))

        let rail = try Self.section(
            of: source, from: "struct WorkspaceActivityRail: View", to: "private func railButton")
        let tileCall = try #require(rail.range(of: "RafuRailAppTile()"))
        let modes = try #require(rail.range(of: "ForEach(WorkspaceNavigatorMode.allCases"))
        #expect(tileCall.lowerBound < modes.lowerBound)
        #expect(rail.contains("VStack(spacing: 6)"))
        #expect(rail.contains(".padding(.top, 10)"))
        // Clicks on the tile fall through to the rail's window-drag handle.
        let railBody = try Self.section(
            of: source, from: "struct WorkspaceActivityRail: View", to: "struct RafuRailAppTile")
        #expect(railBody.contains(".background(WindowDragHandle())"))
    }

    @Test("The seam glyph keeps the app icon's proportions centred in its box")
    func seamGlyphGeometry() {
        let rect = CGRect(x: 0, y: 0, width: 16, height: 16)
        let panes = RafuSeamGlyph.Panes().path(in: rect).boundingRect
        // 320 × 307 scaled to a 16 pt width, centred vertically.
        #expect(abs(panes.width - 16) < 0.01)
        #expect(abs(panes.height - 16 * 307 / 320) < 0.01)
        #expect(abs(panes.midX - 8) < 0.01)
        #expect(abs(panes.midY - 8) < 0.01)
        let thread = RafuSeamGlyph.Thread().path(in: rect).boundingRect
        #expect(rect.contains(thread))
        #expect(thread.minX > panes.minX)
        #expect(thread.maxX < panes.maxX)
    }

    @Test("Tree names start at one x per depth and the List's scroller is overlay-style")
    func treeIconSlotAndOverlayScroller() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        let row = try Self.section(
            of: source, from: "private struct FileTreeRow: View", to: "private var nameColor")
        #expect(row.contains(".frame(width: FileTreeMetrics.iconSlot)"))
        #expect(row.contains(".padding(.leading, FileTreeMetrics.iconLabelGap)"))
        #expect(!row.contains(".padding(.leading, 2)"))

        // The SF Symbol branch has a fixed box like the asset branch, so its
        // intrinsic glyph width never moves the label beside it.
        let icons = try Self.source("Sources/RafuApp/Support/FileIconProvider.swift")
        let symbol = try Self.section(
            of: icons, from: "Image(systemName: icon.symbol)", to: "private func template")
        #expect(symbol.contains(".frame(width: size, height: size)"))

        // Per scroll view, never global: the sidebar List's own scroll view.
        #expect(
            source.contains(
                ".background(OverlayScrollerConfigurator(knobStyle: theme.isDark ? .light : .dark))"
            ))
        let configurator = try Self.source("Sources/RafuApp/Support/ScrollViewConfigurator.swift")
        #expect(!configurator.contains("NSScroller.preferredScrollerStyle ="))
        let probe = try Self.section(
            of: configurator, from: "final class OverlayScrollerProbeView",
            to: "/// Only writes a property that differs, so a re-apply from `layout()` never")
        // Overlay style, but the vertical scroller stays enabled.
        #expect(probe.contains("scrollView.scrollerStyle = .overlay"))
        #expect(!probe.contains("hasVerticalScroller = false"))
        #expect(probe.contains("NSScroller.preferredScrollerStyleDidChangeNotification"))
    }

    @Test("The Files header puts the three creation actions in one neutral plus menu")
    func headerPlusMenu() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        let header = try Self.section(
            of: source, from: "private var sidebarHeader: some View",
            to: "/// New File, New Folder, and Add Folder to Workspace in one")
        #expect(header.contains("Button(\"Filter Files\", systemImage: \"magnifyingglass\")"))
        #expect(header.contains("newItemMenu"))
        #expect(header.contains(".padding(.top, 19)"))
        #expect(header.contains(".padding(.bottom, 8)"))
        #expect(header.contains(".background(WindowDragHandle())"))
        #expect(!header.contains("Button(\"New"))
        #expect(!header.contains("New Folder"))
        #expect(!header.contains("requestAddFolder"))

        let menu = try Self.section(
            of: source, from: "private var newItemMenu: some View",
            to: "private var workspaceTitle")
        #expect(menu.contains("Menu {"))
        #expect(menu.contains("Label(\"New\", systemImage: \"plus\")"))
        #expect(menu.contains("session.requestFileCreation(isDirectory: false)"))
        #expect(menu.contains("session.requestFileCreation(isDirectory: true)"))
        #expect(menu.contains("session.requestAddFolder()"))
        #expect(menu.contains(".help(\"New File\")"))
        #expect(menu.contains(".help(\"New Folder\")"))
        #expect(menu.contains(".help(\"Add Folder to Workspace…\")"))
        #expect(menu.contains(".accessibilityLabel(\"Add Folder to Workspace\")"))
        #expect(menu.contains(".disabled(session.rootURL == nil)"))
        #expect(menu.contains(".buttonStyle(RafuIconButtonStyle(size: 24))"))
        #expect(menu.contains(".tint(theme.palette.textSecondary)"))
        #expect(!menu.contains("palette.accent"))
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
