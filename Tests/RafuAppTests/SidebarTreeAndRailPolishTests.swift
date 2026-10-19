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
        #expect(WorkspaceFileTreeItem.rowInsets.trailing == 12)
        #expect(FileTreeMetrics.rowHeight == 26)
        #expect(FileTreeMetrics.indentStep == 14)
        #expect(FileTreeMetrics.selectionRadius == 6)
    }

    @Test("Depth defaults to the root level and is passed explicitly to rows")
    func depthIsStoredOnTheItem() {
        let suite = "dev.rafu.sidebar-depth.\(UUID().uuidString)"
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(defaultsSuiteName: suite))
        defer {
            session.descriptor = nil
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
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

    @Test("The rail opens with a hidden, non-interactive 28 pt app tile")
    func railAppTile() throws {
        #expect(RafuRailAppTile.size == 28)
        #expect(RafuRailAppTile.cornerRadius == 8)
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let tile = try Self.section(
            of: source, from: "struct RafuRailAppTile: View",
            to: "struct WorkspaceSearchNavigatorView")
        #expect(tile.contains("NSApplication.shared.applicationIconImage"))
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
    }

    @Test("The Files header puts the three creation actions in one neutral plus menu")
    func headerPlusMenu() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        let header = try Self.section(
            of: source, from: "private var sidebarHeader: some View",
            to: "/// New File, New Folder, and Add Folder to Workspace in one")
        #expect(header.contains("Button(\"Filter Files\", systemImage: \"magnifyingglass\")"))
        #expect(header.contains("newItemMenu"))
        #expect(header.contains(".padding(.top, 10)"))
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
