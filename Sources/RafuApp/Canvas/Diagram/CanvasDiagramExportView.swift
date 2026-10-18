import AppKit
import SwiftUI

/// A static snapshot of the cards and links one export includes, in local
/// coordinates (the export bounds start at 0, 0).
struct CanvasDiagramExportScene {
    struct Edge: Identifiable {
        let id: UUID
        let curve: CanvasEdgeCurve
        let isMessageLink: Bool
        let label: String?
    }

    struct Item: Identifiable {
        let card: CanvasCard
        let rect: CGRect
        var id: CanvasCardID { card.id }
    }

    let bounds: CGRect
    let items: [Item]
    let edges: [Edge]
    let rootURL: URL

    init?(document: CanvasDocument, ids: Set<CanvasCardID>, rootURL: URL) {
        let cards = document.cards.filter { ids.contains($0.id) }
        guard let bounds = CanvasDiagramExportPlan.bounds(of: cards.map(\.rect)) else {
            return nil
        }
        let dx = -Double(bounds.minX)
        let dy = -Double(bounds.minY)
        var rects: [CanvasCardID: CGRect] = [:]
        var items: [Item] = []
        for card in cards {
            let rect = CanvasFrameLayout.moved(card.rect, dx: dx, dy: dy).cgRect
            rects[card.id] = rect
            items.append(Item(card: card, rect: rect))
        }
        let connections = document.connections.filter {
            ids.contains($0.from) && ids.contains($0.to)
        }
        let routes = CanvasEdgeGeometry.routes(
            for: connections.map { CanvasEdgeInput(id: $0.id, from: $0.from, to: $0.to) },
            rects: rects)
        let byID = Dictionary(
            connections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        edges = routes.compactMap { route in
            guard let connection = byID[route.id] else { return nil }
            return Edge(
                id: route.id, curve: route.curve, isMessageLink: connection.isMessageLink,
                label: connection.customLabel)
        }
        self.bounds = CGRect(origin: .zero, size: bounds.size)
        self.items = items
        self.rootURL = rootURL
    }

    /// The paths the GIF dots travel.
    var flowEdges: [CanvasGIFFlow.Edge] {
        edges.map {
            CanvasGIFFlow.Edge(
                id: $0.id, path: CanvasFlowPath(curve: $0.curve), bidirectional: $0.isMessageLink)
        }
    }
}

/// The export picture: an opaque board background, links, then cards as
/// static faces. Native views (terminal, web, docked app) draw a summary.
struct CanvasDiagramExportView: View {
    @Environment(\.rafuTheme) private var theme
    let scene: CanvasDiagramExportScene
    let board: CanvasBoardState

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(theme.palette.editorBackground)
            ForEach(scene.edges) { edge in
                CanvasEdgeCurveShape(curve: edge.curve)
                    .stroke(edgeColor(edge), style: edgeStroke(edge))
            }
            ForEach(scene.items) { item in
                CanvasDiagramStaticCard(card: item.card, board: board, rootURL: scene.rootURL)
                    .frame(width: item.rect.width, height: item.rect.height)
                    .offset(x: item.rect.minX, y: item.rect.minY)
            }
            ForEach(scene.edges) { edge in
                CanvasDiagramArrowhead(curve: edge.curve)
                    .fill(edgeColor(edge))
            }
            ForEach(scene.edges) { edge in
                if let label = edge.label {
                    CanvasDiagramEdgeLabel(text: label)
                        .position(edge.curve.midpoint)
                }
            }
        }
        .frame(width: scene.bounds.width, height: scene.bounds.height, alignment: .topLeading)
    }

    private func edgeColor(_ edge: CanvasDiagramExportScene.Edge) -> Color {
        edge.isMessageLink ? theme.palette.textPrimary : theme.palette.textSecondary
    }

    private func edgeStroke(_ edge: CanvasDiagramExportScene.Edge) -> StrokeStyle {
        edge.isMessageLink
            ? StrokeStyle(lineWidth: 1.5) : StrokeStyle(lineWidth: 1.5, dash: [5, 4])
    }
}

/// A small filled arrowhead at the end of a curve.
nonisolated struct CanvasDiagramArrowhead: Shape {
    let curve: CanvasEdgeCurve

    func path(in rect: CGRect) -> Path {
        let tip = curve.end
        let inward = curve.endInward
        let length = 9.0
        let half = 4.5
        let baseX = Double(tip.x) - Double(inward.x) * length
        let baseY = Double(tip.y) - Double(inward.y) * length
        let normalX = -Double(inward.y) * half
        let normalY = Double(inward.x) * half
        var path = Path()
        path.move(to: tip)
        path.addLine(to: CGPoint(x: baseX + normalX, y: baseY + normalY))
        path.addLine(to: CGPoint(x: baseX - normalX, y: baseY - normalY))
        path.closeSubpath()
        return path
    }
}

struct CanvasDiagramEdgeLabel: View {
    @Environment(\.rafuTheme) private var theme
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.elevatedBackground))
            .overlay(Capsule().strokeBorder(theme.palette.borderSubtle))
            .fixedSize()
    }
}

/// One card drawn without live content.
struct CanvasDiagramStaticCard: View {
    let card: CanvasCard
    let board: CanvasBoardState
    let rootURL: URL

    var body: some View {
        switch card.content {
        case .frame(let frame):
            CanvasFrameFaceView(title: card.title, style: frame.style)
        case .serviceIcon(let icon):
            CanvasServiceIconFaceView(icon: icon, title: card.title)
        case .note(let text):
            CanvasDiagramStaticChrome(card: card) {
                CanvasDiagramSummaryText(text: String(text.prefix(1_200)), lines: 14)
            }
        case .file(let path):
            CanvasDiagramStaticChrome(card: card) {
                CanvasDiagramSummaryText(text: path, lines: 2)
            }
        case .image(let path):
            CanvasDiagramStaticChrome(card: card) {
                CanvasDiagramStaticImage(path: path, rootURL: rootURL)
            }
        case .terminal:
            CanvasDiagramStaticChrome(card: card) {
                CanvasDiagramSummaryText(text: "Terminal", lines: 1)
            }
        case .web(let destination):
            CanvasDiagramStaticChrome(card: card) {
                CanvasDiagramSummaryText(text: destination.address, lines: 2)
            }
        case .nativeApp(let bundleID):
            CanvasDiagramStaticChrome(card: card) {
                CanvasDiagramSummaryText(text: bundleID, lines: 1)
            }
        case .mermaid:
            CanvasDiagramStaticChrome(card: card) {
                CanvasWhiteboardCardFace(card: card, board: board)
            }
        default:
            CanvasWhiteboardCardFace(card: card, board: board)
        }
    }
}

/// Header and surface like a live card, without controls.
struct CanvasDiagramStaticChrome<Content: View>: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: card.content.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                Text(card.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            Rectangle().fill(theme.palette.borderSubtle).frame(height: 1)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(shape.fill(theme.palette.elevatedBackground))
        .clipShape(shape)
        .overlay(shape.strokeBorder(theme.palette.borderSubtle))
    }
}

struct CanvasDiagramSummaryText: View {
    @Environment(\.rafuTheme) private var theme
    let text: String
    let lines: Int

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(lines)
            .padding(12)
    }
}

/// A workspace image, loaded once for the export. Paths outside the
/// workspace or larger than 20 MB draw a placeholder symbol.
struct CanvasDiagramStaticImage: View {
    @Environment(\.rafuTheme) private var theme
    let path: String
    let rootURL: URL

    var body: some View {
        if let image = loaded {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: "photo")
                .font(.system(size: 28))
                .foregroundStyle(theme.palette.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loaded: NSImage? {
        guard CanvasCardContent.validRelativePath(path) else { return nil }
        let url = rootURL.appending(path: path)
        guard CanvasDiagramExportPlan.isInside(url, root: rootURL),
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 20 * 1_024 * 1_024,
            let image = NSImage(contentsOf: url), image.isValid
        else { return nil }
        return image
    }
}
