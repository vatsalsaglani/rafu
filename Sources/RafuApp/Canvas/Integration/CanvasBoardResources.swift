import AppKit
import Observation
import SwiftUI

/// Resource owners are window scoped and excluded from document persistence.
/// Native text and views stay here; the board exposes only small metadata.
@Observable
final class CanvasBoardResources {
    @ObservationIgnored weak var session: WorkspaceSession?
    @ObservationIgnored weak var board: CanvasBoardState?
    private var owner: UUID?
    @ObservationIgnored private var notes: [CanvasCardID: CanvasNoteBuffer] = [:]
    @ObservationIgnored private(set) var webs: [CanvasCardID: CanvasWebPreviewController] = [:]
    /// Cards the user switched away from their default Markdown face. View
    /// state only: it is never saved, so every reopen starts from the default.
    private(set) var markdownCardShowsSource: [CanvasCardID: Bool] = [:]
    private(set) var isWindowAvailable = true
    /// Images from the web for this Ensemble's generated views (wave 3). It
    /// makes no network session until the first allowed image asks.
    @ObservationIgnored let remoteImages: RemoteImageProvider
    var isPresented: Bool { owner != nil }
    var permitsLiveContent: Bool { isPresented && isWindowAvailable }

    init(board: CanvasBoardState, session: WorkspaceSession) {
        self.board = board
        self.session = session
        self.remoteImages = RemoteImageProvider(board: board)
        board.stopLiveContent = { [weak self] in self?.leaveInteractiveContent() }
    }
    func canPresent(owner: UUID?) -> Bool { owner != nil && self.owner == owner }
    func present(owner: UUID) { self.owner = owner }
    func hide(owner: UUID) {
        Task { [weak self] in
            await Task.yield()
            guard let self, self.owner == owner else { return }
            self.owner = nil
            stopAll()
        }
    }
    func note(for card: CanvasCard) -> CanvasNoteBuffer? {
        if let note = notes[card.id] { return note }
        guard case .note(let snapshot) = card.content else { return nil }
        let note = CanvasNoteBuffer(snapshot: snapshot)
        note.edited = { [weak board] in board?.markNoteEdited() }
        board?.noteSnapshots[card.id] = { [weak note] in try note?.snapshot() ?? snapshot }
        notes[card.id] = note
        return note
    }
    func web(for card: CanvasCard) -> CanvasWebPreviewController? {
        if let value = webs[card.id] { return value }
        guard case .web(let destination) = card.content else { return nil }
        let value = CanvasWebPreviewController(destination: destination)
        webs[card.id] = value
        return value
    }
    /// Whether a file card draws raw source. A card without a choice uses
    /// `defaultShowsSource` for its path.
    func showsSource(for card: CanvasCardID, path: String) -> Bool {
        markdownCardShowsSource[card] ?? CanvasMarkdownCard.defaultShowsSource(path: path)
    }
    func toggleSource(for card: CanvasCardID, path: String) {
        markdownCardShowsSource[card] = !showsSource(for: card, path: path)
    }
    func prune() {
        guard let board else { return }
        let retained = board.retainedNoteIDs
        for id in Array(notes.keys) where !retained.contains(id) {
            notes[id] = nil
            board.noteSnapshots[id] = nil
        }
        let current = Set(board.cards.map(\.id))
        for id in Array(markdownCardShowsSource.keys) where !current.contains(id) {
            markdownCardShowsSource[id] = nil
        }
        for id in Array(webs.keys) where !current.contains(id) {
            webs[id]?.stop()
            webs[id] = nil
        }
        session?.releaseCanvasTerminalLeasesWithoutCards(on: board)
    }
    func stop(cards: Set<CanvasCardID>) {
        for id in cards {
            markdownCardShowsSource[id] = nil
            webs[id]?.stop()
            webs[id] = nil
        }
        leaveInteractiveContent()
    }
    /// The board's window is hidden (another Space, a covering app, the
    /// screen lock). Live content stops and the terminal views go; a terminal
    /// card that had the keys is remembered, so `windowBecameAvailable` can
    /// give them back. Without that, the board took the keys and the next
    /// letter typed "into the terminal" ran a board tool.
    func pause() {
        let remembered = board.flatMap { board in
            CanvasContentFocusRestore.remembered(
                contentIsActive: board.contentIsActive, focusedCardID: board.focusedCardID,
                focusedCardIsTerminal: board.focusedCardID.map { isTerminalCard($0, on: board) }
                    ?? false,
                pending: board.contentFocusToRestore)
        }
        isWindowAvailable = false
        stopAll()
        board?.contentFocusToRestore = remembered
    }
    /// The window shows again. A terminal card that had the keys when it was
    /// hidden gets them back through the same path as a click on it: the
    /// card claims its lease and makes its terminal the first responder
    /// (`CanvasTerminalCard`, `onChange(of: active)`).
    func windowBecameAvailable() {
        isWindowAvailable = true
        guard let board, let pending = board.contentFocusToRestore else { return }
        board.contentFocusToRestore = nil
        guard
            let id = CanvasContentFocusRestore.restored(
                pending: pending, isTerminalCardOnBoard: isTerminalCard(pending, on: board))
        else { return }
        board.focus(id)
    }
    private func isTerminalCard(_ id: CanvasCardID, on board: CanvasBoardState) -> Bool {
        guard let card = board.cards.first(where: { $0.id == id }) else { return false }
        if case .terminal = card.content { return true }
        return false
    }
    func stopAll() {
        remoteImages.cancelInFlight()
        if let session, let board {
            let owned = session.canvasTerminalOwners.filter { $0.value == board.id }.map(\.key)
            for id in owned {
                session.canvasTerminalOwners[id] = nil
                // A confirmed group close can precede this deferred Canvas hide.
                guard session.terminal.terminalGroup(id) != nil else { continue }
                session.hideTerminalGroup(id)
            }
        }
        leaveInteractiveContent()
        for web in webs.values { web.stop() }
    }
    private func leaveInteractiveContent() {
        guard let session, let board else { return }
        for (id, canvasID) in session.canvasTerminalOwners where canvasID == board.id {
            for pane in session.terminal.terminalGroup(id)?.panes ?? [] {
                session.terminal.terminalController(for: pane.id)?.resignNativeFocus()
            }
        }
        for web in webs.values {
            if let view = web.webView, let first = view.window?.firstResponder as? NSView,
                first.isDescendant(of: view)
            {
                view.window?.makeFirstResponder(nil)
            }
        }
        for note in notes.values {
            if note.textView.window?.firstResponder === note.textView {
                note.textView.window?.makeFirstResponder(nil)
            }
        }
        // Hiding or leaving never sends input and never restarts a resource.
        board.contentIsActive = false
        // Leaving content, or hiding the board, ends a pending restore too
        // (`pause` sets it again after this).
        board.contentFocusToRestore = nil
    }
}

/// The keys of a terminal card across a hidden window. Before this, after a
/// Space or app switch the terminal no longer had the keys, and letters ran
/// board tools. See `docs/references/ensemble-terminal-focus-restore.md`.
nonisolated enum CanvasContentFocusRestore {
    /// The card `pause` remembers: the focused terminal card while its
    /// content has the keys, else the card a previous `pause` remembered
    /// (a second hide notification must not forget it).
    static func remembered(
        contentIsActive: Bool, focusedCardID: CanvasCardID?, focusedCardIsTerminal: Bool,
        pending: CanvasCardID?
    ) -> CanvasCardID? {
        if contentIsActive, focusedCardIsTerminal, let focusedCardID { return focusedCardID }
        return pending
    }

    /// The card to focus when the window shows again: the remembered card
    /// while it is still a terminal card on the board.
    static func restored(pending: CanvasCardID?, isTerminalCardOnBoard: Bool) -> CanvasCardID? {
        isTerminalCardOnBoard ? pending : nil
    }

    /// Card content has the keys, or a terminal card is about to get them
    /// back. The board's own keys (letters, Return, arrows, Delete, Tab)
    /// stay off while this is true.
    static func contentHoldsKeys(contentIsActive: Bool, pending: CanvasCardID?) -> Bool {
        contentIsActive || pending != nil
    }
}

extension WorkspaceSession {
    /// The lease follows the card, so a card view going away never releases
    /// it. A card that leaves the board (an undo of its add, a delete, a
    /// reload) does: this drops every lease `board` holds for a group with no
    /// terminal card on it, so the group can show in an editor tab again.
    func releaseCanvasTerminalLeasesWithoutCards(on board: CanvasBoardState) {
        let onBoard = Set(
            board.cards.compactMap { card -> TerminalGroupID? in
                if case .terminal(let id) = card.content { id } else { nil }
            })
        for (groupID, owner) in canvasTerminalOwners
        where owner == board.id && !onBoard.contains(groupID) {
            canvasTerminalOwners[groupID] = nil
        }
    }

    func installCanvasResources(for board: CanvasBoardState) {
        if canvasResources[board.id]?.board === board { return }
        canvasResources[board.id]?.stopAll()
        canvasResources[board.id] = CanvasBoardResources(board: board, session: self)
        canvas.onBoardHidden = { [weak self] id in self?.canvasResources[id]?.stopAll() }
        canvas.prepareResourceSnapshot = { [weak self] document in
            let ids = Set(
                document.cards.compactMap { card -> TerminalGroupID? in
                    if case .terminal(let id) = card.content { id } else { nil }
                })
            document.terminalGroups = self?.canvasTerminalRestoration(ids)
        }
    }
    func connectCanvasWeb(_ id: CanvasCardID, board boardID: CanvasID) {
        guard let resources = canvasResources[boardID], resources.permitsLiveContent,
            let card = canvas.boards[boardID]?.cards.first(where: { $0.id == id }),
            let web = resources.web(for: card)
        else { return }
        let count = canvasResources.values.reduce(0) {
            $0 + $1.webs.values.filter { $0.webView != nil }.count
        }
        guard count < CanvasLimits.webSurfaces else {
            canvas.boards[boardID]?.showNotice(
                "Two web previews are already open. Stop one first.")
            return
        }
        web.connect()
    }
}
