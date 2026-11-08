import Foundation
import JSONRenderCore
import Testing

@testable import RafuApp

@Suite("Generated view host")
@MainActor
struct GeneratedViewHostTests {
    let host = GeneratedViewActions()
    let fixtures = GeneratedViewFixtures.self

    private func board() -> CanvasBoardState {
        CanvasBoardState(document: CanvasDocument(title: "Views"))
    }

    private func create(_ spec: String, on board: CanvasBoardState) throws -> CanvasCardID {
        try host.create(
            specJSON: spec, title: "Tests", rect: fixtures.rect,
            provenance: fixtures.provenance(), on: board)
    }

    private func savedState(_ json: String, spec: String) throws -> CanvasGeneratedViewState {
        CanvasGeneratedViewState(
            specVersion: GeneratedViewStatePersistence.specVersion(of: try fixtures.spec(spec)),
            catalogVersion: RafuCatalog.version, savedAt: Date(), stateJSON: json)
    }

    @Test("Create is one undo step and stores the canonical spec")
    func createIsOneStep() throws {
        let board = board()
        let messy =
            #"{ "root": "r", "elements": { "r": { "type": "Text", "props": { "text": "Hello" } } } }"#
        let id = try create(messy, on: board)
        let view = try #require(fixtures.view(on: board, id))
        #expect(view.specJSON == fixtures.textSpec)
        #expect(view.state == nil)
        #expect(view.catalogVersion == RafuCatalog.version)
        #expect(view.provenance.creator == "Claude")
        #expect(board.selection == [id])
        board.performUndo()
        #expect(board.cards.isEmpty)
        #expect(!board.canUndo)
    }

    @Test("A spec that does not validate is refused with the validator's words")
    func invalidSpec() throws {
        let board = board()
        let unknown = #"{"root":"r","elements":{"r":{"type":"Marquee","props":{}}}}"#
        #expect(throws: GeneratedViewError.self) { try create(unknown, on: board) }
        guard case .failure(.invalidSpec(let text)) = host.validate(specJSON: unknown) else {
            Issue.record("Expected invalidSpec")
            return
        }
        #expect(text.contains("Marquee"))
        guard case .failure(.invalidSpec) = host.validate(specJSON: "not json") else {
            Issue.record("Expected invalidSpec for bad JSON")
            return
        }
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("A changed spec resets the state in one undo step; Undo brings both back")
    func updateResetsState() async throws {
        let board = board()
        let id = try create(fixtures.textSpec, on: board)
        let state = try savedState(#"{"n":1}"#, spec: fixtures.textSpec)
        fixtures.setState(state, on: id, board: board)
        let summary = try await host.update(
            id, change: .spec(fixtures.otherSpec), provenance: fixtures.provenance(), on: board)
        #expect(summary.elementCount == 1 && summary.types == ["Text"])
        let updated = try #require(fixtures.view(on: board, id))
        #expect(updated.specJSON == fixtures.otherSpec)
        #expect(updated.state == nil)
        #expect(updated.provenance.updatedAt != nil)
        board.performUndo()
        let restored = try #require(fixtures.view(on: board, id))
        #expect(restored.specJSON == fixtures.textSpec)
        #expect(restored.state == state)
        board.performUndo()
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("The same spec again is no change and no undo step")
    func identicalSpec() async throws {
        let board = board()
        let id = try create(fixtures.textSpec, on: board)
        let state = try savedState(#"{"n":1}"#, spec: fixtures.textSpec)
        fixtures.setState(state, on: id, board: board)
        _ = try await host.update(
            id, change: .spec(fixtures.textSpec), provenance: fixtures.provenance(), on: board)
        #expect(fixtures.view(on: board, id)?.state == state)
        board.performUndo()
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("Reset clears the state in one undo step; Undo restores it")
    func reset() async throws {
        let board = board()
        let id = try create(fixtures.textSpec, on: board)
        let state = try savedState(#"{"n":1}"#, spec: fixtures.textSpec)
        fixtures.setState(state, on: id, board: board)
        _ = try await host.update(
            id, change: .reset, provenance: fixtures.provenance(), on: board)
        #expect(fixtures.view(on: board, id)?.state == nil)
        #expect(fixtures.view(on: board, id)?.specJSON == fixtures.textSpec)
        board.performUndo()
        #expect(fixtures.view(on: board, id)?.state == state)
    }

    @Test("Reset with no saved state records no undo step")
    func resetWithoutState() throws {
        let board = board()
        let id = try create(fixtures.textSpec, on: board)
        #expect(!GeneratedViewActions.reset(id, on: board))
        board.performUndo()
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("Patches apply as one step; a bad line names its number only")
    func patches() async throws {
        let board = board()
        let id = try create(fixtures.textSpec, on: board)
        let replace = #"{"op":"replace","path":"/elements/r/props/text","value":"Patched"}"#
        _ = try await host.update(
            id, change: .patches(replace), provenance: fixtures.provenance(), on: board)
        #expect(fixtures.view(on: board, id)?.specJSON.contains("Patched") == true)

        let bad = replace + "\nnot a patch"
        await #expect(throws: GeneratedViewError.invalidSpec("line 2: not an object")) {
            _ = try await host.update(
                id, change: .patches(bad), provenance: fixtures.provenance(), on: board)
        }
        board.performUndo()
        #expect(fixtures.view(on: board, id)?.specJSON == fixtures.textSpec)
    }

    @Test("A board holds at most 50 views")
    func capacity() throws {
        var document = CanvasDocument(title: "Full")
        document.cards = (0..<CanvasLimits.generatedViewCards).map { index in
            CanvasCard(
                title: "View \(index)",
                content: .generatedView(
                    GeneratedViewActions.view(fixtures.textSpec, provenance: fixtures.provenance()))
            )
        }
        let board = CanvasBoardState(document: document)
        #expect(throws: GeneratedViewError.capacity) { try create(fixtures.textSpec, on: board) }
    }

    @Test("Update and reset refuse a card that is not a view")
    func notAView() async throws {
        let board = board()
        try board.add(title: "Note", content: .note(snapshot: "text"))
        let id = try #require(board.cards.first?.id)
        await #expect(throws: GeneratedViewError.notAView) {
            _ = try await host.update(
                id, change: .reset, provenance: fixtures.provenance(), on: board)
        }
        #expect(GeneratedViewActions.resetTarget(on: board) == nil)
    }

    @Test("Reset View targets the focused card, else the one selected view")
    func resetTarget() throws {
        let board = board()
        let id = try create(fixtures.textSpec, on: board)
        board.select([id])
        #expect(GeneratedViewActions.resetTarget(on: board) == id)
        board.select([])
        #expect(GeneratedViewActions.resetTarget(on: board) == nil)
    }

    @Test("A finished voice stream is one undo step with the skeleton's card id")
    func streamCollapses() async throws {
        let board = board()
        let handle = try host.beginStreaming(
            title: "Voice", rect: fixtures.rect, provenance: fixtures.provenance("Rafu (voice)"),
            on: board)
        #expect(
            fixtures.view(on: board, handle.cardID)?.specJSON
                == GeneratedViewStreamSession.skeletonSpec)
        handle.push(#"{"title":"Voice","root":"r","elements":{"r":"#)
        let arguments =
            #"{"title":"Voice","node":"x","root":"r","elements":{"r":{"type":"Text","props":{"text":"Hello"}}}}"#
        let result = await handle.finish(specJSON: arguments)
        #expect((try? result.get())?.elementCount == 1)
        #expect(board.cards.count == 1)
        #expect(fixtures.view(on: board, handle.cardID)?.specJSON == fixtures.textSpec)
        board.performUndo()
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("An invalid final stream spec removes the skeleton and leaves no undo step")
    func streamInvalid() async throws {
        let board = board()
        let handle = try host.beginStreaming(
            title: "Voice", rect: fixtures.rect, provenance: fixtures.provenance(), on: board)
        let result = await handle.finish(specJSON: #"{"root":"r","elements":{}}"#)
        guard case .failure(.invalidSpec) = result else {
            Issue.record("Expected invalidSpec")
            return
        }
        #expect(board.cards.isEmpty && !board.canUndo)
    }

    @Test("A cancelled stream removes the skeleton")
    func streamCancel() throws {
        let board = board()
        let handle = try host.beginStreaming(
            title: "Voice", rect: fixtures.rect, provenance: fixtures.provenance(), on: board)
        handle.cancel()
        #expect(board.cards.isEmpty && !board.canUndo)
    }
}
