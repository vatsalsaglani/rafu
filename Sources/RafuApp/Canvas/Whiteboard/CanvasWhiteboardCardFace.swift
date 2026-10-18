import AppKit
import SwiftUI

/// Renders the card kinds X5 added (and routes X9's diagram kinds). The card
/// shell (X1) owns position, selection handles and gestures; this view only
/// draws the content that fills the card.
struct CanvasWhiteboardCardFace: View {
    let card: CanvasCard
    let board: CanvasBoardState

    /// Whether the shell draws its standard header and frame. Whiteboard items
    /// stay light (selection handles only); a frame draws its own titled look
    /// (`CanvasDiagramCardFace`), so the shell adds no second header. Mermaid
    /// diagrams keep the standard header.
    static func usesCardChrome(_ content: CanvasCardContent) -> Bool {
        switch content {
        case .shape, .stroke, .text, .serviceIcon, .frame: false
        case .mermaid: true
        case .file, .image, .note, .terminal, .web, .nativeApp: true
        }
    }

    /// Whether this face renders `content`; the shell keeps every other kind.
    static func renders(_ content: CanvasCardContent) -> Bool {
        switch content {
        case .mermaid, .shape, .stroke, .text, .frame, .serviceIcon: true
        case .file, .image, .note, .terminal, .web, .nativeApp: false
        }
    }

    var body: some View {
        switch card.content {
        case .mermaid:
            CanvasMermaidCard(card: card, board: board)
        case .shape(let shape):
            CanvasShapeFace(card: card, shape: shape, board: board)
        case .stroke(let stroke):
            CanvasStrokeFace(stroke: stroke)
        case .text(let text):
            CanvasTextFace(card: card, text: text, board: board)
        case .frame, .serviceIcon:
            CanvasDiagramCardFace(card: card, board: board)
        case .file, .image, .note, .terminal, .web, .nativeApp:
            EmptyView()
        }
    }
}

// MARK: Theme mapping

extension CanvasInk {
    /// The theme colour for this ink. Never the gold accent.
    func color(in palette: RafuThemePalette) -> Color {
        switch self {
        case .primary: palette.textPrimary
        case .secondary: palette.textSecondary
        case .info: palette.info
        case .success: palette.success
        case .warning: palette.warning
        case .danger: palette.error
        }
    }
}

extension CanvasFill {
    func color(ink: Color) -> Color {
        switch self {
        case .none: .clear
        case .tint: ink.opacity(0.12)
        case .solid: ink.opacity(0.32)
        }
    }
}

// MARK: Editing

/// Replaces one card's content as a single undoable edit, then returns to the
/// board. A rejected value (too long, invalid) shows the board error.
@MainActor
enum CanvasWhiteboardEdit {
    static func replace(
        _ id: CanvasCardID, in board: CanvasBoardState, with content: CanvasCardContent,
        title: String? = nil
    ) {
        do {
            try board.edit { document in
                guard let index = document.cards.firstIndex(where: { $0.id == id }) else { return }
                document.cards[index].content = content
                if let title, CanvasDocument.validTitle(title) {
                    document.cards[index].title = title
                }
            }
        } catch {
            board.errorMessage = error.localizedDescription
        }
        if board.focusedCardID == id { board.backToBoard() }
    }

    /// Puts a new card on the board (one undoable edit) and selects it.
    static func place(_ card: CanvasCard, on board: CanvasBoardState) {
        do {
            try board.edit { document in
                guard document.cards.count < CanvasLimits.cards else {
                    throw CanvasError.capacity
                }
                document.cards.append(card)
            }
            board.select([card.id])
        } catch {
            board.errorMessage = error.localizedDescription
        }
    }

    /// A card title from the first line of `text`, or `fallback`.
    static func title(from text: String, fallback: String) -> String {
        let line = CanvasCardSummaryText.firstLine(of: text, limit: 60)
        return CanvasDocument.validTitle(line) ? line : fallback
    }
}

/// Enters editing when the card shell (double-click) or a command asks for it
/// through `CanvasWhiteboardEditing`. Editing marks the card's content active
/// so the board's own keys stay out of the way. Whiteboard items are their
/// own move handle, so they take no tap gesture here.
struct CanvasWhiteboardEditTrigger: ViewModifier {
    let card: CanvasCard
    let board: CanvasBoardState
    @Binding var isEditing: Bool
    private var editing: CanvasWhiteboardEditing { .shared }

    func body(content: Content) -> some View {
        content
            .onChange(of: editing.requestedCardID) { _, requested in
                if requested == card.id, editing.consume(card.id) { begin() }
            }
            .onAppear {
                if editing.consume(card.id) { begin() }
            }
    }

    private func begin() {
        guard !isEditing else { return }
        board.focus(card.id)
        isEditing = true
    }
}

extension View {
    func canvasWhiteboardEditTrigger(
        card: CanvasCard, board: CanvasBoardState, isEditing: Binding<Bool>
    ) -> some View {
        modifier(CanvasWhiteboardEditTrigger(card: card, board: board, isEditing: isEditing))
    }
}

// MARK: Shape

/// A rectangle (rounded), ellipse or diamond that insets for its border.
nonisolated struct CanvasShapeOutline: InsettableShape {
    let kind: CanvasShapeKind
    var inset: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let frame = rect.insetBy(dx: inset, dy: inset)
        switch kind {
        case .rectangle:
            let radius = min(10, min(frame.width, frame.height) / 4)
            return Path(roundedRect: frame, cornerRadius: radius, style: .continuous)
        case .ellipse:
            return Path(ellipseIn: frame)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            path.closeSubpath()
            return path
        }
    }

    func inset(by amount: CGFloat) -> CanvasShapeOutline {
        var copy = self
        copy.inset += amount
        return copy
    }
}

struct CanvasShapeFace: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let shape: CanvasShape
    let board: CanvasBoardState
    @State private var isEditing = false

    var body: some View {
        let ink = shape.stroke.color(in: theme.palette)
        let outline = CanvasShapeOutline(kind: shape.kind)
        ZStack {
            outline.fill(shape.fill.color(ink: ink))
            outline.strokeBorder(ink, style: strokeStyle)
            if isEditing {
                CanvasWhiteboardTextEditor(
                    initialText: shape.label ?? "", fontSize: 15,
                    textColor: NSColor(theme.palette.textPrimary),
                    byteLimit: CanvasLimits.shapeLabelBytes,
                    accessibilityLabel: "Shape label",
                    onCommit: commit, onCancel: cancel
                )
                .padding(inset)
            } else if let label = shape.label, !label.isEmpty {
                Text(label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(inset)
            }
        }
        .contentShape(outline)
        .canvasWhiteboardEditTrigger(card: card, board: board, isEditing: $isEditing)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var strokeStyle: StrokeStyle {
        let width = CGFloat(shape.weight.points)
        return StrokeStyle(
            lineWidth: width, lineCap: .round, lineJoin: .round,
            dash: shape.dashed ? [width * 3, width * 2.5] : [])
    }

    /// Labels stay inside the diamond and ellipse, not only the bounding box.
    private var inset: CGFloat {
        switch shape.kind {
        case .rectangle: 10
        case .ellipse: CGFloat(min(card.rect.width, card.rect.height) * 0.15)
        case .diamond: CGFloat(min(card.rect.width, card.rect.height) * 0.25)
        }
    }

    private var accessibilityText: String {
        if let label = shape.label, !label.isEmpty { return "\(shape.kind.title): \(label)" }
        return shape.kind.title
    }

    private func commit(_ text: String) {
        isEditing = false
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = shape
        next.label = trimmed.isEmpty ? nil : trimmed
        guard next != shape else {
            board.backToBoard()
            return
        }
        CanvasWhiteboardEdit.replace(card.id, in: board, with: .shape(next))
    }

    private func cancel() {
        isEditing = false
        board.backToBoard()
    }
}

// MARK: Stroke

/// The path of a stroke in its card: a smoothed freehand curve or a straight
/// segment, plus open arrowheads.
nonisolated struct CanvasStrokePath: Shape {
    let stroke: CanvasStroke

    func path(in rect: CGRect) -> Path {
        let points = stroke.points.map { point in
            CGPoint(
                x: Double(rect.minX) + point.x * Double(rect.width),
                y: Double(rect.minY) + point.y * Double(rect.height))
        }
        var path = Path()
        guard let first = points.first, points.count >= 2 else { return path }
        path.move(to: first)
        if stroke.kind == .freehand, points.count > 2 {
            // Quadratic segments through the midpoints give a smooth line
            // from the simplified samples.
            for index in 1..<(points.count - 1) {
                let control = points[index]
                let next = points[index + 1]
                let mid = CGPoint(
                    x: (Double(control.x) + Double(next.x)) / 2,
                    y: (Double(control.y) + Double(next.y)) / 2)
                path.addQuadCurve(to: mid, control: control)
            }
            path.addLine(to: points[points.count - 1])
        } else {
            path.addLine(to: points[points.count - 1])
        }
        let size = 6 + stroke.weight.points * 2.5
        if stroke.endArrowhead == .arrow {
            Self.addArrowhead(
                to: &path, tip: points[points.count - 1], from: points[points.count - 2], size: size
            )
        }
        if stroke.startArrowhead == .arrow {
            Self.addArrowhead(to: &path, tip: points[0], from: points[1], size: size)
        }
        return path
    }

    private static func addArrowhead(
        to path: inout Path, tip: CGPoint, from tail: CGPoint, size: Double
    ) {
        let angle = atan2(Double(tip.y) - Double(tail.y), Double(tip.x) - Double(tail.x))
        let spread = Double.pi / 7
        for side in [angle + Double.pi - spread, angle + Double.pi + spread] {
            path.move(to: tip)
            path.addLine(
                to: CGPoint(
                    x: Double(tip.x) + cos(side) * size, y: Double(tip.y) + sin(side) * size))
        }
    }
}

struct CanvasStrokeFace: View {
    @Environment(\.rafuTheme) private var theme
    let stroke: CanvasStroke

    var body: some View {
        let width = CGFloat(stroke.weight.points)
        CanvasStrokePath(stroke: stroke)
            .stroke(
                stroke.ink.color(in: theme.palette),
                style: StrokeStyle(
                    lineWidth: width, lineCap: .round, lineJoin: .round,
                    dash: stroke.dashed ? [width * 3, width * 2.5] : [])
            )
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stroke.kind.title)
    }
}

// MARK: Text

struct CanvasTextFace: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let text: CanvasText
    let board: CanvasBoardState
    @State private var isEditing = false
    /// Parsed once per text change, never in `body`.
    @State private var rendered: (source: String, value: AttributedString)?

    var body: some View {
        let size = CGFloat(text.size.points)
        let ink = text.ink.color(in: theme.palette)
        Group {
            if isEditing {
                CanvasWhiteboardTextEditor(
                    initialText: text.text, fontSize: size, textColor: NSColor(ink),
                    byteLimit: CanvasLimits.whiteboardTextBytes,
                    accessibilityLabel: "Text", onCommit: commit, onCancel: cancel)
            } else {
                Group {
                    if let rendered, rendered.source == text.text {
                        Text(rendered.value)
                    } else {
                        Text(text.text)
                    }
                }
                .font(.system(size: size, weight: text.size == .heading ? .semibold : .regular))
                .foregroundStyle(ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(8)
            }
        }
        .contentShape(.rect)
        .onAppear(perform: refresh)
        .onChange(of: text.text) { _, _ in refresh() }
        .canvasWhiteboardEditTrigger(card: card, board: board, isEditing: $isEditing)
    }

    private func refresh() {
        let source = text.text
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let value =
            (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        rendered = (source, value)
    }

    private func commit(_ value: String) {
        isEditing = false
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, value != text.text else {
            board.backToBoard()
            return
        }
        var next = text
        next.text = value
        CanvasWhiteboardEdit.replace(
            card.id, in: board, with: .text(next),
            title: CanvasWhiteboardEdit.title(from: value, fallback: "Text"))
    }

    private func cancel() {
        isEditing = false
        board.backToBoard()
    }
}
