import AppKit
import Foundation
import SwiftUI

/// Frame and service-icon edits on a board. Every edit is one undo step.
extension CanvasBoardState {
    /// `ids` plus every member of every frame among them, transitively. A
    /// drag that starts on a frame moves this set so members come along.
    func cardIDsMovingTogether(with ids: Set<CanvasCardID>) -> Set<CanvasCardID> {
        CanvasFrameLayout.closure(of: ids, in: CanvasFrameLayout.nodes(cards))
    }

    /// Moves a frame and its members by (dx, dy) board points as one undo step.
    func moveFrame(_ id: CanvasCardID, by delta: CGSize) throws {
        let moves = CanvasFrameLayout.frameMove(
            id, dx: Double(delta.width), dy: Double(delta.height),
            in: CanvasFrameLayout.nodes(cards))
        guard !moves.isEmpty else { return }
        try edit { value in
            for index in value.cards.indices {
                if let rect = moves[value.cards[index].id] { value.cards[index].rect = rect }
            }
        }
    }

    /// Wraps `memberIDs` in a new frame placed just behind its earliest
    /// member. Returns the frame's id, or nil when no member is on the board.
    @discardableResult
    func createFrame(
        title: String, memberIDs: [CanvasCardID], style: CanvasFrameStyle = .neutral
    ) throws -> CanvasCardID? {
        let present = Set(cards.map(\.id))
        var seen = Set<CanvasCardID>()
        let members = memberIDs.filter { present.contains($0) && seen.insert($0).inserted }
        guard !members.isEmpty else { return nil }
        guard cards.count < CanvasLimits.cards else { throw CanvasError.capacity }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = String((trimmed.isEmpty ? "Frame" : trimmed).prefix(120))
        let memberRects = cards.filter { seen.contains($0.id) }.map(\.rect)
        guard let rect = CanvasFrameLayout.enclosingRect(memberRects) else { return nil }
        let frame = CanvasFrame(title: name, memberIDs: members, style: style)
        try frame.validate()
        let card = CanvasCard(title: name, rect: rect, content: .frame(frame))
        try edit { value in
            let index = value.cards.firstIndex { seen.contains($0.id) } ?? 0
            value.cards.insert(card, at: index)
        }
        select([card.id])
        return card.id
    }

    /// Convert to Frame: frames the selected cards.
    @discardableResult
    func convertSelectionToFrame(title: String = "Frame") throws -> CanvasCardID? {
        let ordered = cards.map(\.id).filter { selection.contains($0) }
        return try createFrame(title: title, memberIDs: ordered)
    }

    func setFrameStyle(_ id: CanvasCardID, _ style: CanvasFrameStyle) throws {
        try edit { value in
            guard let index = value.cards.firstIndex(where: { $0.id == id }),
                var frame = value.cards[index].content.diagramFrame
            else { return }
            frame.style = style
            value.cards[index].content = .frame(frame)
        }
    }

    /// Selects a frame's members (transitively) without the frame.
    func selectFrameMembers(_ id: CanvasCardID) {
        select(cardIDsMovingTogether(with: [id]).subtracting([id]))
    }

    /// Adds a service icon card centred on `center` (board points), or in the
    /// middle of the visible board.
    @discardableResult
    func addServiceIcon(_ icon: CanvasServiceIcon, center: CGPoint? = nil) throws -> CanvasCardID {
        guard cards.count < CanvasLimits.cards else { throw CanvasError.capacity }
        try icon.validate()
        let point = center ?? creationCenter ?? visibleCenter
        creationCenter = nil
        var rect = CanvasRect(width: 128, height: 128)
        rect.x = CanvasFrameLayout.clampCoordinate((Double(point.x) - rect.width / 2).rounded())
        rect.y = CanvasFrameLayout.clampCoordinate((Double(point.y) - rect.height / 2).rounded())
        let label = icon.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let card = CanvasCard(
            title: String((label.isEmpty ? "Service" : label).prefix(120)), rect: rect,
            content: .serviceIcon(icon))
        try CanvasMotion.animateThrowing(RafuMotion.nodeCreate) {
            try edit { $0.cards.append(card) }
        }
        select([card.id])
        return card.id
    }

    /// Renames a service icon: its label and its card title change together.
    func setServiceIconLabel(_ id: CanvasCardID, _ label: String) throws {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard CanvasDocument.validTitle(trimmed) else { throw CanvasDiagramError.invalidValue }
        try edit { value in
            guard let index = value.cards.firstIndex(where: { $0.id == id }),
                var icon = value.cards[index].content.diagramServiceIcon
            else { return }
            icon.label = trimmed
            value.cards[index].content = .serviceIcon(icon)
            value.cards[index].title = trimmed
        }
    }

    /// The middle of the visible board in board points.
    var visibleCenter: CGPoint {
        let viewport = self.viewport
        guard visibleSize.width > 0, visibleSize.height > 0, viewport.scale > 0 else {
            return CGPoint(x: 200, y: 200)
        }
        let x = (Double(visibleSize.width) / 2 - viewport.x) / viewport.scale
        let y = (Double(visibleSize.height) / 2 - viewport.y) / viewport.scale
        return CGPoint(x: x, y: y)
    }

    // MARK: Follow and stacking (no undo step of their own)

    /// Moves members that did not move with their frame. The surrounding
    /// gesture or edit owns the undo step.
    func applyFrameFollow(_ moves: [CanvasCardID: CanvasRect]) {
        guard !moves.isEmpty else { return }
        for (id, rect) in moves { setRect(rect, for: id) }
        requestSave?()
    }

    /// Puts every frame back behind its members when an edit raised it.
    func restackFramesIfNeeded() {
        let nodes = CanvasFrameLayout.nodes(cards)
        let stacked = CanvasFrameLayout.stackedFramesBehindMembers(nodes)
        guard stacked.map(\.id) != nodes.map(\.id) else { return }
        let order = Dictionary(
            uniqueKeysWithValues: stacked.enumerated().map { ($1.id, $0) })
        refreshResources { document in
            document.cards.sort { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        }
        requestSave?()
    }
}
