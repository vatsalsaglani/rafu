import Foundation
import JSONRenderCore
import Testing

@testable import RafuApp

@Suite("Generated view card and the saved board")
@MainActor
struct GeneratedViewBoardIntegrationTests {
    let fixtures = GeneratedViewFixtures.self

    private func makeCard(_ spec: String) throws -> (CanvasBoardState, CanvasCardID) {
        let board = CanvasBoardState(document: CanvasDocument(title: "Views"))
        let id = try GeneratedViewActions().create(
            specJSON: spec, title: "Form", rect: fixtures.rect,
            provenance: fixtures.provenance(), on: board)
        return (board, id)
    }

    /// Writes the live store, then hands the model the store's snapshot the
    /// way its follow task does.
    private func write(
        _ changes: [(String, JSONRenderCore.JSONValue)], to model: GeneratedViewCardModel
    ) async {
        await model.store.update(changes.map { (JSONPointer(stringLiteral: $0.0), $0.1) })
        model.ingest(await model.store.snapshot)
    }

    @Test("The saved board file never holds a _ key or a password value")
    func savedFileHasNoSecrets() async throws {
        let (board, id) = try makeCard(fixtures.formSpec)
        let model = GeneratedViewModels.shared.model(for: id, board: board, session: nil)
        defer { model.stop() }
        await model.sync(try #require(fixtures.view(on: board, id)))
        await write(
            [("/on", true), ("/pw", "hunter2-secret"), ("/_draft", "unsent-draft-text")],
            to: model)

        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let disk = CanvasPersistenceStore(directory: folder)
        let key = TerminalGroupWorkspaceKey(standardizedRoot: folder)
        let saved = try await disk.save(try board.snapshot(), expectedRevision: 0, workspace: key)

        let files = try #require(
            FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)
        )
        .compactMap { $0 as? URL }
        .filter { $0.lastPathComponent.hasPrefix(saved.id.rawValue.uuidString.lowercased()) }
        let file = try #require(files.first)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("stateJSON"))
        #expect(!text.contains("hunter2-secret"))
        #expect(!text.contains("unsent-draft-text") && !text.contains("_draft"))
        // The Switch value is saved.
        guard case .generatedView(let view)? = saved.cards.first?.content else {
            Issue.record("Expected a view")
            return
        }
        #expect(view.state?.stateJSON == #"{"on":true}"#)
    }

    @Test("A state change is not an undo step; Reset View is one, and Undo brings it back")
    func resetViewUndo() async throws {
        let (board, id) = try makeCard(fixtures.formSpec)
        let model = GeneratedViewModels.shared.model(for: id, board: board, session: nil)
        defer { model.stop() }
        await model.sync(try #require(fixtures.view(on: board, id)))
        await write([("/on", true)], to: model)
        // Saving folds the state in without an undo step.
        let folded = try board.snapshot()
        board.acceptSaved(folded, stamp: board.changeStamp)
        await model.sync(try #require(fixtures.view(on: board, id)))
        #expect(await model.store.get("/on") == true)

        #expect(GeneratedViewActions.reset(id, on: board))
        await model.sync(try #require(fixtures.view(on: board, id)))
        #expect(fixtures.view(on: board, id)?.state == nil)
        #expect(await model.store.get("/on") == false)

        board.performUndo()
        await model.sync(try #require(fixtures.view(on: board, id)))
        #expect(await model.store.get("/on") == true)
        // Undo again removes the card: the state change was never a step.
        board.performUndo()
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("A changed spec drops the live state and says so; the old state is not applied")
    func specChangeResets() async throws {
        let (board, id) = try makeCard(fixtures.formSpec)
        let model = GeneratedViewModels.shared.model(for: id, board: board, session: nil)
        defer { model.stop() }
        await model.sync(try #require(fixtures.view(on: board, id)))
        await write([("/on", true)], to: model)
        let changed = fixtures.formSpec.replacingOccurrences(of: "\"On\"", with: "\"Enabled\"")
        _ = try await GeneratedViewActions().update(
            id, change: .spec(changed), provenance: fixtures.provenance(), on: board)
        await model.sync(try #require(fixtures.view(on: board, id)))
        #expect(await model.store.get("/on") == false)
        #expect(model.resetNotice == .viewChanged)
    }

    @Test("A saved state for another spec is not applied on load")
    func staleStateOnLoad() async throws {
        let (board, id) = try makeCard(fixtures.formSpec)
        fixtures.setState(
            CanvasGeneratedViewState(
                specVersion: String(repeating: "0", count: 64),
                catalogVersion: RafuCatalog.version, savedAt: Date(), stateJSON: #"{"on":true}"#),
            on: id, board: board)
        let model = GeneratedViewModels.shared.model(for: id, board: board, session: nil)
        defer { model.stop() }
        await model.sync(try #require(fixtures.view(on: board, id)))
        #expect(await model.store.get("/on") == false)
        #expect(model.resetNotice == .viewChanged)
    }
}
