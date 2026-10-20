import Foundation

/// Edge selection and editing on a board (review 7.6). Stored properties live in
/// the `Edge interaction (W6b)` block at the end of `CanvasBoardState`.
extension CanvasBoardState {
    func connection(_ id: UUID) -> CanvasConnection? {
        connections.first { $0.id == id }
    }

    /// The selected edge, if any. Selecting a card or several cards deselects
    /// the edge (`selection.didSet`), even if a caller forgets
    /// `clearConnectionSelection()`.
    var selectedConnection: CanvasConnection? {
        guard selection.isEmpty, let id = selectedConnectionID else { return nil }
        return connection(id)
    }

    func isTerminal(_ id: CanvasCardID) -> Bool {
        guard let card = cards.first(where: { $0.id == id }) else { return false }
        if case .terminal = card.content { return true }
        return false
    }

    func bothTerminals(_ a: CanvasCardID, _ b: CanvasCardID) -> Bool {
        isTerminal(a) && isTerminal(b)
    }

    func hasConnection(from: CanvasCardID, to: CanvasCardID) -> Bool {
        CanvasConnectionRules.isIdentical(
            from: from, to: to, bothTerminals: bothTerminals(from, to), existing: connections)
    }

    /// False for the source itself, an identical existing link, or a full board.
    func canConnect(from: CanvasCardID, to: CanvasCardID) -> Bool {
        CanvasConnectionRules.canConnect(
            from: from, to: to, bothTerminals: bothTerminals(from, to), existing: connections)
    }

    // MARK: Selection

    /// Click on an edge: select it and clear the card selection.
    func selectConnection(_ id: UUID) {
        backToBoard()
        selection = []
        selectedConnectionID = id
    }

    func clearConnectionSelection() {
        selectedConnectionID = nil
        labelEditorConnectionID = nil
    }

    /// Deletes the selected edge (one undo step). Returns true if there was one.
    /// Reads `selectedConnectionID` directly: a card selection clears it
    /// (`selection.didSet`), so it is never stale here.
    @discardableResult
    func deleteSelectedConnectionIfAny() -> Bool {
        guard let id = selectedConnectionID else { return false }
        guard connection(id) != nil else {
            // The edge went away (undo, an agent): drop the stale id.
            selectedConnectionID = nil
            return false
        }
        deleteConnection(id)
        return true
    }

    // MARK: Editing (every change is one undo step)

    private func performEdgeEdit(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }

    func deleteConnection(_ id: UUID) {
        performEdgeEdit {
            try edit { $0.connections.removeAll { $0.id == id } }
        }
        if selectedConnectionID == id { selectedConnectionID = nil }
        if hoveredConnectionID == id { hoveredConnectionID = nil }
        if labelEditorConnectionID == id { labelEditorConnectionID = nil }
    }

    /// An empty label restores the placeholder, so the link shows no label.
    func setConnectionLabel(_ id: UUID, to text: String) {
        guard let edge = connection(id) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label =
            trimmed.isEmpty ? CanvasConnection.placeholderLabel(for: edge.behavior) : trimmed
        guard CanvasDocument.validTitle(label) else {
            errorMessage = "A label needs 1 to 120 characters and no control characters."
            return
        }
        performEdgeEdit {
            try edit { document in
                guard let index = document.connections.firstIndex(where: { $0.id == id }) else {
                    return
                }
                document.connections[index].label = label
            }
        }
    }

    /// Reverse Direction (relationships only).
    func reverseConnection(_ id: UUID) {
        guard let edge = connection(id), edge.behavior == .related else { return }
        performEdgeEdit {
            try edit { document in
                guard let index = document.connections.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let first = document.connections[index].from
                document.connections[index].from = document.connections[index].to
                document.connections[index].to = first
            }
        }
    }

    /// Switches a terminal pair between "Message link" and "Relationship only".
    /// Changing the behavior revokes live permission, so a message link
    /// always comes back Paused.
    func setConnectionBehavior(_ id: UUID, to behavior: CanvasConnectionBehavior) {
        guard let edge = connection(id), edge.behavior != behavior,
            behavior == .related || bothTerminals(edge.from, edge.to)
        else { return }
        performEdgeEdit {
            try edit { document in
                guard let index = document.connections.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let wasUnlabelled = document.connections[index].customLabel == nil
                document.connections[index].behavior = behavior
                if wasUnlabelled {
                    document.connections[index].label = CanvasConnection.placeholderLabel(
                        for: behavior)
                }
            }
        }
    }

    /// Moves one end of an edge to another card (drag an end handle). Returns
    /// false, and changes nothing, when the move is not allowed.
    @discardableResult
    func retargetConnection(_ id: UUID, movingFrom: Bool, to card: CanvasCardID) -> Bool {
        guard let edge = connection(id) else { return false }
        let newFrom = movingFrom ? card : edge.from
        let newTo = movingFrom ? edge.to : card
        guard newFrom != newTo, cards.contains(where: { $0.id == card }),
            (movingFrom ? edge.from : edge.to) != card
        else { return false }
        let both = bothTerminals(newFrom, newTo)
        guard
            !CanvasConnectionRules.isIdentical(
                from: newFrom, to: newTo, bothTerminals: both, existing: connections,
                ignoring: id)
        else { return false }
        let behavior = CanvasConnectionRules.behavior(bothTerminals: both)
        var changed = false
        performEdgeEdit {
            try edit { document in
                guard let index = document.connections.firstIndex(where: { $0.id == id }) else {
                    return
                }
                let wasUnlabelled = document.connections[index].customLabel == nil
                document.connections[index].from = newFrom
                document.connections[index].to = newTo
                document.connections[index].behavior = behavior
                if wasUnlabelled {
                    document.connections[index].label = CanvasConnection.placeholderLabel(
                        for: behavior)
                }
                changed = true
            }
        }
        return changed
    }

    /// "Go to Source" and "Go to Target": select the card and centre it.
    func goToCard(_ id: CanvasCardID) {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        selectedConnectionID = nil
        selection = [id]
        guard visibleSize.width > 0, visibleSize.height > 0 else { return }
        var next = viewport
        next.x = visibleSize.width / 2 - (card.rect.x + card.rect.width / 2) * next.scale
        next.y = visibleSize.height / 2 - (card.rect.y + card.rect.height / 2) * next.scale
        setViewport(next)
    }
}

nonisolated enum CanvasNewCardKind: Equatable, Sendable {
    case note
    case terminal
}

extension WorkspaceSession {
    /// "Connect to new…": creates a card with the existing creation APIs, puts it
    /// centred on `point` (board coordinates) and connects it to `source`.
    func connectCanvasToNew(
        _ kind: CanvasNewCardKind, boardID: CanvasID, from source: CanvasCardID, at point: CGPoint
    ) {
        guard let board = canvas.boards[boardID],
            board.cards.contains(where: { $0.id == source }),
            board.cards.count < CanvasLimits.cards,
            board.connections.count < CanvasLimits.connections
        else { return }
        let existing = Set(board.cards.map(\.id))
        switch kind {
        case .note: addCanvasNote(boardID)
        case .terminal: addCanvasStoppedTerminal(boardID)
        }
        guard let created = board.cards.last(where: { !existing.contains($0.id) }) else { return }
        performCanvasEdit(board) {
            try board.edit { document in
                guard let index = document.cards.firstIndex(where: { $0.id == created.id }) else {
                    return
                }
                var rect = document.cards[index].rect
                rect.x = WorkspaceSession.snappedCoordinate(point.x - rect.width / 2)
                rect.y = WorkspaceSession.snappedCoordinate(point.y - rect.height / 2)
                document.cards[index].rect = rect
            }
        }
        connectCanvasCards(boardID: boardID, from: source, to: created.id)
    }

    private static func snappedCoordinate(_ value: Double) -> Double {
        min(50_000, max(-50_000, (value / 8).rounded() * 8))
    }
}
