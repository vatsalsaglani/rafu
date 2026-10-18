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
    @ObservationIgnored private(set) var apps: [CanvasCardID: CanvasNativeAppController] = [:]
    @ObservationIgnored private var visibleApps: [CanvasCardID: Set<UUID>] = [:]
    private(set) var isWindowAvailable = true
    var isPresented: Bool { owner != nil }
    var permitsLiveContent: Bool { isPresented && isWindowAvailable }

    init(board: CanvasBoardState, session: WorkspaceSession) {
        self.board = board
        self.session = session
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
    func nativeApp(for card: CanvasCard) -> CanvasNativeAppController? {
        if let value = apps[card.id] { return value }
        guard case .nativeApp(let bundleID) = card.content else { return nil }
        // Docking has its own limit and checks `permitsLiveContent` itself.
        let value = CanvasNativeAppController(bundleID: bundleID, cardID: card.id)
        apps[card.id] = value
        return value
    }
    func showNative(_ id: CanvasCardID, owner: UUID) { visibleApps[id, default: []].insert(owner) }
    func hideNative(_ id: CanvasCardID, owner: UUID) {
        visibleApps[id]?.remove(owner)
        Task { [weak self] in
            await Task.yield()
            guard let self, visibleApps[id]?.isEmpty != false else { return }
            apps[id]?.stop()
        }
    }
    func prune() {
        guard let board else { return }
        let retained = board.retainedNoteIDs
        for id in Array(notes.keys) where !retained.contains(id) {
            notes[id] = nil
            board.noteSnapshots[id] = nil
        }
        let current = Set(board.cards.map(\.id))
        for id in Array(webs.keys) where !current.contains(id) {
            webs[id]?.stop()
            webs[id] = nil
        }
        for id in Array(apps.keys) where !current.contains(id) {
            apps[id]?.stop()
            apps[id] = nil
            visibleApps[id] = nil
        }
    }
    func stop(cards: Set<CanvasCardID>) {
        for id in cards {
            webs[id]?.stop()
            apps[id]?.stop()
            webs[id] = nil
            apps[id] = nil
        }
        leaveInteractiveContent()
    }
    func pause() {
        isWindowAvailable = false
        stopAll()
    }
    func windowBecameAvailable() { isWindowAvailable = true }
    func stopAll() {
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
        for app in apps.values { app.stop() }
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
    }
}

extension WorkspaceSession {
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
            canvas.boards[boardID]?.errorMessage =
                "Two web previews are already open. Stop one first."
            return
        }
        web.connect()
    }
}
