import Foundation
import Testing

@testable import RafuApp

/// WP-B: the Ensemble bar and the Terminals panel redesign. Source-level
/// contracts only; no view is instantiated.
@Suite("Ensemble bar redesign")
struct EnsembleBarRedesignTests {
    @Test("The board is the only Ensemble surface; VoiceOver keeps a card list")
    func boardOnlySurface() throws {
        #expect(!Self.exists("Sources/RafuApp/Canvas/Views/CanvasListView.swift"))
        let canvas = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        #expect(!canvas.contains("CanvasListView("))
        // The rotor replaces the List's enumerable path through the cards.
        #expect(canvas.contains(".accessibilityRotor(\"Cards\")"))
        #expect(canvas.contains(".accessibilityRotorEntry(id: card.id, in: cardRotorNamespace)"))
        // UX Round A: an empty board shows seeds on the board, not a tip panel.
        #expect(canvas.contains("CanvasSeedLayer(board: board, session: session"))
        #expect(!canvas.contains("emptyBoardTip"))
        #expect(!canvas.contains("canvasEmptyBoardTipDismissed"))
        #expect(CanvasBoardState.ensembleSymbol == "circle.hexagongrid")
        let bar = try Self.source("Sources/RafuApp/Canvas/Views/CanvasBar.swift")
        #expect(!bar.contains("CanvasModeControl"))
        let commands = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCommands.swift")
        #expect(!commands.contains("Button(\"List\")"))
        let palette = try Self.source("Sources/RafuApp/Views/CommandPaletteView.swift")
        #expect(!palette.contains("Ensemble: Show List"))
    }

    @Test("The bar's + and the board's double-click open the same Add palette")
    func addPaletteSharedByBothPaths() throws {
        let add = try Self.source("Sources/RafuApp/Canvas/Views/CanvasAddMenu.swift")
        let canvas = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        #expect(
            add.contains(
                "CanvasAddPopover(\n                board: board, session: session, boardPoint: nil,"
            ))
        #expect(canvas.contains("CanvasAddPopover("))
        #expect(canvas.contains("boardPoint: interaction.addPopoverBoardPoint,"))
        // A tile grid, not a classic pull-down.
        #expect(add.contains("LazyVGrid("))
        #expect(!add.contains(".menuStyle(.borderlessButton)"))
        // The menu bar keeps the classic list.
        #expect(add.contains("struct CanvasAddMenuItems: View"))
    }

    @Test("The bar has no overflow menu; Export is a button; every action keeps a menu-bar path")
    func overflowMenuRetired() throws {
        let bar = try Self.source("Sources/RafuApp/Canvas/Views/CanvasBar.swift")
        #expect(!bar.contains("ellipsis.circle"))
        #expect(!bar.contains("overflowMenu"))
        #expect(bar.contains("Label(\"Export Ensemble…\", systemImage: \"square.and.arrow.up\")"))
        #expect(bar.contains(".disabled(board.cards.isEmpty || session.rootURL == nil)"))
        // UX Round C (W1): the tab names the board; the bar has no title
        // and no name menu, and is 30 pt.
        #expect(!bar.contains("nameMenu"))
        #expect(!bar.contains("Text(board.title)"))
        #expect(bar.contains(".frame(height: CanvasBarLayout.height)"))
        // Double-click on the tab renames through one tap handler.
        let tab = try Self.source("Sources/RafuApp/Canvas/Views/CanvasEditorTabItem.swift")
        #expect(tab.contains("TabClickIntent.current() == .selectAndRename"))
        #expect(!tab.contains("onTapGesture(count: 2)"))
        #expect(tab.contains(".accessibilityAction(named: \"Rename\")"))
        for item in [
            "Button(\"Rename Ensemble…\")", "Button(\"Duplicate Ensemble\")",
            "Button(\"Open Ensemble…\")", "Button(\"Close Ensemble\")",
        ] {
            #expect(tab.contains(item), Comment(rawValue: item))
        }
        // W2: an autosaving board shows a saved tick, not a dirty dot.
        #expect(tab.contains("Image(systemName: \"checkmark.circle\")"))
        #expect(!tab.contains("Image(systemName: \"circle.fill\")"))
        #expect(tab.contains("RafuMotion.successHold"))
        let links = try Self.source("Sources/RafuApp/Canvas/Views/CanvasSessionLinksBar.swift")
        #expect(links.contains("items: CanvasLinkVisibility.allCases, selection: linkVisibility,"))

        #expect(links.contains("Button(\"Pause All Links\")"))
        let commands = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCommands.swift")
        for item in [
            "Menu(\"Show Links\")", "Button(\"Pause All Links\")", "Button(\"Resume All Links\")",
            "Button(\"Select All Cards\")",
            "CanvasDiagramMenuItems(board: board, session: session, showsShortcut: true)",
            "Menu(\"Open Recent Ensemble\")", "Button(\"Rename Ensemble…\")",
            "Button(\"Duplicate Ensemble\")", "Button(\"Close Ensemble\")",
        ] {
            #expect(commands.contains(item), Comment(rawValue: item))
        }
    }

    @Test("The board owns the palette's letter keys, so the palette can sit in the bar")
    func paletteKeysLiveOnTheBoard() throws {
        let canvas = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        let palette = try Self.source("Sources/RafuApp/Canvas/Whiteboard/CanvasToolPalette.swift")
        let bar = try Self.source("Sources/RafuApp/Canvas/Views/CanvasBar.swift")
        // The monitor is installed on the board, before `.focusable()`, and
        // reads the board's own focus state.
        let chromeStart = try #require(canvas.range(of: "private func boardChrome("))
        let keysStart = try #require(canvas.range(of: "private func boardKeys("))
        let chrome = String(canvas[chromeStart.upperBound..<keysStart.lowerBound])
        let monitor = try #require(chrome.range(of: "CanvasToolKeyMonitor("))
        let focusable = try #require(chrome.range(of: ".focusable()\n"))
        #expect(monitor.lowerBound < focusable.lowerBound)
        #expect(chrome.contains("boardFocused: boardHasKeyboardFocus, board: board"))
        #expect(chrome.contains("CanvasToolKeyHandler.handle("))
        // The palette reads no keys and no focus environment.
        let paletteView = try #require(palette.range(of: "struct CanvasToolPalette: View"))
        let paletteEnd = try #require(
            palette.range(
                of: "enum CanvasToolKeyHandler", range: paletteView.upperBound..<palette.endIndex))
        let paletteBody = String(palette[paletteView.upperBound..<paletteEnd.lowerBound])
        #expect(!paletteBody.contains("CanvasToolKeyMonitor("))
        #expect(!paletteBody.contains("\\.isFocused"))
        // One floating shadow; the hosted placement draws none.
        #expect(palette.components(separatedBy: ".shadow(").count - 1 == 1)
        // The bar hosts the palette only when wide, and the board then omits it.
        #expect(bar.contains("if interaction.paletteHostedInBar {"))
        #expect(bar.contains("placement: .hosted"))
        #expect(canvas.contains("if !interaction.paletteHostedInBar {"))
        #expect(!canvas.contains("CanvasBoardTopOverlayMetrics.belowPalette)"))
        #expect(!bar.contains(".shadow("))
    }

    @Test("Add palette entries: kinds, the icon library, then shell chips")
    @MainActor
    func addPaletteEntries() {
        let zsh = TerminalShell(
            path: "/opt/rafu-fixture-shells/zsh", name: "Default (zsh)", isDefault: true)
        let fish = TerminalShell(
            path: "/opt/rafu-fixture-shells/fish", name: "fish", isDefault: false)
        let all = CanvasAddPaletteEntry.entries(matching: "", shells: [zsh, fish])
        #expect(
            all
                == CanvasAddKind.allCases.map { .item(.kind($0)) } + [.serviceIcon]
                + [.item(.terminalShell(zsh)), .item(.terminalShell(fish))])
        #expect(all.filter(\.isChip).count == 2)
        // One shell: nothing to choose between, so no chips.
        #expect(
            !CanvasAddPaletteEntry.entries(matching: "", shells: [zsh]).contains { $0.isChip })
        #expect(CanvasAddPaletteEntry.entries(matching: "icon", shells: []) == [.serviceIcon])
        #expect(CanvasAddPaletteEntry.entries(matching: "zzz", shells: [zsh, fish]).isEmpty)
    }

    @Test("Arrow keys move row-major over three-column tiles, then two-column chips")
    func addPaletteNavigation() {
        typealias Nav = CanvasAddPaletteNavigation
        // 7 tiles (rows 0-2, 3-5, 6) and 3 chips (rows 7-8, 9).
        func move(_ index: Int, _ direction: Nav.Direction) -> Int {
            Nav.move(index, direction, tileCount: 7, chipCount: 3)
        }
        #expect(move(0, .right) == 1)
        #expect(move(0, .left) == 0)
        #expect(move(6, .right) == 7)  // last tile → first chip
        #expect(move(9, .right) == 9)
        #expect(move(1, .down) == 4)
        #expect(move(3, .down) == 6)
        #expect(move(4, .down) == 6)  // short last row: drop to its last tile
        #expect(move(5, .down) == 6)
        #expect(move(6, .down) == 7)  // last tile row → first chip row
        #expect(move(7, .up) == 6)
        #expect(move(7, .down) == 9)
        #expect(move(8, .down) == 8)
        #expect(move(9, .up) == 7)
        #expect(move(8, .up) == 6)  // first chip row → last tile row
        #expect(move(4, .up) == 1)
        #expect(move(1, .up) == 1)
        // No chips: a short last row still catches Down.
        #expect(Nav.move(4, .down, tileCount: 7, chipCount: 0) == 6)
        #expect(Nav.move(6, .down, tileCount: 7, chipCount: 0) == 6)
        #expect(Nav.move(0, .down, tileCount: 0, chipCount: 0) == 0)
    }

    @Test("Terminal groups are cards with pane chips, not an accordion; the card stays draggable")
    func terminalGroupCards() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        #expect(!panel.contains("chevron.right"))
        #expect(!panel.contains("expandedGroupIDs"))
        #expect(!panel.contains("TerminalGroupPaneRowView"))
        #expect(panel.contains("AgentStatusPill("))
        #expect(panel.contains("TerminalPaneChipView("))
        // The whole card is still the drag source, carrying only the group id.
        let card = try #require(panel.range(of: "private struct TerminalGroupManagerRowView"))
        let next = try #require(
            panel.range(
                of: "private struct TerminalPaneMenuItems", range: card.upperBound..<panel.endIndex)
        )
        let cardSource = String(panel[card.upperBound..<next.lowerBound])
        #expect(cardSource.contains(".onDrag("))
        #expect(
            cardSource.contains(
                "CanvasBoardDragPayload(terminalGroupID: row.id).makeItemProvider()"))
        // Hover-revealed ⋯, backed by the same items in a context menu.
        #expect(cardSource.contains(".contextMenu { actions }"))
        #expect(cardSource.contains(".opacity(isHovering || isFocused ? 1 : 0)"))
        // One tap handler: double-click renames without delaying a click.
        #expect(cardSource.contains("TabClickIntent.current() == .selectAndRename"))
    }

    @Test("The zoom capsule offers Fit and Show Overview; the Ensemble menu has Show Overview")
    func zoomCapsuleFitAndOverview() throws {
        let bar = try Self.source("Sources/RafuApp/Canvas/Views/CanvasBar.swift")
        let capsule = try #require(bar.range(of: "struct CanvasZoomCapsule: View"))
        let capsuleSource = String(bar[capsule.lowerBound...])
        #expect(capsuleSource.contains("Button(\"Fit\") { board.fitAll() }"))
        #expect(capsuleSource.contains("CanvasArrival.anyCardOutOfView("))
        #expect(capsuleSource.contains("Toggle(\"Show Overview\", isOn: $overviewPinned)"))
        #expect(capsuleSource.contains("CanvasZoomMetrics.isAtInteractiveFloor("))
        let commands = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCommands.swift")
        #expect(commands.contains("Toggle(\"Show Overview\", isOn: $overviewPinned)"))
        #expect(commands.contains(".keyboardShortcut(\"m\", modifiers: [.control, .command])"))
        // No new shadow in the Round A board views (two-shadow budget).
        for path in [
            "Sources/RafuApp/Canvas/Views/CanvasMinimapView.swift",
            "Sources/RafuApp/Canvas/Views/CanvasSeedLayer.swift",
            "Sources/RafuApp/Canvas/Views/CanvasSetDownRing.swift",
        ] {
            #expect(!(try Self.source(path)).contains(".shadow("), "\(path)")
        }
    }

    private static func root(file: StaticString = #filePath) -> URL? {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    private static func exists(_ path: String) -> Bool {
        guard let root = root() else { return false }
        return FileManager.default.fileExists(atPath: root.appending(path: path).path)
    }

    static func source(_ path: String) throws -> String {
        guard let root = root() else { throw CocoaError(.fileNoSuchFile) }
        return try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }
}
