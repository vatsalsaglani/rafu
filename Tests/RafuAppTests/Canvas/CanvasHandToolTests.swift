import Foundation
import Testing

@testable import RafuApp

/// The Hand tool: it pans through the board's own pan route (the Space-drag
/// route), never through a full-board layer, and it can always be left by
/// the palette, Escape, or a tool letter.
@Suite("Canvas Hand tool")
@MainActor
struct CanvasHandToolTests {
    @Test("Only drawing tools put the creation layer over the board")
    func creationLayerIsInertForHand() {
        #expect(!CanvasWhiteboardToolKind.select.drawsOnBoard)
        #expect(!CanvasWhiteboardToolKind.hand.drawsOnBoard)
        #expect(!CanvasWhiteboardToolKind.image.drawsOnBoard)
        for kind in CanvasWhiteboardToolKind.allCases
        where ![.select, .hand, .image].contains(kind) {
            #expect(kind.drawsOnBoard, "\(kind) draws")
        }
    }

    @Test("Hand and Space give the board's pan priority over cards")
    func panRouting() {
        #expect(CanvasBoardPanRouting.panOverridesCards(spaceIsDown: false, tool: .hand))
        #expect(CanvasBoardPanRouting.panOverridesCards(spaceIsDown: true, tool: .select))
        #expect(CanvasBoardPanRouting.panOverridesCards(spaceIsDown: true, tool: .pen))
        #expect(!CanvasBoardPanRouting.panOverridesCards(spaceIsDown: false, tool: .select))
        #expect(!CanvasBoardPanRouting.panOverridesCards(spaceIsDown: false, tool: .rectangle))
    }

    @Test("Hand shows grab, then grab-active while a pan is live, then grab again")
    func handPanLifecycle() {
        let tool = CanvasWhiteboardTool()
        tool.kind = .hand
        var pan = CanvasBoardPan()
        #expect(!pan.isPanning)
        #expect(
            CanvasBoardPanRouting.pointer(tool: tool.kind, isPanning: pan.isPanning) == .grabIdle)
        #expect(pan.viewport(for: CGSize(width: 10, height: 10)) == nil)

        let start = CanvasViewport(scale: 1.5, x: 20, y: -30)
        pan.begin(from: start)
        #expect(pan.isPanning)
        #expect(
            CanvasBoardPanRouting.pointer(tool: tool.kind, isPanning: pan.isPanning) == .grabActive)
        // Translation is measured from the press, not accumulated.
        #expect(
            pan.viewport(for: CGSize(width: 15, height: 5))
                == CanvasViewport(scale: 1.5, x: 35, y: -25))
        #expect(
            pan.viewport(for: CGSize(width: -40, height: 0))
                == CanvasViewport(scale: 1.5, x: -20, y: -30))

        // Mouse-up, or a cancelled drag, ends the pan.
        pan.end()
        #expect(!pan.isPanning)
        #expect(
            CanvasBoardPanRouting.pointer(tool: tool.kind, isPanning: pan.isPanning) == .grabIdle)
        #expect(tool.kind == .hand)
        #expect(CanvasBoardPanRouting.pointer(tool: .select, isPanning: false) == nil)
        #expect(CanvasBoardPanRouting.pointer(tool: .pen, isPanning: true) == nil)
    }

    @Test("A pan clamps like every other pan")
    func panClamps() {
        let far = CanvasBoardPanRouting.panned(
            CanvasViewport(scale: 1, x: 99_990, y: -99_990), by: CGSize(width: 50, height: -50))
        #expect(far == CanvasViewport(scale: 1, x: 100_000, y: -100_000))
    }

    @Test("Escape and V leave Hand; other letters switch tools; Escape on Select passes")
    func keysLeaveHand() {
        #expect(CanvasWhiteboardToolKind.resolve(.escape, from: .hand) == .select)
        #expect(CanvasWhiteboardToolKind.resolve(.character("v"), from: .hand) == .select)
        #expect(CanvasWhiteboardToolKind.resolve(.character("r"), from: .hand) == .rectangle)
        #expect(CanvasWhiteboardToolKind.resolve(.character("p"), from: .hand) == .pen)
        #expect(CanvasWhiteboardToolKind.resolve(.character("h"), from: .select) == .hand)
        #expect(CanvasWhiteboardToolKind.resolve(.escape, from: .pen) == .select)
        // Escape on Select stays with the board (it clears the selection).
        #expect(CanvasWhiteboardToolKind.resolve(.escape, from: .select) == nil)
        #expect(CanvasWhiteboardToolKind.resolve(.character("q"), from: .hand) == nil)
    }

    // MARK: Source contracts

    @Test("The palette is an overlay outside every board gesture, above every board layer")
    func paletteSitsAboveBoardGestures() throws {
        let source = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        let layersStart = try #require(source.range(of: "private func boardLayers("))
        let chromeStart = try #require(source.range(of: "private func boardChrome("))
        let keysStart = try #require(source.range(of: "private func boardKeys("))
        let layers = source[layersStart.upperBound..<chromeStart.lowerBound]
        let chrome = source[chromeStart.upperBound..<keysStart.lowerBound]
        // Not a ZStack layer, where the board's gestures and layers compete.
        #expect(!layers.contains("boardTopOverlay"))
        // An overlay after the high-priority pan and magnify gestures, and
        // inside `.focusable()` so the palette still sees board focus.
        let gesture = try #require(chrome.range(of: ".highPriorityGesture("))
        let magnify = try #require(chrome.range(of: "MagnifyGesture()"))
        let overlay = try #require(
            chrome.range(of: ".overlay(alignment: .top) { boardTopOverlay }"))
        let focusable = try #require(chrome.range(of: ".focusable()\n"))
        #expect(gesture.lowerBound < overlay.lowerBound)
        #expect(magnify.lowerBound < overlay.lowerBound)
        #expect(overlay.lowerBound < focusable.lowerBound)
        // Both pan masks follow the shared routing, so Hand equals Space.
        #expect(chrome.contains("including: panOverridesCards ? .all : .subviews"))
        #expect(layers.contains("including: panOverridesCards ? .subviews : .all"))
        #expect(!source.contains("including: spaceIsDown"))
        #expect(chrome.contains("backgroundDrag(live: $boardDragIsLive)"))
        #expect(layers.contains("backgroundDrag(live: $gridDragIsLive)"))
        // A cancelled drag clears the pan too.
        #expect(source.contains(".updating(live)"))
        #expect(source.contains(".onChange(of: gridDragIsLive || boardDragIsLive)"))
        #expect(source.contains("if !live { endBackgroundDrag() }"))
    }

    @Test("The creation layer stays inert unless a drawing tool is on")
    func creationLayerGate() throws {
        let source = try Self.source(
            "Sources/RafuApp/Canvas/Whiteboard/CanvasWhiteboardCreationLayer.swift")
        #expect(source.contains("if !tool.kind.drawsOnBoard {"))
        #expect(!source.contains("panStart"))
        #expect(!source.contains("board.setViewport"))
        let palette = try Self.source("Sources/RafuApp/Canvas/Whiteboard/CanvasToolPalette.swift")
        // Choosing a tool returns the keys to the board.
        #expect(palette.contains("if board.contentIsActive { board.backToBoard() }"))
        #expect(palette.contains("focusBoard()"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(
                    contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
