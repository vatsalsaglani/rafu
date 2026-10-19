import AppKit
import SwiftUI

/// The Excalidraw-like drawing surface. It lies over the board's cards and
/// takes pointer input only while a drawing tool is active; with Select, Hand
/// and Image it is inert, so the board and cards behave exactly as before.
/// Hand pans through the board's own pan gesture (`CanvasBoardPanRouting`),
/// so it never lays a press-capturing layer over the cards.
///
/// Coordinates: gesture locations are in the board surface (the same space
/// `viewportProject`/`unproject` use); samples are stored in board units. A
/// gesture draws a preview and commits one card on mouse-up as a single
/// undoable edit.
struct CanvasWhiteboardCreationLayer: View {
    @Environment(\.rafuTheme) private var theme
    let board: CanvasBoardState
    let tool: CanvasWhiteboardTool
    let viewportProject: (CGPoint) -> CGPoint
    let unproject: (CGPoint) -> CGPoint

    /// Board-space samples of the gesture in progress (bounded).
    @State private var samples: [CGPoint] = []
    /// Board point where a new text item is being typed.
    @State private var textDraft: CGPoint?

    var body: some View {
        if !tool.kind.drawsOnBoard {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(.rect)
                    .gesture(drag)
                    .pointerStyle(pointer)
                    .accessibilityLabel("\(tool.kind.title) tool. Drag on the board to draw.")
                preview
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if let textDraft { textEditor(at: textDraft) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onChange(of: tool.kind) { _, _ in
                samples = []
                textDraft = nil
            }
        }
    }

    private var pointer: PointerStyle {
        switch tool.kind {
        case .text: .horizontalText
        default: .rectSelection
        }
    }

    // MARK: Gesture

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0).onChanged { value in
            switch tool.kind {
            case .pen:
                let point = unproject(value.location)
                if samples.isEmpty { samples = [unproject(value.startLocation)] }
                guard let last = samples.last,
                    samples.count < CanvasWhiteboardGeometry.maximumRawPoints
                else { return }
                // Keep samples at least ~1 screen point apart.
                let spacing = 1 / max(0.1, board.viewport.scale)
                if hypot(Double(point.x - last.x), Double(point.y - last.y)) >= spacing {
                    samples.append(point)
                }
            case .rectangle, .ellipse, .diamond, .arrow, .line:
                samples = [unproject(value.startLocation), unproject(value.location)]
            case .text, .mermaid, .select, .hand, .image:
                break
            }
        }
        .onEnded { value in
            let start = unproject(value.startLocation)
            let end = unproject(value.location)
            switch tool.kind {
            case .pen:
                commitStroke(.freehand, samples: samples)
            case .arrow:
                commitStroke(.arrow, samples: [start, end])
            case .line:
                commitStroke(.line, samples: [start, end])
            case .rectangle, .ellipse, .diamond:
                commitShape(from: start, to: end)
            case .text:
                textDraft = start
            case .mermaid:
                commitMermaid(at: start)
            case .select, .hand, .image:
                break
            }
            if tool.kind != .text { samples = [] }
        }
    }

    // MARK: Commit

    private func commitShape(from start: CGPoint, to end: CGPoint) {
        let square = NSEvent.modifierFlags.contains(.shift)
        let rect = CanvasWhiteboardGeometry.shapeRect(from: start, to: end, square: square)
        let shape = tool.shapeStyle
        CanvasWhiteboardEdit.place(
            CanvasCard(title: shape.kind.title, rect: rect, content: .shape(shape)), on: board)
        tool.didCreate()
    }

    private func commitStroke(_ kind: CanvasStrokeKind, samples: [CGPoint]) {
        defer { self.samples = [] }
        guard
            let made = CanvasWhiteboardGeometry.strokeCard(
                kind: kind, samples: samples, style: tool.strokeStyle(kind))
        else { return }
        CanvasWhiteboardEdit.place(
            CanvasCard(title: kind.title, rect: made.rect, content: .stroke(made.stroke)),
            on: board)
        tool.didCreate()
    }

    static let mermaidTemplate = """
        flowchart LR
          A[Start] --> B{Decide}
          B -->|Yes| C[Ship]
          B -->|No| D[Revise]
        """

    private func commitMermaid(at point: CGPoint) {
        let rect = CanvasWhiteboardGeometry.clamped(
            x: Double(point.x) - 210, y: Double(point.y) - 150, width: 420, height: 300)
        let card = CanvasCard(
            title: "Diagram", rect: rect, content: .mermaid(source: Self.mermaidTemplate))
        CanvasWhiteboardEdit.place(card, on: board)
        tool.didCreate()
        // Open the source editor right away for the new diagram.
        CanvasWhiteboardEditing.shared.request(card.id)
    }

    private func commitText(_ text: String, at point: CGPoint) {
        // A late commit from an older draft must not close a newer one.
        if textDraft == point { textDraft = nil }
        tool.didCreate()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let size = CanvasWhiteboardGeometry.textCardSize(for: text, size: tool.textSize)
        let rect = CanvasWhiteboardGeometry.clamped(
            x: Double(point.x), y: Double(point.y) - 8, width: size.0, height: size.1)
        let value = CanvasText(text: text, size: tool.textSize, ink: tool.ink)
        CanvasWhiteboardEdit.place(
            CanvasCard(
                title: CanvasWhiteboardEdit.title(from: text, fallback: "Text"), rect: rect,
                content: .text(value)),
            on: board)
    }

    // MARK: Preview

    @ViewBuilder private var preview: some View {
        let ink = tool.ink.color(in: theme.palette)
        let width = CGFloat(tool.weight.points * board.viewport.scale)
        let style = StrokeStyle(
            lineWidth: width, lineCap: .round, lineJoin: .round,
            dash: tool.dashed ? [width * 3, width * 2.5] : [])
        if let kind = tool.kind.shapeKind, samples.count == 2 {
            let rect = CanvasWhiteboardGeometry.shapeRect(
                from: samples[0], to: samples[1], square: NSEvent.modifierFlags.contains(.shift))
            let origin = viewportProject(CGPoint(x: rect.x, y: rect.y))
            let scale = board.viewport.scale
            CanvasShapeOutline(kind: kind)
                .fill(tool.fill.color(ink: ink))
                .overlay { CanvasShapeOutline(kind: kind).strokeBorder(ink, style: style) }
                .frame(width: rect.width * scale, height: rect.height * scale)
                .offset(x: origin.x, y: origin.y)
        } else if tool.kind.strokeKind != nil, samples.count >= 2 {
            Path { path in
                let points = samples.map(viewportProject)
                path.move(to: points[0])
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            .stroke(ink, style: style)
        }
    }

    private func textEditor(at point: CGPoint) -> some View {
        let origin = viewportProject(point)
        let scale = board.viewport.scale
        let fontSize = CGFloat(tool.textSize.points * scale)
        return CanvasWhiteboardTextEditor(
            initialText: "", fontSize: fontSize,
            textColor: NSColor(tool.ink.color(in: theme.palette)),
            byteLimit: CanvasLimits.whiteboardTextBytes, accessibilityLabel: "New text",
            onCommit: { commitText($0, at: point) },
            onCancel: {
                if textDraft == point { textDraft = nil }
                tool.didCreate()
            }
        )
        .frame(width: 280 * scale, height: max(40, fontSize * 4))
        .background(theme.palette.editorBackground.opacity(0.6))
        .overlay {
            RoundedRectangle(cornerRadius: 4).strokeBorder(theme.palette.borderStrong)
        }
        .offset(x: origin.x, y: origin.y - 8 * scale)
    }
}
