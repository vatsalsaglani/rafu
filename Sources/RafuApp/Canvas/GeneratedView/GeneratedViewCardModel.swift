import Foundation
import JSONRenderCore
import Observation

/// The live side of one generated view card in one board window: the decoded
/// spec, the `StateStore` its controls write, and the debounced state save.
///
/// The model lives in `GeneratedViewModels`, not in the card view, because
/// the board drops a card's view when it scrolls out of sight: the store must
/// keep the user's input (and a draft that is never saved) until the card or
/// the board goes away. The view's `RenderModel` is still released off-screen.
///
/// State rules (decision 2026-11-07):
/// - A saved state applies only when its spec and catalog versions match.
/// - A changed spec always resets the state to the spec's seed.
/// - A document state that becomes `nil` (Reset View) resets the store; one
///   that comes back from `nil` (Undo of Reset View) is applied. Any other
///   document state change with the same spec (this model's own save, or an
///   undo of an unrelated edit) leaves the live state alone.
/// - State changes are never undo steps.
@MainActor
@Observable
final class GeneratedViewCardModel {
    enum ResetNotice: Equatable {
        case viewChanged
        case catalogChanged

        var text: String {
            switch self {
            case .viewChanged: "View reset: the view changed"
            case .catalogChanged: "View reset: Rafu was updated"
            }
        }
    }

    let cardID: CanvasCardID
    let store = StateStore()
    private(set) var spec: Spec?
    /// Fixed text from the decoder, never spec content.
    private(set) var decodeError: String?
    private(set) var warningCount = 0
    private(set) var elementCount = 0
    private(set) var resetNotice: ResetNotice?
    private(set) var stateNotSaved = false
    /// Ids, names and counts only; at most 20 lines.
    private(set) var journal: [String] = []
    private(set) var creatorName = "an agent"
    var confirmRequest: GeneratedViewConfirmRequest?
    var isShowingSpec = false
    /// Set while a voice stream fills this card.
    var streamHandle: GeneratedViewStreamSession?

    @ObservationIgnored private(set) weak var board: CanvasBoardState?
    @ObservationIgnored private weak var session: WorkspaceSession?
    @ObservationIgnored private(set) var specText: String?
    @ObservationIgnored private var specVersion = ""
    @ObservationIgnored private var lastDocumentState: CanvasGeneratedViewState?
    @ObservationIgnored private var hasLoaded = false
    /// What the next save writes for this card (`nil`: the document's own).
    @ObservationIgnored private var persisted: CanvasGeneratedViewState?
    /// Recent states this model saved, so their fold back into the document
    /// is not mistaken for an outside change.
    @ObservationIgnored private var written: [CanvasGeneratedViewState] = []
    /// Store versions at or below this are the model's own resets.
    @ObservationIgnored private var baselineVersion: UInt64 = 0
    @ObservationIgnored private var isApplying = false
    @ObservationIgnored private var pendingState: JSONRenderCore.JSONValue?
    @ObservationIgnored private var changedOrder: [JSONPointer] = []
    @ObservationIgnored private var follow: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var confirmation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored let actionHost: RafuViewActionHost
    /// What the board components read; one object per model so the
    /// environment value stays stable across renders.
    @ObservationIgnored let boardContext: GeneratedViewBoardContext

    static let debounce: Duration = .milliseconds(500)
    static let journalLimit = CanvasLimits.generatedViewJournalEntries

    init(cardID: CanvasCardID, board: CanvasBoardState, session: WorkspaceSession?) {
        self.cardID = cardID
        self.board = board
        self.session = session
        actionHost = RafuViewActionHost(cardID: cardID, board: board, session: session)
        boardContext = GeneratedViewBoardContext(
            board: board, session: session, actionHost: actionHost)
        actionHost.attach(model: self)
        board.generatedViewStateSnapshots[cardID] = { [weak self, weak board] in
            guard let board,
                case .generatedView(let current)? = board.cards.first(where: {
                    $0.id == cardID
                })?.content
            else { return nil }
            guard let self else { return current.state }
            return self.stateForSave(current)
        }
        startFollowing()
    }

    /// Ends the store subscription and the pending save. The registry calls it
    /// when the card or the board goes away.
    func stop() {
        flushPending()
        follow?.cancel()
        follow = nil
        debounce?.cancel()
        debounce = nil
        confirmation?.resume(returning: false)
        confirmation = nil
        confirmRequest = nil
        if let board, board.cards.contains(where: { $0.id == cardID }) == false {
            board.generatedViewStateSnapshots[cardID] = nil
        }
    }

    /// A model made without a session (a menu or voice touched it first)
    /// takes the window's session when its card view appears.
    func adopt(_ session: WorkspaceSession) {
        guard self.session == nil else { return }
        self.session = session
        actionHost.adopt(session)
        boardContext.adopt(session)
    }

    // MARK: Document sync

    /// Brings the model in line with the card's content. Called when the card
    /// appears and whenever its content changes.
    func sync(_ content: CanvasGeneratedView) async {
        creatorName = content.provenance.creator
        if content.specJSON != specText {
            await load(content)
        } else if content.state != lastDocumentState {
            let previous = lastDocumentState
            lastDocumentState = content.state
            if let state = content.state, written.contains(state) { return }
            if content.state == nil {
                // Reset View. A later Undo brings a state back from nil, and
                // that state must apply even though this model wrote it.
                written.removeAll()
                persisted = nil
                resetNotice = nil
                stateNotSaved = false
                await apply(spec?.state)
            } else if previous == nil, spec != nil,
                let value = GeneratedViewStatePersistence.applicableState(
                    content.state, specVersion: specVersion, catalogVersion: RafuCatalog.version)
            {
                persisted = content.state
                await apply(value)
            }
        }
    }

    private func load(_ content: CanvasGeneratedView) async {
        let hadUserState = persisted != nil || pendingState != nil
        let wasLoaded = hasLoaded
        hasLoaded = true
        specText = content.specJSON
        lastDocumentState = content.state
        written.removeAll()
        persisted = nil
        pendingState = nil
        debounce?.cancel()
        stateNotSaved = false
        let decoded: Spec
        do {
            decoded = try Spec.decode(Data(content.specJSON.utf8), limits: .default).spec
        } catch {
            spec = nil
            decodeError = error.message
            elementCount = 0
            warningCount = 0
            return
        }
        decodeError = nil
        spec = decoded
        elementCount = decoded.elements.count
        warningCount = RafuCatalog.rafu.validate(decoded).warnings.count
        specVersion = GeneratedViewStatePersistence.specVersion(of: decoded)
        if let value = GeneratedViewStatePersistence.applicableState(
            content.state, specVersion: specVersion, catalogVersion: RafuCatalog.version)
        {
            persisted = content.state
            resetNotice = nil
            await apply(value)
        } else {
            if let saved = content.state {
                resetNotice =
                    saved.catalogVersion != RafuCatalog.version ? .catalogChanged : .viewChanged
            } else {
                resetNotice = wasLoaded && hadUserState ? .viewChanged : nil
            }
            await apply(decoded.state)
        }
    }

    func resetStore(to value: JSONRenderCore.JSONValue?) async {
        written.removeAll()
        persisted = nil
        await apply(value)
    }

    private func apply(_ value: JSONRenderCore.JSONValue?) async {
        isApplying = true
        debounce?.cancel()
        pendingState = nil
        changedOrder = []
        await store.replaceAll(value ?? .object([:]))
        baselineVersion = await store.snapshot.version
        isApplying = false
    }

    // MARK: Reset View

    /// Restores the spec's seed state in one board undo step. The state the
    /// user had is first written into the document without an undo step, so
    /// Undo brings it back.
    func flushIntoDocument() {
        guard let board else { return }
        flushPending()
        guard let persisted else { return }
        board.refreshResources { document in
            guard let index = document.cards.firstIndex(where: { $0.id == self.cardID }),
                case .generatedView(var view) = document.cards[index].content,
                view.specJSON == self.specText
            else { return }
            view.state = persisted
            document.cards[index].content = .generatedView(view)
        }
        lastDocumentState = persisted
    }

    // MARK: Saving

    private func startFollowing() {
        follow = Task { [weak self] in
            guard let stream = await self?.store.snapshots() else { return }
            for await snapshot in stream {
                guard let self else { return }
                self.ingest(snapshot)
            }
        }
    }

    /// Takes one store snapshot: remembers what changed and restarts the
    /// save debounce. The follow task calls it; tests call it directly so they
    /// need not wait for the stream.
    func ingest(_ snapshot: StateSnapshot) {
        guard !isApplying, snapshot.version > baselineVersion, spec != nil else { return }
        for pointer in snapshot.changed where !pointer.isRoot {
            changedOrder.removeAll { $0 == pointer }
            changedOrder.append(pointer)
        }
        if changedOrder.count > 256 { changedOrder.removeFirst(changedOrder.count - 256) }
        pendingState = snapshot.state
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.writePending()
        }
    }

    private func writePending() {
        guard flushPending() else { return }
        board?.markGeneratedViewStateEdited()
    }

    /// Computes the saved form of a pending change. Returns `true` when it
    /// changed what the next save writes.
    @discardableResult
    private func flushPending() -> Bool {
        guard let state = pendingState, let spec, let board else { return false }
        pendingState = nil
        let output = GeneratedViewStatePersistence.snapshot(
            state: state, changedNewestLast: changedOrder, spec: spec,
            secretProps: GeneratedViewModels.secretProps,
            catalogVersion: RafuCatalog.version,
            cap: GeneratedViewBudget.stateCap(for: cardID, on: board))
        stateNotSaved = output.notSaved
        for line in output.journal { appendJournal(line) }
        guard output.state?.stateJSON != persisted?.stateJSON else { return false }
        persisted = output.state
        if let saved = output.state {
            written.append(saved)
            if written.count > 8 { written.removeFirst(written.count - 8) }
        }
        return true
    }

    /// The state the next save writes for `current`, the card's content now.
    func stateForSave(_ current: CanvasGeneratedView) -> CanvasGeneratedViewState? {
        guard current.specJSON == specText else { return current.state }
        flushPending()
        let ownState =
            current.state == lastDocumentState
            || current.state.map { written.contains($0) } == true
        guard ownState else { return current.state }
        return persisted ?? current.state
    }

    // MARK: Journal and popups

    func appendJournal(_ line: String) {
        journal.append(String(line.prefix(160)))
        if journal.count > Self.journalLimit {
            journal.removeFirst(journal.count - Self.journalLimit)
        }
    }

    func requestConfirmation(_ request: GeneratedViewConfirmRequest) async -> Bool {
        // One question at a time: a second one while the first is open is declined.
        guard confirmation == nil else { return false }
        return await withCheckedContinuation { continuation in
            confirmation = continuation
            confirmRequest = request
        }
    }

    func answerConfirmation(_ confirmed: Bool) {
        confirmRequest = nil
        confirmation?.resume(returning: confirmed)
        confirmation = nil
    }
}

/// The card models of every open board window. Weak on the board: a closed
/// board's models stop and go away at the next lookup.
@MainActor
final class GeneratedViewModels {
    static let shared = GeneratedViewModels()

    /// The secret props of the Rafu catalog, read once.
    static let secretProps = GeneratedViewStatePersistence.secretProps(of: RafuCatalog.rafu)

    private struct Entry {
        weak var board: CanvasBoardState?
        var models: [CanvasCardID: GeneratedViewCardModel]
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    /// The card's model, made on first use. Cheap when it exists, so a view
    /// body may call it; it reads no observable board state.
    func model(
        for cardID: CanvasCardID, board: CanvasBoardState, session: WorkspaceSession?
    ) -> GeneratedViewCardModel {
        let key = ObjectIdentifier(board)
        if let entry = entries[key], entry.board === board, let model = entry.models[cardID] {
            if let session { model.adopt(session) }
            return model
        }
        if let entry = entries[key], entry.board !== board {
            for model in entry.models.values { model.stop() }
            entries[key] = nil
        }
        let model = GeneratedViewCardModel(cardID: cardID, board: board, session: session)
        var entry = entries[key] ?? Entry(board: board, models: [:])
        entry.models[cardID] = model
        entries[key] = entry
        return model
    }

    func existing(_ cardID: CanvasCardID, on board: CanvasBoardState) -> GeneratedViewCardModel? {
        guard let entry = entries[ObjectIdentifier(board)], entry.board === board else {
            return nil
        }
        return entry.models[cardID]
    }

    /// Drops the models of closed boards and of cards that left their board.
    func prune() {
        for (key, entry) in entries {
            guard let board = entry.board else {
                for model in entry.models.values { model.stop() }
                entries[key] = nil
                continue
            }
            let present = Set(board.cards.map(\.id))
            var kept = entry.models
            for (id, model) in entry.models where !present.contains(id) {
                model.stop()
                kept[id] = nil
            }
            if kept.count != entry.models.count { entries[key]?.models = kept }
        }
    }
}

extension GeneratedViewCardModel {
    /// Resets the live store to the spec's seed when nothing was saved yet
    /// (Reset View with no document state to clear).
    func resetLiveState() {
        resetNotice = nil
        stateNotSaved = false
        let seed = spec?.state
        Task { await self.resetStore(to: seed) }
    }
}
