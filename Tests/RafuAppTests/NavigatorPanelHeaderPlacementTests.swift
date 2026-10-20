import Foundation
import Testing

@testable import RafuApp

/// ADR 0031 §g, round 5: every navigator (rail) panel header puts its title
/// on the editor tab labels' centre line through one shared modifier. The
/// Files header was aligned by hand first while the others stayed about
/// 14 pt higher; these checks keep the panels from drifting apart again.
@Suite("Navigator panel header placement")
struct NavigatorPanelHeaderPlacementTests {
    @Test("The title centre is the deck inset plus half the tab shelf")
    func sharedMetric() {
        #expect(
            RafuMetrics.navigatorHeaderTitleCenterY
                == RafuMetrics.workbenchInset + RafuMetrics.tabShelfHeight / 2)
        #expect(RafuMetrics.navigatorHeaderTitleCenterY == 31)
        // Files (24 pt row) and the shared utility header (34 pt band).
        #expect(RafuMetrics.navigatorHeaderTopInset(rowHeight: 24) == 19)
        #expect(
            RafuMetrics.navigatorHeaderTopInset(rowHeight: RafuMetrics.sectionHeaderHeight) == 14)
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
        let modifier = try Self.section(
            of: source, from: "func rafuNavigatorHeaderPlacement(rowHeight: CGFloat)",
            to: "/// Shared one-row panel header.")
        #expect(modifier.contains("RafuMetrics.navigatorHeaderTopInset(rowHeight: rowHeight)"))
    }

    @Test(
        "Every rail panel's header uses the shared placement",
        arguments: WorkspaceNavigatorMode.allCases)
    func everyPanelUsesSharedPlacement(mode: WorkspaceNavigatorMode) throws {
        let source = try Self.source(Self.panelSourcePath(for: mode))
        let usesSharedHeader = source.contains("RafuUtilityPanelHeader(")
        let usesModifier = source.contains(".rafuNavigatorHeaderPlacement(rowHeight:")
        #expect(usesSharedHeader || usesModifier, "\(mode.title) header is not placed")
        // No panel aligns its header with its own hard-coded top padding.
        #expect(!source.contains(".padding(.top, 19)"), "\(mode.title)")
    }

    @Test("The sidebar hosts exactly these panel views for the rail modes")
    func panelHostMapping() throws {
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        let host = try Self.section(
            of: navigator, from: "private var panelContent: some View",
            to: "/// The one always-visible left icon rail")
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
        case .history: "Sources/RafuApp/AgentHistory/AgentHistoryPanelView.swift"
        }
    }

    private static func panelTypeName(for mode: WorkspaceNavigatorMode) -> String {
        switch mode {
        case .files: "WorkspaceSidebarView"
        case .search: "WorkspaceSearchNavigatorView"
        case .sourceControl: "SourceControlPanelView"
        case .terminals: "WorkspaceTerminalsPanelView"
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
