import Foundation
import Testing

@testable import RafuApp

@Suite("Utility panel presentation")
struct UtilityPanelPresentationTests {
    @Test("Search filters default closed and become mandatory when either field has content")
    func searchFilterDisclosureContract() {
        #expect(
            !SearchFileFilterDisclosure.requiresExpandedFilters(
                includePattern: "",
                excludePattern: ""
            )
        )
        #expect(
            SearchFileFilterDisclosure.requiresExpandedFilters(
                includePattern: "*.swift",
                excludePattern: ""
            )
        )
        #expect(
            SearchFileFilterDisclosure.requiresExpandedFilters(
                includePattern: "",
                excludePattern: "Tests/**"
            )
        )
    }

    @Test("Utility host is solid, headerless, top pinned, and routes Source Control uniformly")
    func utilityHostAndRailContract() throws {
        let navigator = try Self.source(
            "Sources/RafuApp/Views/WorkspaceNavigatorView.swift"
        )
        let sharedStyles = try Self.source(
            "Sources/RafuApp/Support/RafuWorkbenchStyles.swift"
        )

        #expect(!navigator.contains("private var panelHeader"))
        #expect(!navigator.contains("sidebarBackground.opacity(0.92)"))
        #expect(navigator.contains(".background(theme.palette.elevatedBackground)"))
        #expect(navigator.contains("SourceControlPanelView(session: session)"))
        #expect(
            navigator.components(separatedBy: "RafuUtilityPanelHeader(").count - 1 == 1
        )
        #expect(
            navigator.components(separatedBy: "RafuRailButtonStyle(").count - 1 >= 2
        )
        #expect(
            navigator.contains(
                ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"
            )
        )
        #expect(
            sharedStyles.contains(
                ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)"
            )
        )
    }

    @Test(
        "Search uses one concrete header, labelled options, disclosure, and actionless empty state")
    func searchHierarchyContract() throws {
        let navigator = try Self.source(
            "Sources/RafuApp/Views/WorkspaceNavigatorView.swift"
        )

        #expect(navigator.contains("title: \"Search\""))
        #expect(navigator.contains("DisclosureGroup(\"File filters\""))
        #expect(navigator.contains("\"Case\", accessibilityLabel: \"Case Sensitive\""))
        #expect(navigator.contains("\"Regex\", accessibilityLabel: \"Regular Expression\""))
        #expect(navigator.contains("RafuPanelEmptyState("))
        #expect(navigator.contains("title: \"Search Workspace\""))
    }

    @Test("Source Control owns both repository states and keeps the dense Git body")
    func sourceControlStateAndDensityContract() throws {
        let source = try Self.source("Sources/RafuApp/Views/GitInspectorView.swift")
        let wrapperStart = try #require(source.range(of: "struct SourceControlPanelView"))
        let inspectorStart = try #require(source.range(of: "struct GitInspectorView"))
        let wrapper = String(source[wrapperStart.lowerBound..<inspectorStart.lowerBound])
        let inspector = String(source[inspectorStart.lowerBound...])

        #expect(wrapper.components(separatedBy: "RafuUtilityPanelHeader(").count - 1 == 1)
        #expect(wrapper.contains("title: \"Source Control\""))
        #expect(wrapper.contains("if session.gitSnapshot != nil"))
        #expect(wrapper.contains("title: \"No Git Repository\""))
        #expect(wrapper.contains("Button(\"Initialize Repository\")"))
        #expect(wrapper.contains(".buttonStyle(RafuProminentButtonStyle())"))
        #expect(wrapper.contains("private var repositoryContext"))

        #expect(inspector.contains("title: \"No Changes\""))
        #expect(!inspector.contains("Button(\"Initialize Repository\")"))
        #expect(inspector.contains("switch session.gitInspectorSection"))
        #expect(inspector.contains("case .changes:"))
        #expect(inspector.contains("case .worktrees:"))
        #expect(inspector.contains("case .history:"))
        #expect(inspector.contains(".frame(minHeight: 40)"))
        #expect(inspector.contains("RafuMetrics.radiusDenseCard"))
        #expect(inspector.contains(".padding(RafuMetrics.utilityBodyInset)"))
        #expect(inspector.contains(".frame(maxWidth: .infinity, alignment: .leading)"))
    }

    @Test("Branch picker remains native, bounded, and exposes full names")
    func branchPopoverSourceContract() throws {
        let dropdown = try Self.source(
            "Sources/RafuApp/Support/RafuSearchableDropdown.swift"
        )
        let git = try Self.source("Sources/RafuApp/Views/GitInspectorView.swift")
        let status = try Self.source("Sources/RafuApp/Views/WorkspaceStatusBar.swift")

        #expect(dropdown.contains(".popover(isPresented: $isPresented, arrowEdge: .bottom)"))
        #expect(dropdown.contains("RafuMetrics.radiusTransientPopover"))
        #expect(dropdown.contains("RafuDropdownRowPresentation.resolve("))
        #expect(dropdown.contains(".help(text(item))"))
        #expect(dropdown.contains(".truncationMode(.middle)"))
        #expect(git.contains(".help(\"Switch branches — \\(snapshot.branch)\")"))
        #expect(status.contains("\"Current branch \\(presentation.label) — switch branches\""))
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
        throw UtilityPanelPresentationTestError.repositoryRootNotFound
    }

    private enum UtilityPanelPresentationTestError: Error {
        case repositoryRootNotFound
    }
}
