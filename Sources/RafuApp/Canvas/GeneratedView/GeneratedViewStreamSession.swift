import Foundation
import JSONRenderCore
import JSONRenderSwiftUI
import Observation

/// A view that fills while voice streams the `show_view` arguments.
///
/// `beginStreaming` adds the card with a one-element skeleton spec (one undo
/// step) and returns this handle. `push` feeds the argument text into a
/// `StreamModel` (object mode: `title`, `node` and `reset` are ignored keys),
/// which the card renders while it streams.
///
/// Undo collapse rule for `finish`: when nothing else changed the board's
/// cards or links since the skeleton was added, the board's change stamp has
/// not moved (no rename, consent change or other step), no card content is
/// active, and the skeleton step is still the newest undo step, `finish` undoes the
/// skeleton step and adds the final card with the same id. The whole voice
/// request is then one undo step. Otherwise the final spec is written as an
/// update of the skeleton card (two undo steps, both honest). An invalid
/// final spec, or `cancel`, removes the skeleton the same way.
final class GeneratedViewStreamSession: GeneratedViewStreamHandle {
    /// The skeleton every streamed card starts with (canonical text).
    static let skeletonSpec = #"{"elements":{"r":{"props":{},"type":"Skeleton"}},"root":"r"}"#
    /// Argument text after this many bytes is ignored.
    static let pushLimit = CanvasLimits.generatedViewSpecBytes

    let cardID: CanvasCardID
    let model: StreamModel
    private let card: CanvasCard
    private weak var board: CanvasBoardState?
    private let provenance: CanvasGeneratedViewProvenance
    private let host: GeneratedViewActions
    private let gate: CanvasAgentUndoGate
    /// The board's change stamp just after the skeleton step. The gate compares
    /// only cards and links; a rename or a consent change is also an undo step,
    /// and the stamp catches it.
    private let skeletonStamp: UInt64
    private var continuation: AsyncThrowingStream<String, any Error>.Continuation?
    private var run: Task<Void, Never>?
    private var received = 0
    private var isDone = false

    init(
        card: CanvasCard, board: CanvasBoardState, provenance: CanvasGeneratedViewProvenance,
        host: GeneratedViewActions
    ) {
        self.card = card
        cardID = card.id
        self.board = board
        self.provenance = provenance
        self.host = host
        gate = CanvasAgentUndoGate(
            boardID: board.id, cards: board.cards, connections: board.connections)
        skeletonStamp = board.changeStamp
        model = StreamModel(catalog: RafuCatalog.rafu)
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        self.continuation = continuation
        let model = model
        run = Task { await model.run(stream, mode: .object) }
        GeneratedViewStreams.shared.begin(self)
    }

    func push(_ argumentsDelta: String) {
        guard !isDone else { return }
        let bytes = argumentsDelta.utf8.count
        guard received + bytes <= Self.pushLimit else { return }
        received += bytes
        continuation?.yield(argumentsDelta)
    }

    func finish(specJSON: String) async -> Result<GeneratedViewSummary, GeneratedViewError> {
        guard !isDone else { return .failure(.unavailable) }
        end()
        guard let board, board.cards.contains(where: { $0.id == cardID }) else {
            return .failure(.invalidSpec("The view was removed before it finished."))
        }
        let checked: GeneratedViewActions.Checked
        switch Self.specText(fromArguments: specJSON).flatMap({ host.check($0) }) {
        case .success(let value): checked = value
        case .failure(let error):
            removeSkeleton(from: board)
            return .failure(error)
        }
        if let refusal = GeneratedViewBudget.refusal(
            specJSON: checked.text, cards: board.cards, replacing: cardID)
        {
            removeSkeleton(from: board)
            return .failure(refusal)
        }
        var finished = card
        finished.content = .generatedView(
            GeneratedViewActions.view(checked.text, provenance: provenance))
        do {
            if canCollapse(board) {
                board.performUndo()
                try board.edit { $0.cards.append(finished) }
            } else {
                try board.edit { document in
                    guard let index = document.cards.firstIndex(where: { $0.id == self.cardID })
                    else { return }
                    document.cards[index].content = finished.content
                }
            }
        } catch {
            return .failure(.invalidSpec("The view could not be added."))
        }
        board.select([cardID])
        return .success(checked.summary)
    }

    func cancel() {
        guard !isDone else { return }
        end()
        if let board { removeSkeleton(from: board) }
    }

    private func end() {
        isDone = true
        continuation?.finish()
        continuation = nil
        model.cancel()
        run?.cancel()
        run = nil
        GeneratedViewStreams.shared.end(cardID)
    }

    private func canCollapse(_ board: CanvasBoardState) -> Bool {
        board.canUndo && !board.contentIsActive && board.changeStamp == skeletonStamp
            && gate.allows(cards: board.cards, connections: board.connections)
    }

    private func removeSkeleton(from board: CanvasBoardState) {
        if canCollapse(board) {
            board.performUndo()
        } else {
            try? board.edit { $0.cards.removeAll { $0.id == self.cardID } }
        }
    }

    /// The spec part of the `show_view` arguments object: `root`, `elements`
    /// and `state`; every other key is dropped.
    static func specText(fromArguments text: String) -> Result<String, GeneratedViewError> {
        guard text.utf8.count <= CanvasLimits.generatedViewSpecBytes else {
            return .failure(.tooLarge(bytes: text.utf8.count))
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                as? [String: Any]
        else { return .failure(.invalidSpec("The arguments are not one JSON object.")) }
        var spec: [String: Any] = [:]
        for key in ["root", "elements", "state"] { spec[key] = object[key] }
        guard JSONSerialization.isValidJSONObject(spec),
            let data = try? JSONSerialization.data(
                withJSONObject: spec, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return .failure(.invalidSpec("The spec is not valid JSON.")) }
        return .success(String(decoding: data, as: UTF8.self))
    }
}

/// The streams that fill cards now. The card view reads it to show the stream.
@MainActor
@Observable
final class GeneratedViewStreams {
    static let shared = GeneratedViewStreams()

    private(set) var models: [CanvasCardID: StreamModel] = [:]

    func begin(_ session: GeneratedViewStreamSession) {
        models[session.cardID] = session.model
    }

    func end(_ cardID: CanvasCardID) {
        models[cardID] = nil
    }
}
