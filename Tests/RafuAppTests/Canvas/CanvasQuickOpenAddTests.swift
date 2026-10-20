import AppKit
import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Quick Open's ⌘↩ "Add to Ensemble": `WorkspaceSession.addFileToSelectedCanvas`,
/// its duplicate lookup, its key match, and the palette footer legend.
@Suite("Ensemble Quick Open add")
@MainActor
struct CanvasQuickOpenAddTests {
    // MARK: - Lookup

    @Test("Lookup finds file and image cards by path, and only those")
    func lookupMatchesFileAndImageCards() {
        let note = CanvasCard(title: "Notes", content: .note(snapshot: "Sources/a.swift"))
        let file = CanvasCard(title: "a.swift", content: .file(path: "Sources/a.swift"))
        let image = CanvasCard(title: "logo.png", content: .image(path: "Assets/logo.png"))
        let cards = [note, file, image]

        #expect(
            CanvasFileCardLookup.existingCard(forRelativePath: "Sources/a.swift", in: cards)
                == file.id)
        #expect(
            CanvasFileCardLookup.existingCard(forRelativePath: "Assets/logo.png", in: cards)
                == image.id)
        #expect(
            CanvasFileCardLookup.existingCard(forRelativePath: "Sources/b.swift", in: cards)
                == nil)
        #expect(CanvasFileCardLookup.existingCard(forRelativePath: "a.swift", in: cards) == nil)
    }

    @Test("Lookup returns the first matching card in board order")
    func lookupReturnsFirstMatch() {
        let first = CanvasCard(title: "a", content: .file(path: "a.txt"))
        let second = CanvasCard(title: "a again", content: .file(path: "a.txt"))
        #expect(
            CanvasFileCardLookup.existingCard(forRelativePath: "a.txt", in: [first, second])
                == first.id)
    }

    // MARK: - Session action

    @Test("Adding a file puts one selected, focused card on the board as one undo step")
    func addsSelectedFocusedCard() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        #expect(board.cards.isEmpty)

        session.addFileToSelectedCanvas(try match(session, "Sources/App.swift"))

        let card = try #require(board.cards.first)
        #expect(board.cards.count == 1)
        #expect(card.title == "App.swift")
        #expect(card.content == .file(path: "Sources/App.swift"))
        #expect(board.selection == [card.id])
        #expect(board.focusedCardID == card.id)
        #expect(!board.contentIsActive)
        #expect(board.errorMessage == nil)

        board.performUndo()
        #expect(board.cards.isEmpty, "The add is exactly one undo step")
        #expect(await session.canvas.flushAll())
    }

    @Test("An image path becomes an image card")
    func imagePathBecomesImageCard() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)

        session.addFileToSelectedCanvas(try match(session, "Assets/logo.PNG"))

        #expect(board.cards.first?.content == .image(path: "Assets/logo.PNG"))
        #expect(await session.canvas.flushAll())
    }

    @Test("Adding a file the board already shows selects that card and adds none")
    func duplicateSelectsExistingCard() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        let file = try match(session, "README.md")

        session.addFileToSelectedCanvas(file)
        let existing = try #require(board.cards.first?.id)
        try board.add(title: "Note", content: .note(snapshot: ""))
        #expect(board.selection != [existing])

        session.addFileToSelectedCanvas(file)

        #expect(board.cards.count == 2)
        #expect(board.selection == [existing])
        #expect(board.focusedCardID == existing)
        #expect(await session.canvas.flushAll())
    }

    @Test("A file from another workspace folder is refused with a message")
    func otherFolderIsRefused() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        let outside = WorkspaceFileMatch(
            rootID: UUID(), relativePath: "other.swift", displayPath: "Other/other.swift")

        session.addFileToSelectedCanvas(outside)

        #expect(board.cards.isEmpty)
        #expect(board.errorMessage == WorkspaceSession.canvasFileOutsideFolderMessage)
        #expect(await session.canvas.flushAll())
    }

    @Test("A full board reports the capacity error and adds nothing")
    func fullBoardReportsCapacity() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        session.presentCanvasBoard(board)
        try board.edit { document in
            document.cards = (0..<CanvasLimits.cards).map { index in
                CanvasCard(title: "Note \(index)", content: .note(snapshot: ""))
            }
        }

        session.addFileToSelectedCanvas(try match(session, "README.md"))

        #expect(board.cards.count == CanvasLimits.cards)
        #expect(board.errorMessage == CanvasError.capacity.localizedDescription)
        #expect(await session.canvas.flushAll())
    }

    @Test("Without a selected Ensemble the action does nothing")
    func noSelectedBoardIsANoOp() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, board) = try await fixture(root)
        // The board is never presented, so `selectedCanvasID` is nil.
        #expect(session.selectedCanvasID == nil)

        session.addFileToSelectedCanvas(try match(session, "README.md"))

        #expect(board.cards.isEmpty)
        #expect(board.errorMessage == nil)
        #expect(await session.canvas.flushAll())
    }

    // MARK: - Palette

    @Test("The footer names ⌘↩ only while an Ensemble is the focused tab")
    func footerTextBothStates() {
        let base = "↑↓ Navigate · ↩ Open · esc Close"
        #expect(PaletteFooterHints.text(boardActive: false) == base)
        #expect(PaletteFooterHints.text(boardActive: true) == base + " · ⌘↩ Add to Ensemble")
        #expect(PaletteFooterHints.text == base)
        #expect(!PaletteFooterHints.text(boardActive: true).contains("Canvas"))
    }

    @Test("The key monitor takes Command-Return and keypad Enter only")
    func keyMonitorMatchesCommandReturn() {
        typealias Host = CommandPaletteKeyMonitor.Host
        #expect(Host.isAddToEnsemble(keyCode: 36, flags: .command))
        #expect(Host.isAddToEnsemble(keyCode: 76, flags: .command))
        #expect(Host.isAddToEnsemble(keyCode: 36, flags: [.command, .capsLock]))
        #expect(!Host.isAddToEnsemble(keyCode: 36, flags: []))
        #expect(!Host.isAddToEnsemble(keyCode: 36, flags: [.command, .shift]))
        #expect(!Host.isAddToEnsemble(keyCode: 36, flags: [.command, .option]))
        #expect(!Host.isAddToEnsemble(keyCode: 36, flags: .control))
        #expect(!Host.isAddToEnsemble(keyCode: 35, flags: .command))
    }

    // MARK: - Fixture

    private func makeRoot() throws -> URL {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func match(_ session: WorkspaceSession, _ path: String) throws -> WorkspaceFileMatch {
        let rootID = try #require(session.descriptor?.id)
        return WorkspaceFileMatch(rootID: rootID, relativePath: path, displayPath: path)
    }

    private func fixture(_ root: URL) async throws -> (WorkspaceSession, CanvasBoardState) {
        let session = WorkspaceSession(
            restorationStore: WorkspaceRestorationStore(
                defaultsSuiteName: TestDefaultsSuite.name("dev.rafu.canvas-quick-open-add-tests"),
                bookmarkMaker: { _ in throw CancellationError() }),
            closeSaveTracker: WorkspaceCloseSaveTracker(),
            canvasStore: WorkspaceCanvasStore(
                persistence: CanvasPersistenceStore(directory: root.appending(path: "saved-boards"))
            ))
        session.descriptor = WorkspaceDescriptor(
            displayName: "Test", location: .local(.init(path: root.path)))
        #expect(await session.canvas.configure(root: root))
        return (session, try #require(await session.canvas.create(title: "Quick Open")))
    }
}
