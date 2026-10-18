import Foundation
import Testing

@testable import RafuApp

@Suite("Ensemble inline card rename")
struct CanvasInlineRenameTests {
    @Test("Return or clicking away saves a trimmed, changed, valid title")
    func committedTitle() {
        #expect(
            CanvasInlineRename.committedTitle(draft: "  Builder  ", current: "Terminal")
                == "Builder")
        #expect(CanvasInlineRename.committedTitle(draft: "Terminal", current: "Terminal") == nil)
        #expect(CanvasInlineRename.committedTitle(draft: " Terminal\n", current: "Terminal") == nil)
        #expect(CanvasInlineRename.committedTitle(draft: "   ", current: "Terminal") == nil)
        let tooLong = String(repeating: "x", count: 121)
        #expect(CanvasInlineRename.committedTitle(draft: tooLong, current: "Terminal") == nil)
    }

    @Test("Board shortcuts stand aside while a title field or card content has the keys")
    func boardTakesKeys() {
        let id = CanvasCardID()
        #expect(CanvasInlineRename.boardTakesKeys(contentIsActive: false, renamingCardID: nil))
        #expect(!CanvasInlineRename.boardTakesKeys(contentIsActive: false, renamingCardID: id))
        #expect(!CanvasInlineRename.boardTakesKeys(contentIsActive: true, renamingCardID: nil))
        #expect(!CanvasInlineRename.boardTakesKeys(contentIsActive: true, renamingCardID: id))
    }

    @Test("Every board key handler checks the rename-aware gate")
    func boardKeyHandlersUseGate() throws {
        let source = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        let start = try #require(source.range(of: "private func boardKeys("))
        let end = try #require(
            source.range(
                of: "private var boardTopOverlay", range: start.upperBound..<source.endIndex))
        let keys = source[start.upperBound..<end.lowerBound]
        #expect(!keys.contains("!board.contentIsActive"))
        #expect(keys.contains("guard boardTakesKeys"))
        let chrome = try Self.source("Sources/RafuApp/Canvas/Views/CanvasCardChrome.swift")
        // Focus loss saves; Esc closes the field before focus moves.
        #expect(chrome.contains("if !isFocused, board.renamingCardID == card.id { commit() }"))
        #expect(chrome.contains(".onSubmit { commit() }"))
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
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
