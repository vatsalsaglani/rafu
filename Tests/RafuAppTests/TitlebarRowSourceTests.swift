import Foundation
import Testing

/// Source contracts for the round-2 workbench polish (X8). The views need a
/// window to render, so these pin the load-bearing lines that a later edit
/// could drop without any other test failing.
@Suite("Titlebar row and tab strip source contracts")
struct TitlebarRowSourceTests {
    @Test("The titlebar row is a drag surface with the system double-click action")
    func titlebarDragAndDoubleClick() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceTitlebarRow.swift")
        #expect(source.contains("struct WindowTitlebarRow: View"))
        #expect(source.contains("nonisolated static let height: CGFloat = 28"))
        #expect(source.contains(".gesture(WindowDragGesture())"))
        #expect(source.contains("TapGesture(count: 2)"))
        #expect(source.contains("TitlebarDoubleClickAction.current()"))
        #expect(source.contains("window.performZoom(nil)"))
        #expect(source.contains("window.performMiniaturize(nil)"))
        // The sidebar toggle stays, with its menu and accessibility paths.
        #expect(source.contains("Button(\"Toggle Sidebar\", systemImage: \"sidebar.left\")"))
        #expect(source.contains(".accessibilityLabel(\"Toggle Sidebar\")"))
    }

    @Test("The workspace title is a menu with recents, Open Folder, and Reveal in Finder")
    func titlebarWorkspaceMenu() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceTitlebarRow.swift")
        #expect(source.contains("Button(\"Open Folder…\""))
        #expect(source.contains("Button(\"Reveal in Finder\""))
        #expect(source.contains("activateFileViewerSelecting"))
        #expect(source.contains(".menuStyle(.borderlessButton)"))
        // A native menu must not inherit the gold tint.
        #expect(source.contains(".tint(theme.palette.textSecondary)"))
        // Vendor SVGs render 1 x 1 pt in an NSMenu, so no agent mark may sit
        // inside the menu body.
        let menu = try Self.section(
            of: source, from: "private var workspaceMenu", to: "private var otherRecents")
        #expect(!menu.contains("AgentIconView"))
    }

    @Test("The titlebar shows the branch and a words-first agent capsule")
    func titlebarBranchAndActivity() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceTitlebarRow.swift")
        #expect(source.contains("StatusBarBranchFormatter.present(snapshot)"))
        #expect(source.contains("AgentActivitySummary(sessions: session.terminal.sessions)"))
        #expect(source.contains("summary.label"))
        #expect(source.contains("session.showCommandPalette(seed: \"\")"))
    }

    @Test("The old titlebar row no longer lives in the navigator file")
    func navigatorFileHasNoTitlebarRow() throws {
        let navigator = try Self.source("Sources/RafuApp/Views/WorkspaceNavigatorView.swift")
        #expect(!navigator.contains("struct WindowTitlebarRow"))
    }

    @Test("The tab strip drop target covers the whole strip and the group keeps tab drags")
    func tabStripAndGroupDropTargets() throws {
        let canvas = try Self.source("Sources/RafuApp/Views/EditorCanvasView.swift")
        #expect(canvas.contains(".frame(minWidth: stripViewportWidth, alignment: .leading)"))
        #expect(canvas.contains("? [.rafuEditorDrag, .fileURL] : [.rafuEditorDrag]"))
        #expect(canvas.contains("canvasIsVisible: selectedCanvas != nil"))
        #expect(canvas.contains("EditorDropRouting.groupAccepts("))
        let boardDrop = try Self.source("Sources/RafuApp/Canvas/Views/CanvasFileDropDelegate.swift")
        // The board owns every drag over it and forwards tab edges to the group.
        #expect(boardDrop.contains("case .tab? = session.activeEditorDrag"))
        #expect(boardDrop.contains("session.dropEditorTabOnCanvas("))
    }

    @Test("Agent marks reach editor tabs, the Terminals panel, the palette, and the status bar")
    func agentIdentityIsUsedEverywhere() throws {
        let canvas = try Self.source("Sources/RafuApp/Views/EditorCanvasView.swift")
        #expect(canvas.contains("AgentIconView(cli: provider, size: 13)"))
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        #expect(panel.contains("AgentIconView(cli: row.id, size: 16)"))
        let palette = try Self.source("Sources/RafuApp/Views/CommandPaletteView.swift")
        #expect(palette.contains("AgentIconView(cli: agent, size: 16)"))
        #expect(palette.contains("agent: option.id"))
        let status = try Self.source("Sources/RafuApp/Views/WorkspaceStatusBar.swift")
        #expect(status.contains("AgentIconView(cli: cli, size: 13)"))
    }

    private static func section(of source: String, from start: String, to end: String) throws
        -> String
    {
        guard let lower = source.range(of: start),
            let upper = source.range(of: end, range: lower.upperBound..<source.endIndex)
        else { throw SourceContractError.sectionNotFound(start) }
        return String(source[lower.lowerBound..<upper.lowerBound])
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(
                    contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw SourceContractError.repositoryRootNotFound
    }
}

private enum SourceContractError: Error {
    case repositoryRootNotFound
    case sectionNotFound(String)
}
