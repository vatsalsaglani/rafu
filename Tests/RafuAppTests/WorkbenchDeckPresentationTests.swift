import Foundation
import Testing

@testable import RafuApp

@Suite("Workbench deck presentation")
struct WorkbenchDeckPresentationTests {
    @Test("Exactly one deck surface hosts the editor alone")
    func oneDeckOwnsInnerSplit() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let windowContent = try Self.section(
            in: source,
            from: "private var windowContent: some View",
            through: "private var editorCanvas: some View"
        )
        let deckLane = try Self.section(
            in: windowContent,
            from: "WorkbenchDeckSurface {",
            through: ".background(theme.palette.appBackground)"
        )

        #expect(Self.occurrences(of: "WorkbenchDeckSurface {", in: windowContent) == 1)
        // No outer HSplitView: `WorkbenchSplitHandle` is the explicit
        // boundary between the left sidebar pane and the deck lane, inside
        // a plain HStack. The deck itself still owns no inner split: there
        // is no right panel for it to host.
        #expect(!windowContent.contains("HSplitView {"))
        #expect(windowContent.contains("WorkbenchSplitHandle(session: session)"))
        #expect(deckLane.contains("editorCanvas"))
        #expect(!deckLane.contains("WorkspaceUtilityPanelView"))
    }

    @Test("The Activity Rail, sidebar, and status remain outside the deck")
    func structuralPlaneStaysOutsideDeck() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let windowContent = try Self.section(
            in: source,
            from: "private var windowContent: some View",
            through: "private var editorCanvas: some View"
        )
        let rail = try #require(
            windowContent.range(of: "WorkspaceActivityRail(session: session)")
        )
        let deck = try #require(windowContent.range(of: "WorkbenchDeckSurface {"))
        let sidebar = try #require(
            windowContent.range(of: "WorkspaceSidebarPanelView(session: session)")
        )
        let status = try #require(
            windowContent.range(of: "WorkspaceStatusBar(session: session)")
        )

        #expect(rail.lowerBound < deck.lowerBound)
        #expect(sidebar.lowerBound < deck.lowerBound)
        #expect(status.lowerBound > deck.lowerBound)
        #expect(RafuMetrics.statusBarHeight == 24)
    }

    @Test("The four-point inset is external and adds no content padding")
    func insetIsExternal() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let deckLane = try Self.section(
            in: source,
            from: "WorkbenchDeckSurface {",
            through: ".background(theme.palette.appBackground)"
        )
        let padding = try #require(
            deckLane.range(of: ".padding(RafuMetrics.workbenchInset)")
        )
        let backing = try #require(
            deckLane.range(of: ".background(theme.palette.appBackground)")
        )

        #expect(RafuMetrics.workbenchInset == 8)
        #expect(Self.occurrences(of: ".padding(", in: deckLane) == 1)
        #expect(padding.lowerBound < backing.lowerBound)
    }

    @Test("Native split geometry and interaction modifiers stay authoritative")
    func nativeSplitContract() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let windowContent = try Self.section(
            in: source,
            from: "private var windowContent: some View",
            through: "private var editorCanvas: some View"
        )

        // The sidebar's width is explicit session state clamped by
        // `WorkbenchSidebarResize` (min 220, ideal 300, max 560 — grown from
        // the Files-only 200/260/420 to fit Search and Source Control,
        // which were authored for the former 300-520 right panel), not a
        // split view's own min/ideal/max frame triplet.
        #expect(
            windowContent.contains(
                ".frame(width: WorkbenchSidebarResize.clamp(session.sidebarWidth))"
            )
        )
        #expect(WorkbenchSidebarResize.minimumWidth == 220)
        #expect(WorkbenchSidebarResize.idealWidth == 300)
        #expect(WorkbenchSidebarResize.maximumWidth == 560)
        #expect(windowContent.contains(".frame(minWidth: 472, minHeight: 220)"))
        #expect(!windowContent.contains("WorkspaceUtilityPanelView"))
        #expect(Self.occurrences(of: ".layoutPriority(1)", in: windowContent) >= 2)
        #expect(!windowContent.contains(".shadow("))
        #expect(!windowContent.contains(".blur("))
        #expect(!windowContent.contains(".material"))
        #expect(!windowContent.contains(".mask("))
        #expect(!windowContent.contains(".clipShape("))
    }

    @Test("Files remains an unrounded source-list leaf")
    func filesLeafStaysFlat() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")

        #expect(source.contains(".background(theme.palette.sidebarBackground)"))
        #expect(source.contains(".listStyle(.plain)"))
        #expect(
            source.contains(".environment(\\.defaultMinListRowHeight, FileTreeMetrics.rowHeight)"))
        #expect(FileTreeMetrics.rowHeight == 26)
        #expect(source.contains("ForEach(session.loadedChildren[\"\"] ?? [], id: \\.id)"))
        #expect(source.contains(".dropDestination(for: URL.self)"))
        #expect(source.contains(".onCopyCommand"))
        #expect(source.contains(".onPasteCommand"))
        #expect(!source.contains("WorkbenchDeckSurface"))
    }

    @Test("The left Activity Rail hosts every navigator mode outside the deck")
    func leftActivityRailHostsEveryMode() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let windowContent = try Self.section(
            in: source,
            from: "private var windowContent: some View",
            through: "private var editorCanvas: some View"
        )
        let rail = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")

        #expect(windowContent.contains("WorkspaceActivityRail(session: session)"))
        // The rail is a sibling of the sidebar pane and `WorkbenchSplitHandle`
        // in the explicit HStack, and is never gated on `isSidebarCollapsed`
        // — only the sidebar pane is.
        #expect(Self.occurrences(of: "if !session.isSidebarCollapsed", in: windowContent) == 1)
        let railBody = try Self.section(
            in: rail,
            from: "struct WorkspaceActivityRail: View",
            through: "private func railButton"
        )
        #expect(!railBody.contains("if !session.isSidebarCollapsed"))
        #expect(rail.contains("ForEach(WorkspaceNavigatorMode.allCases, id: \\.self)"))
        #expect(
            WorkspaceNavigatorMode.allCases == [
                .files, .search, .sourceControl, .terminals, .history,
            ])
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private static func section(
        in source: String,
        from start: String,
        through end: String
    ) throws -> String {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.upperBound])
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
        throw WorkbenchDeckPresentationTestError.repositoryRootNotFound
    }

    private enum WorkbenchDeckPresentationTestError: Error {
        case repositoryRootNotFound
    }
}
