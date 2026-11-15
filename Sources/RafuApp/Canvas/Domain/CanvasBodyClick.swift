import Foundation

/// A primary click in the body of an Ensemble card selects and focuses that
/// card, whatever the body draws (terminal, note, Markdown file, generated
/// view, image, web page, diagram). The header keeps its own gesture.
///
/// The board observes the mouse-down at the AppKit level and never consumes
/// it (`CanvasBodyClickMonitor`), so text selection, links, buttons, scrolling
/// and the content's own focus keep working. Per-kind SwiftUI taps missed
/// clicks that a native subview took first (selectable text, a scroll view's
/// tracking, SwiftTerm), and several body states had no click handler at all.
/// See `docs/references/canvas-interaction.md`.
enum CanvasBodyClick {
    /// The card header (32 pt) and its hairline, in board units.
    static let headerHeight = 33.0
    /// The card's left, right and bottom edge band, in screen points, that
    /// belongs to the resize zones and connection ports.
    static let edgeBand = 8.0
    /// The named coordinate space of the board surface. Overlays that sit
    /// above the cards register their frames in it (`CanvasBodyClickExclusions`).
    nonisolated static let coordinateSpaceName = "dev.rafu.canvas.body-click"

    /// The modifier keys that change what a click does.
    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let option = Modifiers(rawValue: 1 << 3)
    }

    /// What one mouse-down in the board does to selection and focus.
    enum Decision: Equatable {
        /// Nothing: not on a card body, a board mode owns the click, or the
        /// card already has content focus.
        case none
        /// Raise, select and focus this card (and give a terminal the keys).
        case activate(CanvasCardID)
        /// ⌘- or ⇧-click: the board selection becomes exactly this set.
        case select(Set<CanvasCardID>)
    }

    /// The card whose body is under `point` (board surface, top-left
    /// origin, screen points), or nil. The frontmost card under the point
    /// owns it: a header, a compact face, a whiteboard item or an edge band
    /// on top gives nil, never the card behind it. A point inside `excluded`
    /// (an overlay above the cards) gives nil.
    static func card(
        at point: CGPoint, cards: [CanvasCard], viewport: CanvasViewport,
        activeCardID: CanvasCardID?, excluded: [CGRect] = []
    ) -> CanvasCardID? {
        guard !excluded.contains(where: { $0.contains(point) }) else { return nil }
        let scale = viewport.scale
        // `cards` is back-to-front; the last card is drawn on top.
        for card in cards.reversed() {
            let frame = CGRect(
                x: card.rect.x * scale + viewport.x, y: card.rect.y * scale + viewport.y,
                width: card.rect.width * scale, height: card.rect.height * scale)
            guard frame.contains(point) else { continue }
            guard
                hasLiveBody(
                    card.content, scale: scale, isContentActive: card.id == activeCardID)
            else { return nil }
            let body = CGRect(
                x: frame.minX + edgeBand, y: frame.minY + headerHeight * scale,
                width: max(0, frame.width - edgeBand * 2),
                height: max(0, frame.height - headerHeight * scale - edgeBand))
            return body.contains(point) ? card.id : nil
        }
        return nil
    }

    /// Whether this card draws the header-and-body face at `scale`. Compact
    /// faces and whiteboard items are one move handle with no body.
    static func hasLiveBody(_ content: CanvasCardContent, scale: Double, isContentActive: Bool)
        -> Bool
    {
        guard CanvasWhiteboardCardFace.usesCardChrome(content) else { return false }
        if case .terminal = content {
            return CanvasTerminalLiveRule.isLive(scale: scale, isContentActive: isContentActive)
        }
        return CanvasZoomFace(scale: scale).showsLiveContent
    }

    /// What a mouse-down on `card`'s body does. `cardsTakeClicks` is false
    /// while a board mode owns the pointer: Space or the Hand tool pans, a
    /// drawing tool draws, a connection drag runs, or Find covers the board.
    /// ⌃-click is a context-menu click and changes nothing.
    static func decision(
        card: CanvasCardID?, modifiers: Modifiers, selection: Set<CanvasCardID>,
        focusedCardID: CanvasCardID?, contentIsActive: Bool, cardsTakeClicks: Bool
    ) -> Decision {
        guard cardsTakeClicks, let card, !modifiers.contains(.control) else { return .none }
        if modifiers.contains(.command) || modifiers.contains(.shift) {
            var next = selection
            if next.contains(card) { next.remove(card) } else { next.insert(card) }
            return .select(next)
        }
        if contentIsActive, focusedCardID == card { return .none }
        return .activate(card)
    }
}

/// The frames of overlays drawn above the cards (the tool palette and board
/// notices, the zoom corner), in `CanvasBodyClick.coordinateSpaceName`. A
/// click there belongs to the overlay, not to the card under it. Not
/// observable: frames change with layout and are read only at click time.
final class CanvasBodyClickExclusions {
    private var frames: [String: CGRect] = [:]

    var rects: [CGRect] { Array(frames.values) }

    func set(_ key: String, _ frame: CGRect?) {
        frames[key] = frame
    }
}
