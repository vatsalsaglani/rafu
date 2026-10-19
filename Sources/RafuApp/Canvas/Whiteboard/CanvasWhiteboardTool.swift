import Foundation
import Observation
import SwiftUI

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

    /// Whether the creation layer covers the board for this tool. Select,
    /// Hand and Image do not. Hand pans through the board's own pan gesture
    /// (the Space-drag route), so no full-board layer lies over the cards,
    /// and a press never starts a zero-distance gesture that can outlive
    /// its mouse-up. See `CanvasBoardPanRouting`.
    var drawsOnBoard: Bool {
        switch self {
        case .select, .hand, .image: false
        default: true
        }
    }

    /// The built-in tool a palette key selects from `current`, or nil when
    /// the key is not a tool key. Escape returns any other tool to Select.
    static func resolve(_ key: CanvasToolKey, from current: CanvasWhiteboardToolKind)
        -> CanvasWhiteboardToolKind?
    {
        switch key {
        case .escape: current == .select ? nil : .select
        case .character(let character): matching(key: character)
        }
    }

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

/// Who owns a board drag. The Hand tool latches the Space-drag route: the
/// board's high-priority background pan takes the drag over cards, so a
/// click (no movement) still reaches card chrome and the palette, and a
/// drag pans. Pure, so the routing is testable without a window.
enum CanvasBoardPanRouting {
    /// True while the board's pan must win over cards.
    static func panOverridesCards(spaceIsDown: Bool, tool: CanvasWhiteboardToolKind) -> Bool {
        spaceIsDown || tool == .hand
    }

    /// `start` moved by a drag `translation`, clamped like every pan.
    static func panned(_ start: CanvasViewport, by translation: CGSize) -> CanvasViewport {
        CanvasViewport(
            scale: start.scale,
            x: min(100_000, max(-100_000, start.x + Double(translation.width))),
            y: min(100_000, max(-100_000, start.y + Double(translation.height))))
    }

    /// The board-wide grab pointer of the Hand tool.
    enum Pointer: Equatable {
        case grabIdle, grabActive

        var style: PointerStyle { self == .grabIdle ? .grabIdle : .grabActive }
    }

    /// The board-wide pointer: grab while the Hand tool is on, otherwise
    /// nil (each layer keeps its own pointer).
    static func pointer(tool: CanvasWhiteboardToolKind, isPanning: Bool) -> Pointer? {
        guard tool == .hand else { return nil }
        return isPanning ? .grabActive : .grabIdle
    }
}

/// One background pan: the viewport it started from. `end()` runs on
/// mouse-up and on a cancelled drag, so `isPanning` never outlives the
/// press.
struct CanvasBoardPan: Equatable {
    private(set) var start: CanvasViewport?

    var isPanning: Bool { start != nil }

    mutating func begin(from viewport: CanvasViewport) { start = viewport }

    /// The viewport for a drag `translation`, or nil when no pan is live.
    func viewport(for translation: CGSize) -> CanvasViewport? {
        start.map { CanvasBoardPanRouting.panned($0, by: translation) }
    }

    mutating func end() { start = nil }
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
