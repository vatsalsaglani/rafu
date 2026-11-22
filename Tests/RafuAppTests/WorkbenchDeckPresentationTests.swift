import Foundation
import SwiftUI
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
            through: ".rafuFrameSurface(.app)"
        )

        #expect(Self.occurrences(of: "WorkbenchDeckSurface {", in: windowContent) == 1)
        // No outer HSplitView: `WorkbenchSplitHandle` is the explicit
        // boundary between the left sidebar pane and the deck lane, inside
        // a plain HStack. The deck itself still owns no inner split: there
        // is no right panel for it to host.
        #expect(!windowContent.contains("HSplitView {"))
        let flatContent = windowContent.split(whereSeparator: \.isWhitespace).joined(
            separator: " ")
        #expect(
            flatContent.contains(
                "WorkbenchSplitHandle(session: session, hitAreaWidth: hitArea.width, edge: sidebarEdge)"
            ))
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
        // The rail and sidebar travel as one `navigatorColumn`, placed before
        // the deck on the leading edge and after it on the trailing edge. The
        // column itself holds the rail and the sidebar pane.
        let leadingColumn = try #require(
            windowContent.range(of: "if sidebarEdge == .leading {\n")
        )
        let trailingColumn = try #require(
            windowContent.range(of: "if sidebarEdge == .trailing {\n")
        )
        let deck = try #require(windowContent.range(of: "WorkbenchDeckSurface {"))
        let status = try #require(
            windowContent.range(of: "WorkspaceStatusBar(session: session)")
        )
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let column = try Self.section(
            in: navigator, from: "struct WorkbenchNavigatorColumn: View",
            through: "struct WorkspaceActivityRail: View")
        #expect(column.contains("WorkspaceActivityRail("))
        #expect(column.contains("WorkspaceSidebarPanelView(session: session)"))
        #expect(!windowContent.contains("WorkspaceActivityRail("))

        #expect(leadingColumn.lowerBound < deck.lowerBound)
        #expect(trailingColumn.lowerBound > deck.lowerBound)
        #expect(status.lowerBound > deck.lowerBound)
        #expect(RafuMetrics.statusBarHeight == 24)
    }

    @Test("The deck inset is external and adds no content padding")
    func insetIsExternal() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let deckLane = try Self.section(
            in: source,
            from: "WorkbenchDeckSurface {",
            through: ".rafuFrameSurface(.app)"
        )
        let padding = try #require(
            deckLane.range(of: "WorkbenchDeckLane.padding(")
        )
        let backing = try #require(
            deckLane.range(of: ".rafuFrameSurface(.app)")
        )

        // Design polish round 2: 8 → 10 so the stronger deck shadow fits;
        // round 4: 10 → 12 for the deeper shadow; window gap tightening:
        // per edge, top 6, leading 6, trailing 8, bottom 12; window gap
        // tightening 2: top 2, leading 8 (the handle no longer adds 10).
        #expect(
            WorkbenchDeckLane.insets
                == EdgeInsets(top: 2, leading: 8, bottom: 12, trailing: 8))
        #expect(deckLane.contains("isSidebarCollapsed: session.isSidebarCollapsed"))
        #expect(deckLane.contains("railDeckSideInset: WorkspaceActivityRail.deckSideInset"))
        #expect(Self.occurrences(of: ".padding(", in: deckLane) == 2)
        #expect(padding.lowerBound < backing.lowerBound)
    }

    @Test("The split handle is an overlay on the seam and takes no layout width")
    func handleIsAnOverlay() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let workbench = try Self.section(
            in: source,
            from: "private var workbenchContent: some View",
            through: "private var editorCanvas: some View"
        )
        let flat = workbench.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Not an HStack child between the sidebar and the deck any more.
        let row = try Self.section(
            in: workbench, from: "HStack(spacing: 0) {", through: "WorkbenchDeckSurface {")
        #expect(!row.contains("WorkbenchSplitHandle("))
        // One `.app` frame fill under the whole row, then the handle overlay.
        #expect(
            flat.contains(
                ".overlay(alignment: sidebarEdge.seamOverlayAlignment) { sidebarSplitHandle }"))
        let fill = try #require(workbench.range(of: ".rafuFrameSurface(.app)"))
        let overlay = try #require(workbench.range(of: "{ sidebarSplitHandle }"))
        #expect(fill.lowerBound < overlay.lowerBound)
        #expect(
            flat.contains(".offset(x: sidebarEdge.seamOffset(distance: paneEdge + hitArea.x))"))
    }

    @Test("Seam gaps: 5 pt beside a collapsed sidebar's rail, 8 pt beside an open one")
    func seamGapMath() {
        let strip = WorkspaceActivityRail.deckSideInset
        let insets = WorkbenchDeckLane.insets

        // Open: the gutter alone is the sidebar-to-card gap (8; was the
        // handle's 10 + leading 6 = 16).
        let open = WorkbenchDeckLane.padding(isSidebarCollapsed: false, railDeckSideInset: strip)
        #expect(open == insets)
        #expect(open.leading == 8)

        // Collapsed: rail strip 3 + padding 2 = 5 from the icons' trailing
        // edge to the card (was 3 + the handle's 10 = 13). The other edges
        // do not change.
        let collapsed = WorkbenchDeckLane.padding(
            isSidebarCollapsed: true, railDeckSideInset: strip)
        #expect(collapsed.leading == 2)
        #expect(strip + collapsed.leading == RafuMetrics.deckGapCollapsedRail)
        #expect(collapsed.top == insets.top)
        #expect(collapsed.bottom == insets.bottom)
        #expect(collapsed.trailing == insets.trailing)
        // A strip wider than the gap never yields negative padding.
        #expect(
            WorkbenchDeckLane.padding(isSidebarCollapsed: true, railDeckSideInset: 9).leading
                == 0)

        // Hit area, measured from the leading pane's trailing edge.
        // Open: sidebar edge → 3 pt into the card (0…11), not over the
        // sidebar's scroller.
        let openHit = WorkbenchDeckLane.handleHitArea(
            isSidebarCollapsed: false, railDeckSideInset: strip)
        #expect(openHit == .init(x: 0, width: 11))
        // Collapsed: rail icons' edge → 3 pt into the card (-3…5), never
        // over an icon; still grabbable while the visible gap is 5 pt.
        let collapsedHit = WorkbenchDeckLane.handleHitArea(
            isSidebarCollapsed: true, railDeckSideInset: strip)
        #expect(collapsedHit == .init(x: -3, width: 8))
        #expect(collapsedHit.x == -strip)
        #expect(
            collapsedHit.x + collapsedHit.width
                == collapsed.leading + WorkbenchDeckLane.handleDeckOverlap)
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
        // (Alignment and clipping of that frame: see
        // `sidebarContentStaysInsideItsPane`.)
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        #expect(navigator.contains("width: WorkbenchSidebarResize.clamp(session.sidebarWidth)"))
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

        #expect(source.contains(".rafuFrameSurface(.sidebar)"))
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

        // The rail and the sidebar pane travel together as `navigatorColumn`.
        // The rail is never gated on `isSidebarCollapsed` — only Zen mode
        // hides it — while the sidebar pane also follows the collapse bit.
        #expect(windowContent.contains("navigatorColumn"))
        let column = try Self.section(
            in: rail, from: "struct WorkbenchNavigatorColumn: View",
            through: "struct WorkspaceActivityRail: View")
        #expect(column.contains("if session.showsNavigatorRail"))
        #expect(column.contains("if session.showsSidebarPane"))
        #expect(!column.contains("session.isSidebarCollapsed"))
        let railBody = try Self.section(
            in: rail,
            from: "struct WorkspaceActivityRail: View",
            through: "private func railButton"
        )
        #expect(!railBody.contains("if !session.isSidebarCollapsed"))
        #expect(rail.contains("ForEach(WorkspaceNavigatorMode.allCases, id: \\.self)"))
        #expect(
            WorkspaceNavigatorMode.allCases == [
                .files, .search, .sourceControl, .terminals, .ensemble, .history, .meetings,
            ])
    }

    @Test("Sidebar content cannot spill over the Activity Rail")
    func sidebarContentStaysInsideItsPane() throws {
        let window = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let workbench = try Self.section(
            in: window,
            from: "private var workbenchContent: some View",
            through: "private var editorCanvas: some View"
        )
        // Collapse whitespace so the assertions survive formatter wrapping.
        let flat = workbench.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // A fixed width frame centres an over-wide child over the rail, so
        // the pane aligns toward the rail (leading on the leading edge,
        // trailing on the trailing edge) and clips to its own rect.
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let flatNavigator = navigator.split(whereSeparator: \.isWhitespace).joined(
            separator: " ")
        #expect(
            flatNavigator.contains(
                "WorkbenchSidebarResize.clamp(session.sidebarWidth), alignment: edge.frameAlignment )"
                    + " .clipped()"))
        #expect(flat.contains("alignment: sidebarEdge.seamOverlayAlignment"))

        // No navigator-hosted panel may demand more than the sidebar minimum.
        let git = try Self.source("Sources/RafuApp/Views/GitInspectorView.swift")
        #expect(!git.contains("frame(minWidth: 300"))
        #expect(WorkbenchSidebarResize.minimumWidth == 220)
    }

    @Test("Ensemble cards past the board edge cannot take sidebar or tab bar clicks")
    func boardHitTestingStaysInsideItsFrame() throws {
        // `clipped()` clips drawing, not hit testing: the board must also
        // declare its content shape, and the rail and sidebar must sit above
        // the deck so an overflowing card never wins their clicks.
        let canvas = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        let layers = try Self.section(
            in: canvas,
            from: "private func boardLayers(",
            through: "private func boardChrome("
        )
        let flatLayers = layers.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flatLayers.contains(".clipped() .contentShape(.rect) }"))

        let window = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let workbench = try Self.section(
            in: window,
            from: "private var workbenchContent: some View",
            through: "WorkbenchDeckSurface {"
        )
        // The rail and sidebar are one column, kept above the deck.
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let column = try Self.section(
            in: navigator, from: "struct WorkbenchNavigatorColumn: View",
            through: "struct WorkspaceActivityRail: View")
        let flatColumn = column.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        #expect(flatColumn.contains(".frame(maxHeight: .infinity) .zIndex(1)"))
        #expect(workbench.contains("navigatorColumn"))
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
