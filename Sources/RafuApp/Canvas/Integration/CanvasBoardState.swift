import AppKit
import Foundation
import Observation
import RafuCore
import SwiftUI

/// Which links the board draws. W6b's edge layer reads `linkVisibility`.
enum CanvasLinkVisibility: String, CaseIterable, Sendable {
    case all
    case messageOnly
    case none

    var title: String {
        switch self {
        case .all: "All"
        case .messageOnly: "Message Links Only"
        case .none: "None"
        }
    }
}

/// Only metadata changes are observed. Native note owners supply text snapshots
/// for saves; their live buffers never flow through Observation.
@Observable
@MainActor
final class CanvasBoardState: Identifiable {
    /// The one SF Symbol that stands for an Ensemble wherever the board
    /// needs an identity glyph (the empty-board tip, tabs, launchers).
    nonisolated static let ensembleSymbol = "circle.hexagongrid"

    let id: CanvasID
    @ObservationIgnored private var document: CanvasDocument
    private(set) var changeStamp: UInt64 = 0
    private(set) var isDirty = false
    var isSaving = false
    /// When the last save that left the board clean finished. The tab shows
    /// a brief saved tick for each new value (UX Round C, W2).
    private(set) var lastSavedAt: Date?
    @ObservationIgnored private var lastSavedContent: SavedContent
    /// Why the last save, reload, or Save Copy failed. Only the store's save
    /// paths write it; the save-failure banner (Save Again, Save Copy,
    /// Reload) is its only reader. Every other message is a `notice`.
    var saveFailureMessage: String?
    /// A short message about the last action (a refused drop, a failed edit,
    /// copied images). View state, never saved. One at a time: a new notice
    /// replaces the old one. The next successful edit, a click, Escape, or
    /// the view's timer dismisses it.
    var notice: CanvasBoardNotice?
    /// The hover preview of the drag that is over this board now: a ghost
    /// card, an edge band, or a board highlight. View state, never saved.
    /// The ONE owner for both drop halves (the SwiftUI delegate and the
    /// AppKit `CanvasScrollBridge`): each writes here, and every way a drag
    /// session ends calls `clearDropPreview()`.
    var dropPreview: CanvasDropPreview?
    /// External images that wait for the user's consent before Rafu copies
    /// them into the workspace. The board view shows the confirmation.
    var pendingAssetImport: CanvasAssetImportRequest?
    /// A non-empty card selection always clears the edge selection, by any
    /// path (a marquee, Select All, an agent), so Delete never acts on a
    /// stale edge and a cleared selection never brings an old edge back.
    var selection: Set<CanvasCardID> = [] {
        didSet {
            if !selection.isEmpty, selectedConnectionID != nil { selectedConnectionID = nil }
        }
    }
    var focusedCardID: CanvasCardID?
    var contentIsActive = false
    var visibleSize: CGSize = .zero
    var connectingFrom: CanvasCardID?
    /// View state, not saved: the "Show Links" choice (review 7.6).
    var linkVisibility: CanvasLinkVisibility = .all
    /// View state, not saved: the Find in Ensemble popover is open. While it
    /// is, its text field owns the keys (`CanvasInlineRename.boardTakesKeys`).
    var isFindPresented = false
    /// The card whose title is being renamed inline in its header.
    var renamingCardID: CanvasCardID?
    /// Set by Return, the header or the menu to ask the terminal card to start
    /// (or restart) its shell. The card clears it. Starting is always an
    /// explicit user action; nothing sets this on its own.
    var terminalStartRequest: CanvasCardID?
    /// Lines an agent asked Rafu to type into a terminal node whose shell is
    /// not ready. Held in order, a few per node, and dropped when they get
    /// old, when the node goes, or when the board closes. Never saved, never
    /// logged, and not observed: the terminal card and the agent tools drain it.
    @ObservationIgnored var pendingTerminalLines: [CanvasCardID: [PendingTerminalLine]] = [:]
    /// Focus-time bookkeeping for Tidy Up. Durations and dates per card; no
    /// text. Not observed and never touched inside an edit or a gesture: the
    /// board view reports coarse focus transitions only.
    @ObservationIgnored private var attentionClock = CanvasAttentionClock()
    /// What the sidecar held when the board opened or last flushed.
    @ObservationIgnored private(set) var attentionSaved: CanvasAttention.Records = [:]
    /// Focus time since the last flush.
    @ObservationIgnored private(set) var attentionPending: CanvasAttention.Records = [:]
    /// False while the board view is hidden or the app is in the background.
    @ObservationIgnored private var attentionIsRunning = false
    @ObservationIgnored private var lastAttentionFlush: Date?
    /// Asks the store to write `attentionPending`. Set by the store.
    @ObservationIgnored var requestAttentionFlush: (@MainActor () -> Void)?
    /// Nodes with a drain loop running, so one node never has two.
    @ObservationIgnored var terminalLineDrains: Set<CanvasCardID> = []
    /// Board-space point for the next added card, set by the Add popover and
    /// consumed by `add`. Any other path to add a card clears it first.
    @ObservationIgnored var creationCenter: CGPoint?
    /// False while a keyboard add (N, T) runs, so its card appears with no
    /// spring (`withoutCreationMotion`). Never saved.
    @ObservationIgnored private(set) var creationIsAnimated = true
    /// True until the board view first reports a non-zero size; then
    /// `arriveIfNeeded` fits a board that would open with nothing in view
    /// (UX Round A, B1). A new board object (open, restore, reload) starts
    /// true.
    @ObservationIgnored var arrivalPending = true
    /// The cards that just landed by a drop. The board view draws one
    /// set-down ring around each and clears it (S1). View state, never saved.
    var landing: CanvasLanding?
    @ObservationIgnored private var lastCreatedOrigin: CGPoint?
    @ObservationIgnored var noteSnapshots: [CanvasCardID: @MainActor () throws -> String] = [:]
    @ObservationIgnored var requestSave: (@MainActor () -> Void)?
    @ObservationIgnored var revokeSessionLinks: (([UUID]) -> Void)?
    @ObservationIgnored var stopLiveContent: (@MainActor () -> Void)?
    @ObservationIgnored var saveTask: Task<Bool, Never>?
    /// Fires after `performUndo()`/`performRedo()` swaps `document`, naming
    /// the cards that disappeared and the cards that (re)appeared, matched by
    /// id. `WorkspaceSession` uses this to restore or re-park a moved
    /// Terminal Group's editor tab (ADR 0025's 2026-10-19 amendment). A
    /// plain callback, not board state.
    @ObservationIgnored var undoRedoObserver:
        ((_ removed: [CanvasCard], _ added: [CanvasCard]) -> Void)?
    @ObservationIgnored private var undo: [CanvasDocument] = []
    @ObservationIgnored private var redo: [CanvasDocument] = []
    @ObservationIgnored private var gestureStart: CanvasDocument?
    /// The rects a move or resize shows before it commits. A separate
    /// observable, so a drag frame does not invalidate every view that reads
    /// `cards`, `viewport` or `changeStamp` (every card's body).
    let liveGeometry = CanvasLiveGeometry()

    init(document: CanvasDocument) {
        id = document.id
        var value = document
        // A board saved before frame bounds were derived may hold a frame
        // that no longer fits. This is not an edit: the next save keeps it.
        CanvasBoardState.normalizeFrames(&value, previous: nil)
        self.document = value
        lastSavedContent = SavedContent(value)
    }

    /// What the saved tick compares: everything but the viewport and the
    /// revision.
    private struct SavedContent: Equatable {
        let title: String
        let cards: [CanvasCard]
        let connections: [CanvasConnection]

        init(_ document: CanvasDocument) {
            title = document.title
            cards = document.cards
            connections = document.connections
        }
    }

    var title: String {
        _ = changeStamp
        return document.title
    }
    var cards: [CanvasCard] {
        _ = changeStamp
        return document.cards
    }
    var connections: [CanvasConnection] {
        _ = changeStamp
        return document.connections
    }
    var viewport: CanvasViewport {
        _ = changeStamp
        return document.viewport
    }
    var revision: UInt64 { document.revision }
    var canUndo: Bool {
        _ = changeStamp
        return !undo.isEmpty
    }
    var canRedo: Bool {
        _ = changeStamp
        return !redo.isEmpty
    }
    var focusedCard: CanvasCard? { cards.first { $0.id == focusedCardID } }

    var retainedNoteIDs: Set<CanvasCardID> {
        Set(
            ([document] + undo + redo).flatMap {
                $0.cards.compactMap { card -> CanvasCardID? in
                    if case .note = card.content { card.id } else { nil }
                }
            })
    }

    func snapshot() throws -> CanvasDocument {
        var value = document
        for index in value.cards.indices {
            let card = value.cards[index]
            if case .note = card.content, let takeSnapshot = noteSnapshots[card.id] {
                value.cards[index].content = .note(snapshot: try takeSnapshot())
            }
        }
        try value.validate()
        return value
    }

    func refreshResources(_ prepare: ((inout CanvasDocument) -> Void)?) {
        var value = document
        prepare?(&value)
        if value != document {
            document = value
            markDirty()
        }
    }

    func acceptSaved(_ saved: CanvasDocument, stamp: UInt64, at date: Date = Date()) {
        document.revision = saved.revision
        if changeStamp == stamp {
            document = saved
            isDirty = false
            // A pan or zoom also saves; only a change the user made to the
            // cards, links or name shows the saved tick.
            let content = SavedContent(saved)
            if content != lastSavedContent {
                lastSavedContent = content
                lastSavedAt = date
            }
        }
        isSaving = false
    }

    func markNoteEdited() {
        markDirty()
        requestSave?()
    }

    func edit(_ action: (inout CanvasDocument) throws -> Void) throws {
        var changed = document
        try action(&changed)
        Self.normalizeFrames(&changed, previous: document)
        try changed.validate()
        guard changed != document else { return }
        remember(document, in: &undo)
        redo.removeAll()
        revokeChangedLinks(replacing: changed)
        document = changed
        prunePendingTerminalLines()
        notice = nil
        clearDropPreview()
        markDirty()
        requestSave?()
    }

    /// Ends the drop hover preview. Idempotent, so every end-of-drag hook
    /// can call it without checking which half drew the preview.
    func clearDropPreview() {
        if dropPreview != nil { dropPreview = nil }
    }

    /// Writes the hover preview only when it changed, so a drag that hovers
    /// in one place does not invalidate the board view on every tick.
    func updateDropPreview(_ preview: CanvasDropPreview?) {
        if CanvasDropPreview.changed(from: dropPreview, to: preview) { dropPreview = preview }
    }

    /// Shows `message` as the board's notice, replacing any other notice.
    func showNotice(
        _ message: String, tone: CanvasBoardNotice.Tone = .warn,
        action: CanvasBoardNotice.Action? = nil
    ) {
        notice = CanvasBoardNotice(message: message, tone: tone, action: action)
    }

    func dismissNotice() {
        if notice != nil { notice = nil }
    }

    /// The name older code (and code owned by other work) still writes.
    /// Writing it shows a warning notice; it never reaches the save-failure
    /// banner. New code calls `showNotice` or sets `saveFailureMessage`.
    var errorMessage: String? {
        get { notice?.message }
        set {
            if let newValue { showNotice(newValue) } else { dismissNotice() }
        }
    }

    /// Adds a card. With `center` (board units) the card appears centred on
    /// that point, and lands with the set-down ring (`landing`). Otherwise it
    /// appears at the middle of the visible board, stepping 24 pt from the
    /// previous new card; a board that has not been laid out yet keeps the
    /// older cascade. `animated` false (or `withoutCreationMotion`) skips the
    /// creation spring. Returns the new card's id.
    @discardableResult
    func add(
        title: String, content: CanvasCardContent, center: CGPoint? = nil, animated: Bool = true
    ) throws -> CanvasCardID {
        guard cards.count < CanvasLimits.cards else { throw CanvasError.capacity }
        // An explicit centre is a drop: it lands on the nearest free spot,
        // where its ghost was. A menu's `creationCenter` is exact.
        let isDrop = center != nil
        let center = center ?? creationCenter
        creationCenter = nil
        let size = CanvasBoardDropGeometry.defaultSize(for: content)
        var rect: CanvasRect
        if let center {
            rect =
                isDrop
                ? CanvasBoardDropGeometry.freeRect(
                    for: content, centeredAt: center,
                    avoiding: CanvasBoardDropGeometry.obstacles(in: cards))
                : CanvasBoardDropGeometry.defaultRect(for: content, centeredAt: center)
        } else {
            rect = CanvasRect(x: 40, y: 40, width: size.width, height: size.height)
            if visibleSize.width > 0, visibleSize.height > 0 {
                let scale = document.viewport.scale
                rect.x =
                    (Double(visibleSize.width) / 2 - document.viewport.x) / scale - rect.width / 2
                rect.y =
                    (Double(visibleSize.height) / 2 - document.viewport.y) / scale - rect.height / 2
                while let last = lastCreatedOrigin, abs(last.x - rect.x) < 1,
                    abs(last.y - rect.y) < 1
                {
                    rect.x += 24
                    rect.y += 24
                }
                lastCreatedOrigin = CGPoint(x: rect.x, y: rect.y)
            } else {
                let offset = Double(cards.count % 5) * 36
                rect.x += offset
                rect.y += offset
            }
            rect.x = min(50_000, max(-50_000, rect.x.rounded()))
            rect.y = min(50_000, max(-50_000, rect.y.rounded()))
        }
        let card = CanvasCard(title: title, rect: rect, content: content)
        if animated, creationIsAnimated {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            try withAnimation(
                RafuMotion.resolve(
                    RafuMotion.nodeCreate, reduceMotion: reduceMotion,
                    reduced: RafuMotion.reducedFade)
            ) {
                try edit { $0.cards.append(card) }
            }
        } else {
            // Keyboard creation (N, T) is immediate: no spring, no transition.
            try edit { $0.cards.append(card) }
        }
        if isDrop { landing = CanvasLanding(ids: [card.id]) }
        select([card.id])
        return card.id
    }

    /// Runs `body` (a keyboard add) so the card it adds appears with no
    /// motion. The add paths are synchronous, so the flag never outlives it.
    func withoutCreationMotion(_ body: () -> Void) {
        creationIsAnimated = false
        defer { creationIsAnimated = true }
        body()
    }

    /// Fits a board that just opened with nothing to look at: zoomed out past
    /// the hand-zoom floor, or with every card out of view (UX Round A, B1).
    /// Runs once per board object, on the first non-zero `visibleSize`. A
    /// board with a card in view keeps the viewport the user parked.
    func arriveIfNeeded() {
        guard arrivalPending, visibleSize.width > 0, visibleSize.height > 0 else { return }
        arrivalPending = false
        let rects = document.cards.map(\.rect)
        guard
            CanvasArrival.needsFit(
                cards: rects, viewport: document.viewport, visible: visibleSize)
        else { return }
        applyArrivalViewport(CanvasArrival.fittedViewport(cards: rects, visible: visibleSize))
    }

    /// Writes the arrival viewport WITHOUT marking the board dirty and
    /// without a save: opening a `.rafuensemble` file board must never make
    /// it Git-modified. The change stamp still moves so views redraw; the
    /// next real edit saves the fitted viewport with it.
    private func applyArrivalViewport(_ value: CanvasViewport) {
        guard value.isValid, value != document.viewport else { return }
        document.viewport = value
        changeStamp &+= 1
    }

    func removeSelection() throws {
        let removing = selection
        leaveContent()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try withAnimation(
            RafuMotion.resolve(
                RafuMotion.nodeRemove, reduceMotion: reduceMotion, reduced: RafuMotion.reducedFade)
        ) {
            try edit {
                $0.cards.removeAll { removing.contains($0.id) }
                $0.connections.removeAll { removing.contains($0.from) || removing.contains($0.to) }
            }
        }
        if let focusedCardID, removing.contains(focusedCardID) { self.focusedCardID = nil }
        selection = []
    }

    func connect(to id: CanvasCardID, label: String = "Related to") throws {
        guard let from = connectingFrom, from != id else {
            connectingFrom = id
            return
        }
        guard connections.count < CanvasLimits.connections else { throw CanvasError.capacity }
        try edit { $0.connections.append(.init(from: from, to: id, label: label)) }
        connectingFrom = nil
    }

    func addConnection(
        from: CanvasCardID, to: CanvasCardID, label: String = "Related to",
        behavior: CanvasConnectionBehavior = .related
    ) throws {
        guard connections.count < CanvasLimits.connections else { throw CanvasError.capacity }
        try edit {
            $0.connections.append(.init(from: from, to: to, label: label, behavior: behavior))
        }
    }

    func beginGesture() { if gestureStart == nil { gestureStart = document } }

    func setRect(_ rect: CanvasRect, for id: CanvasCardID) { setRects([id: rect]) }

    /// Sets several card rects in one step (a group drag), then refits the
    /// frames. The surrounding gesture owns the undo step. Invalid rects are
    /// ignored.
    func setRects(_ rects: [CanvasCardID: CanvasRect]) {
        var value = document
        var changed = false
        for index in value.cards.indices {
            guard let rect = rects[value.cards[index].id], rect.isValid,
                value.cards[index].rect != rect
            else { continue }
            value.cards[index].rect = rect
            changed = true
        }
        guard changed else { return }
        Self.normalizeFrames(&value, previous: document)
        guard value != document else { return }
        document = value
        markDirty()
    }

    /// Shows `rects` for a move or resize in progress without editing the
    /// document. Frames refit around moved members exactly as the commit
    /// will (`normalizeFrames` against the stored document), so a frame
    /// still grows while a member is dragged. An invalid rect keeps the
    /// card's last live rect, as `setRects` keeps the last stored one.
    func showLiveRects(_ rects: [CanvasCardID: CanvasRect]) {
        var value = document
        var changed = false
        for index in value.cards.indices {
            let id = value.cards[index].id
            guard let requested = rects[id] else { continue }
            guard let rect = requested.isValid ? requested : liveGeometry.rect(for: id),
                value.cards[index].rect != rect
            else { continue }
            value.cards[index].rect = rect
            changed = true
        }
        guard changed else {
            liveGeometry.clear()
            return
        }
        Self.normalizeFrames(&value, previous: document)
        var stored: [CanvasCardID: CanvasRect] = [:]
        for card in document.cards { stored[card.id] = card.rect }
        var live: [CanvasCardID: CanvasRect] = [:]
        for card in value.cards where stored[card.id] != card.rect {
            live[card.id] = card.rect
        }
        liveGeometry.set(live)
    }

    /// The rect a card shows now: its live rect during a move or resize,
    /// otherwise its stored rect.
    func shownRect(of id: CanvasCardID) -> CanvasRect? {
        liveGeometry.rect(for: id) ?? document.cards.first { $0.id == id }?.rect
    }

    /// Ends the live phase: writes `rects` in one step (the surrounding
    /// gesture still owns the undo step) and drops the live rects in the
    /// same turn, so the cards never show a stale position in between.
    func commitLiveRects(_ rects: [CanvasCardID: CanvasRect]) {
        setRects(rects)
        liveGeometry.clear()
    }

    /// The single choke point for derived frame bounds: every edit, gesture
    /// step and raise passes through it, inside the same undo step. Members
    /// follow a frame that moved on its own, each frame then fits its members,
    /// and frames go behind their members (`CanvasFrameLayout.normalized`).
    static func normalizeFrames(_ value: inout CanvasDocument, previous: CanvasDocument?) {
        guard value.cards.contains(where: { $0.content.diagramFrame != nil }) else { return }
        let nodes = CanvasFrameLayout.nodes(value.cards)
        let result = CanvasFrameLayout.normalized(
            nodes, previous: previous.map { CanvasFrameLayout.nodes($0.cards) })
        guard result != nodes else { return }
        var byID: [CanvasCardID: CanvasCard] = [:]
        for card in value.cards {
            // Duplicate ids: validation rejects the document anyway.
            guard byID.updateValue(card, forKey: card.id) == nil else { return }
        }
        value.cards = result.compactMap { node in
            guard var card = byID[node.id] else { return nil }
            card.rect = node.rect
            return card
        }
    }

    func endGesture() {
        // A gesture never leaves live rects behind, even one that ended
        // without its commit (the card went away mid-drag).
        liveGeometry.clear()
        if let original = gestureStart, original != document {
            remember(original, in: &undo)
            redo.removeAll()
            requestSave?()
        }
        gestureStart = nil
    }

    func setViewport(_ value: CanvasViewport) {
        guard value.isValid, value != document.viewport else { return }
        document.viewport = value
        markDirty()
        requestSave?()
    }

    /// Tidy Up: groups related cards into clusters (linked cards stay together,
    /// the most attended card in the middle), then zooms to fit. The move is one
    /// undo step; the zoom is a viewport change and is not.
    func arrange(now: Date = Date()) throws {
        let scores = attentionScores(at: now)
        let nodes = document.cards.map {
            CanvasClusterLayout.Node(
                id: $0.id, rect: $0.rect, frameMembers: $0.content.diagramFrame?.memberIDs,
                isDrawing: $0.content.isWhiteboardDrawing)
        }
        let aspect =
            visibleSize.width > 0 && visibleSize.height > 0
            ? Double(visibleSize.width / visibleSize.height) : 1.6
        let placed = CanvasClusterLayout.clustered(
            nodes: nodes, edges: document.connections.map { ($0.from, $0.to) },
            attention: scores.seconds, lastFocused: scores.lastFocused, targetAspect: aspect)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        try withAnimation(RafuMotion.resolve(RafuMotion.zoomToFit, reduceMotion: reduceMotion)) {
            try edit { value in
                for index in value.cards.indices {
                    if let rect = placed[value.cards[index].id], rect.isValid {
                        value.cards[index].rect = rect
                    }
                }
            }
        }
        fitAll()
    }

    // MARK: Attention

    /// The board view reports a change of the focused card or of whether its
    /// content is open. Time is counted per transition, never per frame.
    func attentionFocusChanged(now: Date = Date()) {
        moveAttentionClock(now: now)
    }

    /// The board view is hidden or the app went to the background.
    func suspendAttention(now: Date = Date()) {
        attentionIsRunning = false
        moveAttentionClock(now: now)
    }

    /// The board view is shown again and the app is active.
    func resumeAttention(now: Date = Date()) {
        attentionIsRunning = true
        moveAttentionClock(now: now)
    }

    private func moveAttentionClock(now: Date) {
        let focus =
            attentionIsRunning
            ? focusedCardID.map { CanvasAttentionFocus(card: $0, contentIsActive: contentIsActive) }
            : nil
        guard let sample = attentionClock.move(to: focus, at: now) else { return }
        record(sample, now: now)
    }

    private func record(_ sample: CanvasAttentionClock.Sample, now: Date) {
        attentionPending = CanvasAttention.merged(
            attentionPending, adding: [sample.card: sample.record])
        // Routine flushes are throttled; boundaries flush on their own.
        if lastAttentionFlush.map({
            now.timeIntervalSince($0) >= CanvasLimits.attentionFlushInterval
        })
            ?? true
        {
            requestAttentionFlush?()
        }
    }

    /// Hands the focus time since the last flush to the caller, including the
    /// stretch that is still running.
    func takeAttentionDelta(now: Date = Date()) -> CanvasAttention.Records {
        if let sample = attentionClock.fold(at: now) {
            attentionPending = CanvasAttention.merged(
                attentionPending, adding: [sample.card: sample.record])
        }
        let delta = attentionPending
        attentionPending = [:]
        lastAttentionFlush = now
        return delta
    }

    /// A flush could not write: keep the time for the next one.
    func restoreAttentionDelta(_ delta: CanvasAttention.Records) {
        attentionPending = CanvasAttention.merged(attentionPending, adding: delta)
    }

    /// The sidecar's records, as loaded at open or returned by a flush.
    func adoptSavedAttention(_ records: CanvasAttention.Records) {
        attentionSaved = records
    }

    /// Decayed attention seconds and last-focused dates for every card, with
    /// unflushed time and the running stretch included.
    func attentionScores(at now: Date = Date())
        -> (seconds: [CanvasCardID: Double], lastFocused: [CanvasCardID: Date])
    {
        var pending = attentionPending
        if let sample = attentionClock.preview(at: now) {
            pending = CanvasAttention.merged(pending, adding: [sample.card: sample.record])
        }
        return CanvasAttention.scores(
            CanvasAttention.merged(attentionSaved, adding: pending), at: now)
    }

    /// Moves the cards to the end (front) or start (back) of the stack. The
    /// array order is the z-order, so this is an undoable edit.
    func reorder(_ ids: Set<CanvasCardID>, toFront: Bool) throws {
        guard !ids.isEmpty else { return }
        try edit { value in
            value.cards = CanvasLayoutMath.reordered(value.cards, moving: ids, toFront: toFront)
        }
    }

    /// Raises cards inside a drag. The drag's own undo step covers the change,
    /// so a click-drag that also reorders is still one undo.
    func raiseDuringGesture(_ ids: Set<CanvasCardID>) {
        guard !ids.isEmpty else { return }
        beginGesture()
        var value = document
        value.cards = CanvasLayoutMath.reordered(document.cards, moving: ids, toFront: true)
        Self.normalizeFrames(&value, previous: document)
        guard value != document else { return }
        document = value
        markDirty()
    }

    var frontmostCardID: CanvasCardID? { cards.last?.id }

    /// Selects exactly `ids`. A new card selection clears any link selection.
    func select(_ ids: Set<CanvasCardID>) {
        if selection != ids { selection = ids }
        if !ids.isEmpty { clearConnectionSelection() }
    }

    func moveSelection(dx: Double, dy: Double) throws {
        try edit { value in
            for index in value.cards.indices where selection.contains(value.cards[index].id) {
                value.cards[index].rect.x = min(
                    50_000, max(-50_000, value.cards[index].rect.x + dx))
                value.cards[index].rect.y = min(
                    50_000, max(-50_000, value.cards[index].rect.y + dy))
            }
        }
    }

    func focus(_ id: CanvasCardID) {
        guard cards.contains(where: { $0.id == id }) else { return }
        selection = [id]
        focusedCardID = id
        contentIsActive = true
    }

    func leaveContent() {
        stopLiveContent?()
        contentIsActive = false
    }

    func backToBoard() {
        leaveContent()
        focusedCardID = nil
    }

    func performUndo() {
        guard var previous = undo.popLast() else { return }
        leaveContent()
        remember(document, in: &redo)
        previous.revision = document.revision
        previous.agentControl = document.agentControl
        revokeChangedLinks(replacing: previous)
        let before = document.cards
        document = previous
        selection.formIntersection(Set(document.cards.map(\.id)))
        focusedCardID = nil
        dismissNotice()
        markDirty()
        requestSave?()
        notifyUndoRedo(before: before, after: document.cards)
    }

    func performRedo() {
        guard var next = redo.popLast() else { return }
        leaveContent()
        remember(document, in: &undo)
        next.revision = document.revision
        next.agentControl = document.agentControl
        revokeChangedLinks(replacing: next)
        let before = document.cards
        document = next
        selection.formIntersection(Set(document.cards.map(\.id)))
        focusedCardID = nil
        dismissNotice()
        markDirty()
        requestSave?()
        notifyUndoRedo(before: before, after: document.cards)
    }

    private func notifyUndoRedo(before: [CanvasCard], after: [CanvasCard]) {
        guard let undoRedoObserver else { return }
        let beforeIDs = Set(before.map(\.id))
        let afterIDs = Set(after.map(\.id))
        let removed = before.filter { !afterIDs.contains($0.id) }
        let added = after.filter { !beforeIDs.contains($0.id) }
        guard !removed.isEmpty || !added.isEmpty else { return }
        undoRedoObserver(removed, added)
    }

    private func revokeChangedLinks(replacing next: CanvasDocument) {
        let revoked = document.connections.filter { old in
            !next.connections.contains(where: {
                $0.id == old.id && $0.from == old.from && $0.to == old.to
                    && $0.behavior == old.behavior
            })
        }.map(\.id)
        if !revoked.isEmpty { revokeSessionLinks?(revoked) }
    }

    // MARK: Agent control (X4)

    /// The saved per-Ensemble Agent control. Undo and redo never change it.
    var agentControlMode: CanvasAgentControlMode {
        _ = changeStamp
        return document.agentControl?.mode ?? .ask
    }

    /// A setting change, not an edit: it is saved but is not an undo step.
    func setAgentControlMode(_ mode: CanvasAgentControlMode) {
        guard mode != agentControlMode else { return }
        document.agentControl = CanvasAgentControl(mode: mode)
        markDirty()
        requestSave?()
    }

    private func markDirty() {
        changeStamp &+= 1
        isDirty = true
    }

    /// Conservative accounting also bounds retained note snapshots in history.
    private func remember(_ value: CanvasDocument, in history: inout [CanvasDocument]) {
        history.append(value)
        func cost(_ item: CanvasDocument) -> Int {
            item.cards.reduce(1_024 + item.connections.count * 256) { sum, card in
                if case .note(let text) = card.content { return sum + 1_024 + text.utf8.count }
                return sum + 5_120
            }
        }
        var bytes = history.reduce(0) { $0 + cost($1) }
        while history.count > 32 || bytes > 2 * 1_024 * 1_024 {
            bytes -= cost(history.removeFirst())
        }
    }

    // MARK: Edge interaction (W6b)
    /// The selected edge. Selecting a card clears it (`clearConnectionSelection()`).
    var selectedConnectionID: UUID?
    /// The edge under the pointer; drawn emphasized, still below every card.
    var hoveredConnectionID: UUID?
    /// The edge whose label popover is open, and whether it was just created.
    var labelEditorConnectionID: UUID?
    var labelEditorIsForNewConnection = false
}

/// A short, dismissible message over the board, separate from the save-failure
/// banner. Identity is per posting, so the same text posted twice restarts the
/// auto-dismiss timer.
nonisolated struct CanvasBoardNotice: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable { case info, warn }

    /// One optional button, such as "Show in Finder".
    struct Action: Sendable {
        let title: String
        let perform: @MainActor @Sendable () -> Void
    }

    let id = UUID()
    let message: String
    let tone: Tone
    let action: Action?

    /// How long the notice stays when nothing else dismisses it.
    static let lifetime: Duration = .seconds(8)

    init(message: String, tone: Tone = .warn, action: Action? = nil) {
        self.message = message
        self.tone = tone
        self.action = action
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// The cards one drop just landed, for the set-down ring (UX Round A, S1).
/// A new token restarts the ring, also for the same ids.
nonisolated struct CanvasLanding: Equatable, Sendable {
    /// The haptic channel of a landing; it throttles, so a batch plays once.
    static let hapticChannel = "landing"
    /// The most rings one landing draws.
    static let maximumRings = 12

    let ids: [CanvasCardID]
    let token: UUID

    init(ids: [CanvasCardID], token: UUID = UUID()) {
        self.ids = ids
        self.token = token
    }
}
