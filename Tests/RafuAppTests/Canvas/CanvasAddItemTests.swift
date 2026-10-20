import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// `CanvasAddItem` — the Add popover/menu row that can be a fixed
/// `CanvasAddKind` or a specific shell's terminal (terminal-manager.md T-C).
/// Every fixture shell path is made up: these tests never depend on which
/// shells are actually installed on this machine.
@Suite("Canvas Add Item")
@MainActor
struct CanvasAddItemTests {
    // Deliberately made-up paths — never a real shell on any machine, so a
    // `record()` through `perform` below cannot collide with, and silently
    // persist as, a developer's actual preferred shell.
    private let zsh = TerminalShell(
        path: "/opt/rafu-fixture-shells/zsh", name: "Default (zsh)", isDefault: true)
    private let fish = TerminalShell(
        path: "/opt/rafu-fixture-shells/fish", name: "fish", isDefault: false)

    @Test("With fewer than two shells, only the fixed kinds are offered")
    func oneShellOffersNoShellRows() {
        let items = CanvasAddItem.all(shells: [zsh])
        #expect(items == CanvasAddKind.allCases.map(CanvasAddItem.kind))
        #expect(CanvasAddItem.all(shells: []) == CanvasAddKind.allCases.map(CanvasAddItem.kind))
    }

    @Test("With two or more shells, one row per shell follows the fixed kinds, catalog order")
    func twoShellsAddShellRows() {
        let items = CanvasAddItem.all(shells: [zsh, fish])
        #expect(items.count == CanvasAddKind.allCases.count + 2)
        #expect(items.suffix(2) == [.terminalShell(zsh), .terminalShell(fish)])
    }

    @Test("A kind row's id and title are unchanged; a shell row's id is its path")
    func idsAndTitles() {
        let terminalKind = CanvasAddItem.kind(.terminal)
        #expect(terminalKind.id == "kind.terminal")
        #expect(terminalKind.title(amongShells: [zsh, fish]) == "Terminal")

        let shellItem = CanvasAddItem.terminalShell(fish)
        #expect(shellItem.id == "shell:\(fish.path)")
        #expect(shellItem.title(amongShells: [zsh, fish]) == "Terminal — fish")
        #expect(shellItem.symbol == "apple.terminal")
    }

    @Test("A shell row's title de-duplicates same-named shells by path, like the menu")
    func duplicateShellNamesAppendPath() {
        let secondFish = TerminalShell(
            path: "/opt/rafu-fixture-shells/second-fish", name: "fish", isDefault: false)
        let shells = [zsh, fish, secondFish]
        let title = CanvasAddItem.terminalShell(fish).title(amongShells: shells)
        #expect(title == "Terminal — fish — \(fish.path)")
    }

    @Test("matches filters by title, case-insensitively, including shell rows")
    func matchesFiltersShellRowsToo() {
        let shells = [zsh, fish]
        #expect(CanvasAddItem.matches("", shells: shells) == CanvasAddItem.all(shells: shells))
        #expect(
            CanvasAddItem.matches("fish", shells: shells) == [CanvasAddItem.terminalShell(fish)])
        #expect(
            CanvasAddItem.matches("term", shells: shells)
                == [.kind(.terminal), .terminalShell(zsh), .terminalShell(fish)])
        #expect(CanvasAddItem.matches("zzz", shells: shells).isEmpty)
    }

    @Test("A kind row performs its kind's action; a shell row adds a terminal with that shell")
    @MainActor
    func performDelegatesByCase() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-add-item-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: "saved-boards"))
            ))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: root.path)))
        #expect(await session.canvas.configure(root: root))
        let board = try #require(await session.canvas.create(title: "Items"))

        CanvasAddItem.kind(.note).perform(on: board, session: session)
        #expect(board.cards.count == 1)
        guard case .note = board.cards[0].content else {
            Issue.record("Expected a note card")
            return
        }

        CanvasAddItem.terminalShell(zsh).perform(on: board, session: session)
        #expect(board.cards.count == 2)
        guard case .terminal(let groupID) = board.cards[1].content else {
            Issue.record("Expected a terminal card")
            return
        }
        let pane = try #require(session.terminal.terminalGroup(groupID)?.panes.first)
        #expect(pane.launchProfile?.shell == .approvedShellPath(zsh.path))
        #expect(await session.canvas.flushAll())
    }
}
