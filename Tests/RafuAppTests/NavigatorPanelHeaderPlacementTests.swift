import Foundation
import Testing

@testable import RafuApp

/// ADR 0031 §g, round 5: every navigator (rail) panel header puts its title
/// on the editor tab labels' centre line through one shared modifier. The
/// Files header was aligned by hand first while the others stayed about
/// 14 pt higher; these checks keep the panels from drifting apart again.
@Suite("Navigator panel header placement")
struct NavigatorPanelHeaderPlacementTests {
    @Test("The title centre is the deck's top inset plus half the tab shelf")
    func sharedMetric() {
        #expect(
            RafuMetrics.navigatorHeaderTitleCenterY
                == RafuMetrics.deckInsetTop + RafuMetrics.tabShelfHeight / 2)
        // Window gap tightening: the deck's top inset 12 → 6 moved the tab
        // labels up 6 pt, so the headers follow (31 → 25, inset 19 → 13);
        // window gap tightening 2: 6 → 2 (25 → 21, inset 13 → 9).
        #expect(RafuMetrics.navigatorHeaderTitleCenterY == 21)
        // Every panel, Files included, uses the one 24 pt header row.
        #expect(RafuMetrics.navigatorHeaderRowHeight == 24)
        #expect(
            RafuMetrics.navigatorHeaderTopInset(rowHeight: RafuMetrics.navigatorHeaderRowHeight)
                == 9)
        // A row taller than the line never gets a negative inset.
        #expect(RafuMetrics.navigatorHeaderTopInset(rowHeight: 80) == 0)
    }

    @Test("The shared utility header places itself with the navigator modifier")
    func utilityHeaderUsesModifier() throws {
        let source = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        let header = try Self.section(
            of: source, from: "struct RafuUtilityPanelHeader<Context: View, Actions: View>",
            to: "extension RafuUtilityPanelHeader where Context == EmptyView")
        #expect(header.contains(".rafuNavigatorHeaderPlacement(rowHeight: rowHeight)"))
        #expect(header.contains(".frame(minHeight: rowHeight)"))
        #expect(header.contains("base: RafuMetrics.navigatorHeaderRowHeight"))
        let modifier = try Self.section(
            of: source, from: "func rafuNavigatorHeaderPlacement(rowHeight: CGFloat)",
            to: "/// Shared one-row panel header.")
        #expect(modifier.contains("RafuMetrics.navigatorHeaderTopInset(rowHeight: rowHeight)"))
    }

    /// The sidebar redesign: the four panel headers had an elevated slab, a
    /// hairline, a leading icon and a close button that Files never had, so
    /// they looked foreign. The header is now the Files look for all five.
    @Test("The shared header is the quiet Files look: no slab, line, icon, or close")
    func sharedHeaderIsQuiet() throws {
        let source = try Self.source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
        let header = try Self.section(
            of: source, from: "struct RafuUtilityPanelHeader<Context: View, Actions: View>",
            to: "extension RafuUtilityPanelHeader where Context == EmptyView")
        #expect(header.contains(".font(.system(size: 13, weight: .semibold))"))
        #expect(header.contains(".truncationMode(.tail)"))
        #expect(header.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(header.contains(".padding(.horizontal, RafuMetrics.sidebarTextInset)"))
        #expect(header.contains(".background(WindowDragHandle())"))
        // Nothing painted: a translucent sidebar base must show through.
        #expect(!header.contains("elevatedBackground"))
        #expect(!header.contains("sidebarBackground"))
        #expect(!header.contains("RafuMetrics.hairline"))
        #expect(!header.contains("Rectangle()"))
        // No second sidebar toggle and no icon that repeats the rail.
        #expect(!header.contains("xmark"))
        #expect(!header.contains("onClose"))
        #expect(!header.contains("Image(systemName:"))
        #expect(RafuMetrics.sidebarTextInset == 10)
    }

    @Test(
        "Every rail panel's header is the shared header",
        arguments: WorkspaceNavigatorMode.allCases)
    func everyPanelUsesSharedHeader(mode: WorkspaceNavigatorMode) throws {
        let source = try Self.source(Self.panelSourcePath(for: mode))
        #expect(source.contains("RafuUtilityPanelHeader("), "\(mode.title) header is not shared")
        // No panel places or closes its header by hand.
        #expect(!source.contains(".padding(.top, 19)"), "\(mode.title)")
        #expect(!source.contains(".rafuNavigatorHeaderPlacement(rowHeight:"), "\(mode.title)")
        #expect(!source.contains("closeAccessibilityLabel"), "\(mode.title)")
    }

    @Test("The sidebar hosts exactly these panel views for the rail modes")
    func panelHostMapping() throws {
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let host = try Self.section(
            of: navigator, from: "private var panelContent: some View",
            to: "/// The rail and the sidebar pane as one unit")
        for mode in WorkspaceNavigatorMode.allCases {
            #expect(host.contains("\(Self.panelTypeName(for: mode))(session: session)"))
        }
    }

    /// Exhaustive on purpose: a new rail mode fails to compile here until
    /// its panel is added to the placement checks.
    private static func panelSourcePath(for mode: WorkspaceNavigatorMode) -> String {
        switch mode {
        case .files: "Sources/RafuApp/Views/WorkspaceSidebarView.swift"
        case .search: "Sources/RafuApp/Views/WorkspaceNavigatorView.swift"
        case .sourceControl: "Sources/RafuApp/Views/GitInspectorView.swift"
        case .terminals: "Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift"
        case .ensemble: "Sources/RafuApp/Canvas/Views/CanvasNavigatorPanelView.swift"
        case .history: "Sources/RafuApp/AgentHistory/AgentHistoryPanelView.swift"
        }
    }

    private static func panelTypeName(for mode: WorkspaceNavigatorMode) -> String {
        switch mode {
        case .files: "WorkspaceSidebarView"
        case .search: "WorkspaceSearchNavigatorView"
        case .sourceControl: "SourceControlPanelView"
        case .terminals: "WorkspaceTerminalsPanelView"
        case .ensemble: "CanvasNavigatorPanelView"
        case .history: "AgentHistoryPanelView"
        }
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
