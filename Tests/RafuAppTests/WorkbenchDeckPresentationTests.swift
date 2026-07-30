import Foundation
import Testing

@testable import RafuApp

@Suite("Workbench deck presentation")
struct WorkbenchDeckPresentationTests {
    @Test("Exactly one deck owns the editor and optional utility split")
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
            through: "Divider().overlay(theme.palette.borderSubtle)"
        )

        #expect(Self.occurrences(of: "WorkbenchDeckSurface {", in: windowContent) == 1)
        #expect(Self.occurrences(of: "HSplitView {", in: windowContent) == 2)
        #expect(Self.occurrences(of: "HSplitView {", in: deckLane) == 1)
        #expect(deckLane.contains("editorCanvas"))
        #expect(deckLane.contains("WorkspaceUtilityPanelView(session: session)"))
    }

    @Test("Files, both rails, and status remain outside the deck")
    func structuralPlaneStaysOutsideDeck() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let windowContent = try Self.section(
            in: source,
            from: "private var windowContent: some View",
            through: "private var editorCanvas: some View"
        )
        let deck = try #require(windowContent.range(of: "WorkbenchDeckSurface {"))
        let sidebarRail = try #require(windowContent.range(of: "WorkspaceSidebarRail()"))
        let files = try #require(windowContent.range(of: "WorkspaceSidebarView(session: session)"))
        let utilityRail = try #require(
            windowContent.range(of: "WorkspaceUtilityRail(session: session)")
        )
        let status = try #require(
            windowContent.range(of: "WorkspaceStatusBar(session: session)")
        )

        #expect(sidebarRail.lowerBound < deck.lowerBound)
        #expect(files.lowerBound < deck.lowerBound)
        #expect(utilityRail.lowerBound > deck.lowerBound)
        #expect(status.lowerBound > deck.lowerBound)
        #expect(RafuMetrics.statusBarHeight == 24)
    }

    @Test("The four-point inset is external and adds no content padding")
    func insetIsExternal() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        let deckLane = try Self.section(
            in: source,
            from: "WorkbenchDeckSurface {",
            through: "Divider().overlay(theme.palette.borderSubtle)"
        )
        let padding = try #require(
            deckLane.range(of: ".padding(RafuMetrics.workbenchInset)")
        )
        let backing = try #require(
            deckLane.range(of: ".background(theme.palette.appBackground)")
        )

        #expect(RafuMetrics.workbenchInset == 4)
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

        #expect(
            windowContent.contains(
                ".frame(minWidth: 200, idealWidth: 260, maxWidth: 420)"
            )
        )
        #expect(windowContent.contains(".frame(minWidth: 480, minHeight: 220)"))
        #expect(
            windowContent.contains(
                ".frame(minWidth: 250, idealWidth: 310, maxWidth: 460)"
            )
        )
        #expect(Self.occurrences(of: ".layoutPriority(1)", in: windowContent) >= 4)
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
        #expect(source.contains(".environment(\\.defaultMinListRowHeight, 22)"))
        #expect(source.contains("ForEach(session.loadedChildren[\"\"] ?? [], id: \\.id)"))
        #expect(source.contains(".dropDestination(for: URL.self)"))
        #expect(source.contains(".onCopyCommand"))
        #expect(source.contains(".onPasteCommand"))
        #expect(!source.contains("WorkbenchDeckSurface"))
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
