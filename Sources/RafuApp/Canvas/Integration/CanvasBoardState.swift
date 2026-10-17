import Foundation
import Observation

/// Only metadata changes are observed. Native note owners supply text snapshots
/// for saves; their live buffers never flow through Observation.
@Observable
@MainActor
final class CanvasBoardState: Identifiable {
    let id: CanvasID
    @ObservationIgnored private var document: CanvasDocument
    private(set) var changeStamp: UInt64 = 0
    private(set) var isDirty = false
    var isSaving = false
    var errorMessage: String?
    var selection: Set<CanvasCardID> = []
    var focusedCardID: CanvasCardID?
    var contentIsActive = false
    var showsList = false
    var visibleSize: CGSize = .zero
    var connectingFrom: CanvasCardID?
    @ObservationIgnored var noteSnapshots: [CanvasCardID: @MainActor () throws -> String] = [:]
    @ObservationIgnored var requestSave: (@MainActor () -> Void)?
    @ObservationIgnored var stopLiveContent: (@MainActor () -> Void)?
    @ObservationIgnored var saveTask: Task<Bool, Never>?
    @ObservationIgnored private var undo: [CanvasDocument] = []
    @ObservationIgnored private var redo: [CanvasDocument] = []
    @ObservationIgnored private var gestureStart: CanvasDocument?

    init(document: CanvasDocument) {
        id = document.id
        self.document = document
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

    func acceptSaved(_ saved: CanvasDocument, stamp: UInt64) {
        document.revision = saved.revision
        if changeStamp == stamp {
            document = saved
            isDirty = false
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
        try changed.validate()
        guard changed != document else { return }
        remember(document, in: &undo)
        redo.removeAll()
        document = changed
        markDirty()
        requestSave?()
    }

    func add(title: String, content: CanvasCardContent) throws {
        guard cards.count < CanvasLimits.cards else { throw CanvasError.capacity }
        let offset = Double(cards.count % 5) * 36
        var rect = CanvasRect(x: 40 + offset, y: 40 + offset)
        switch content {
        case .terminal, .web:
            rect.width = 640
            rect.height = 420
        default: break
        }
        let card = CanvasCard(title: title, rect: rect, content: content)
        try edit { $0.cards.append(card) }
        selection = [card.id]
    }

    func removeSelection() throws {
        let removing = selection
        leaveContent()
        try edit {
            $0.cards.removeAll { removing.contains($0.id) }
            $0.connections.removeAll { removing.contains($0.from) || removing.contains($0.to) }
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

    func beginGesture() { if gestureStart == nil { gestureStart = document } }

    func setRect(_ rect: CanvasRect, for id: CanvasCardID) {
        guard rect.isValid, let index = document.cards.firstIndex(where: { $0.id == id }),
            document.cards[index].rect != rect
        else { return }
        document.cards[index].rect = rect
        markDirty()
    }

    func endGesture() {
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

    func arrange() throws {
        try edit { value in
            for index in value.cards.indices {
                value.cards[index].rect.x = 40 + Double(index % 3) * 460
                value.cards[index].rect.y = 40 + Double(index / 3) * 340
            }
        }
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
        showsList = false
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
        document = previous
        selection.formIntersection(Set(document.cards.map(\.id)))
        focusedCardID = nil
        markDirty()
        requestSave?()
    }

    func performRedo() {
        guard var next = redo.popLast() else { return }
        leaveContent()
        remember(document, in: &undo)
        next.revision = document.revision
        document = next
        selection.formIntersection(Set(document.cards.map(\.id)))
        focusedCardID = nil
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
}
