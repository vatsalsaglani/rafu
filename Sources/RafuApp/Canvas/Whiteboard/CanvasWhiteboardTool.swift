import Foundation
import Observation

/// The tools of the Excalidraw-like palette. `key` is the single-letter
/// shortcut, active only while the board itself has keyboard focus.
///
/// Text uses X, not T: T already adds a terminal on the board (see
/// `docs/references/canvas-interaction.md`), and that binding is kept.
enum CanvasWhiteboardToolKind: String, CaseIterable, Identifiable, Sendable {
    case select, hand, rectangle, ellipse, diamond, arrow, line, pen, text, mermaid, image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .hand: "Hand"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .diamond: "Diamond"
        case .arrow: "Arrow"
        case .line: "Line"
        case .pen: "Pen"
        case .text: "Text"
        case .mermaid: "Mermaid Diagram"
        case .image: "Image…"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .diamond: "diamond"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .mermaid: "point.3.connected.trianglepath.dotted"
        case .image: "photo"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .hand: "h"
        case .rectangle: "r"
        case .ellipse: "o"
        case .diamond: "d"
        case .arrow: "a"
        case .line: "l"
        case .pen: "p"
        case .text: "x"
        case .mermaid: "m"
        case .image: "i"
        }
    }

    /// "Rectangle (R)" for help tags and menus.
    var helpText: String { "\(title) (\(String(key).uppercased()))" }

    /// Image is an action (it opens a panel), not a mode that stays selected.
    var isMode: Bool { self != .image }

    var shapeKind: CanvasShapeKind? {
        switch self {
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        case .diamond: .diamond
        default: nil
        }
    }

    var strokeKind: CanvasStrokeKind? {
        switch self {
        case .arrow: .arrow
        case .line: .line
        case .pen: .freehand
        default: nil
        }
    }

    static func matching(key: Character) -> CanvasWhiteboardToolKind? {
        allCases.first { $0.key == key }
    }
}

/// The active whiteboard tool and the style new items use. One per board,
/// shared by the palette and the creation layer. View state only: nothing
/// here is saved.
@Observable
final class CanvasWhiteboardTool {
    var kind: CanvasWhiteboardToolKind = .select
    var ink: CanvasInk = .primary
    var fill: CanvasFill = .none
    var weight: CanvasLineWeight = .regular
    var dashed = false
    var textSize: CanvasTextSize = .medium

    init() {}

    /// After an item is made the palette returns to Select, except for the
    /// pen, which stays active for the next stroke (as in Excalidraw).
    func didCreate() {
        if kind != .pen { kind = .select }
    }

    var shapeStyle: CanvasShape {
        CanvasShape(
            kind: kind.shapeKind ?? .rectangle, stroke: ink, fill: fill, weight: weight,
            dashed: dashed)
    }

    func strokeStyle(_ strokeKind: CanvasStrokeKind) -> CanvasStroke {
        CanvasStroke(kind: strokeKind, points: [], ink: ink, weight: weight, dashed: dashed)
    }

    private static var tools: [CanvasID: CanvasWhiteboardTool] = [:]
    private static var order: [CanvasID] = []

    /// The tool of board `id`. Bounded: the oldest boards' tools are dropped
    /// past 32 entries (a dropped tool only resets to Select).
    static func forBoard(_ id: CanvasID) -> CanvasWhiteboardTool {
        if let tool = tools[id] { return tool }
        let tool = CanvasWhiteboardTool()
        tools[id] = tool
        order.append(id)
        while order.count > 32 { tools[order.removeFirst()] = nil }
        return tool
    }
}

/// Asks a whiteboard or Mermaid card to enter its editor. Card commands and
/// the card shell call `request(_:)`; the matching card face consumes it.
@Observable
final class CanvasWhiteboardEditing {
    static let shared = CanvasWhiteboardEditing()
    private(set) var requestedCardID: CanvasCardID?

    func request(_ id: CanvasCardID) { requestedCardID = id }

    /// Requests editing for a chrome-less item with an editor (text, shape
    /// label). Returns false for every other kind, so a Mermaid card's header
    /// keeps rename and zoom; its body takes its own double-click. The card
    /// shell calls this on a double-click, before its own handling.
    func requestEditing(_ card: CanvasCard) -> Bool {
        switch card.content {
        case .text, .shape:
            request(card.id)
            return true
        default:
            return false
        }
    }

    /// The menu title of the edit command for `content`.
    static func editTitle(_ content: CanvasCardContent) -> String {
        switch content {
        case .mermaid: "Edit Diagram"
        case .shape: "Edit Label"
        default: "Edit Text"
        }
    }

    /// Returns true once for the requested card and clears the request.
    func consume(_ id: CanvasCardID) -> Bool {
        guard requestedCardID == id else { return false }
        requestedCardID = nil
        return true
    }
}
