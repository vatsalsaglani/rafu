import SwiftUI

struct MermaidDiagramView: View {
    @Environment(\.rafuTheme) private var theme
    let result: MermaidParseResult

    var body: some View {
        switch result {
        case .flow(let flow):
            diagramBody {
                MermaidFlowCanvas(flow: flow)
            }
        case .sequence(let seq):
            diagramBody {
                HStack {
                    ForEach(seq.participants, id: \.self) {
                        node($0).frame(maxWidth: .infinity)
                    }
                }
                ForEach(seq.messages, id: \.id) { message in
                    HStack {
                        Text(message.from).font(.caption)
                        Image(systemName: "arrow.right")
                        Text(message.to).font(.caption)
                        Text(message.label).foregroundStyle(.secondary)
                    }
                }
            }
        case .unsupported(let type, let raw):
            MermaidUnsupportedView(type: type, raw: raw, reason: nil)
        case .malformed(let type, let raw, let reason):
            MermaidUnsupportedView(type: type, raw: raw, reason: reason)
        }
    }

    @ViewBuilder
    private func diagramBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Simplified native preview", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(rafuHex: theme.ui.accent))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(rafuHex: theme.ui.elevatedBackground),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(rafuHex: theme.ui.borderSubtle))
        }
    }

    private func node(_ label: String) -> some View {
        Text(label)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(rafuHex: theme.ui.selection), in: Capsule())
    }
}

/// Renders a `MermaidFlow` diagram as a real 2D graph. Layout is a pure, deterministic,
/// one-shot computation (`MermaidLayoutEngine`) cached in `@State` and keyed by the flow's
/// stable `raw` source string, so it runs once per unique diagram rather than once per body
/// re-evaluation or per `Canvas` draw pass.
struct MermaidFlowCanvas: View {
    @Environment(\.rafuTheme) private var theme
    let flow: MermaidFlow
    @State private var layout: MermaidFlowLayout?

    var body: some View {
        Group {
            if let layout {
                let borderColor = Color(rafuHex: theme.ui.borderSubtle)
                let lineColor = Color(rafuHex: theme.ui.textSecondary)
                let nodeFillColor = Color(rafuHex: theme.ui.selection)
                let nodeTextColor = Color(rafuHex: theme.ui.textPrimary)
                let labelBackgroundColor = Color(rafuHex: theme.ui.elevatedBackground)
                let nodeLabels = layout.nodes.map { label(for: $0.id) }

                ScrollView(.horizontal, showsIndicators: true) {
                    Canvas { context, _ in
                        drawFlow(
                            layout: layout,
                            context: context,
                            borderColor: borderColor,
                            lineColor: lineColor,
                            nodeFillColor: nodeFillColor,
                            nodeTextColor: nodeTextColor,
                            labelBackgroundColor: labelBackgroundColor
                        )
                    }
                    .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
                }
                .frame(height: layout.canvasSize.height)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Flow diagram, \(layout.nodes.count) nodes, \(layout.edges.count) edges. "
                        + "Nodes: \(nodeLabels.joined(separator: ", "))."
                )
            } else {
                // Placeholder while the one-shot layout computation lands; a fixed minimal
                // height avoids a reflow jump once `layout` is populated.
                Color.clear.frame(height: 1)
            }
        }
        .task(id: flow.raw) {
            layout = MermaidLayoutEngine().layout(flow)
        }
    }

    private func label(for nodeID: String) -> String {
        flow.nodesByID[nodeID]?.label ?? flow.nodes[nodeID] ?? nodeID
    }

    // MARK: - Painter (subgraphs -> edges -> arrowheads -> edge labels -> nodes)

    private func drawFlow(
        layout: MermaidFlowLayout,
        context: GraphicsContext,
        borderColor: Color,
        lineColor: Color,
        nodeFillColor: Color,
        nodeTextColor: Color,
        labelBackgroundColor: Color
    ) {
        drawSubgraphs(
            layout: layout, context: context, borderColor: borderColor, titleColor: lineColor)
        drawEdges(layout: layout, context: context, lineColor: lineColor)
        drawEdgeArrowheads(layout: layout, context: context, color: lineColor)
        drawEdgeLabels(
            layout: layout, context: context, textColor: lineColor,
            backgroundColor: labelBackgroundColor)
        drawNodes(
            layout: layout, context: context, fillColor: nodeFillColor, borderColor: borderColor,
            textColor: nodeTextColor)
    }

    private func drawSubgraphs(
        layout: MermaidFlowLayout, context: GraphicsContext, borderColor: Color, titleColor: Color
    ) {
        for subgraph in layout.subgraphs.sorted(by: { $0.depth < $1.depth }) {
            let path = Path(roundedRect: subgraph.frame, cornerRadius: 6)
            context.stroke(
                path, with: .color(borderColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            context.draw(
                Text(subgraph.title).font(.caption).foregroundColor(titleColor),
                at: subgraph.titleAnchor, anchor: .topLeading)
        }
    }

    private func drawEdges(layout: MermaidFlowLayout, context: GraphicsContext, lineColor: Color) {
        for edge in layout.edges {
            let style: StrokeStyle
            switch edge.line {
            case .solid: style = StrokeStyle(lineWidth: 1.5)
            case .dotted: style = StrokeStyle(lineWidth: 1.5, dash: [2, 3])
            case .thick: style = StrokeStyle(lineWidth: 3)
            }
            context.stroke(edgePath(for: edge), with: .color(lineColor), style: style)
        }
    }

    private func edgePath(for edge: MermaidFlowLayout.EdgeGeometry) -> Path {
        var path = Path()
        path.move(to: edge.start)
        for waypoint in edge.waypoints {
            path.addLine(to: waypoint)
        }
        path.addLine(to: edge.end)
        return path
    }

    private func drawEdgeArrowheads(
        layout: MermaidFlowLayout, context: GraphicsContext, color: Color
    ) {
        for edge in layout.edges {
            drawArrowHead(
                context: context, at: edge.arrowAnchor, direction: edge.arrowDirection,
                head: edge.endHead, color: color)

            guard edge.startHead != .none else { continue }
            let startDirection: CGVector
            if let firstWaypoint = edge.waypoints.first {
                startDirection = normalizedVector(
                    CGVector(
                        dx: edge.start.x - firstWaypoint.x, dy: edge.start.y - firstWaypoint.y))
            } else {
                startDirection = CGVector(dx: -edge.arrowDirection.dx, dy: -edge.arrowDirection.dy)
            }
            drawArrowHead(
                context: context, at: edge.start, direction: startDirection, head: edge.startHead,
                color: color)
        }
    }

    private func drawArrowHead(
        context: GraphicsContext, at point: CGPoint, direction: CGVector,
        head: MermaidFlow.EdgeHead, color: Color
    ) {
        guard head != .none else { return }
        let normalized = normalizedVector(direction)
        guard normalized.dx != 0 || normalized.dy != 0 else { return }

        switch head {
        case .none:
            break
        case .arrow:
            let length: CGFloat = 8
            let halfBase: CGFloat = 3
            let backX = point.x - normalized.dx * length
            let backY = point.y - normalized.dy * length
            let perpX = -normalized.dy
            let perpY = normalized.dx
            var path = Path()
            path.move(to: point)
            path.addLine(
                to: CGPoint(x: backX + perpX * halfBase, y: backY + perpY * halfBase))
            path.addLine(
                to: CGPoint(x: backX - perpX * halfBase, y: backY - perpY * halfBase))
            path.closeSubpath()
            context.fill(path, with: .color(color))
        case .circle:
            let radius: CGFloat = 4
            let center = CGPoint(
                x: point.x - normalized.dx * radius, y: point.y - normalized.dy * radius)
            let rect = CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1.5)
        case .cross:
            let half: CGFloat = 4
            let center = CGPoint(
                x: point.x - normalized.dx * half, y: point.y - normalized.dy * half)
            var path = Path()
            path.move(to: CGPoint(x: center.x - half, y: center.y - half))
            path.addLine(to: CGPoint(x: center.x + half, y: center.y + half))
            path.move(to: CGPoint(x: center.x - half, y: center.y + half))
            path.addLine(to: CGPoint(x: center.x + half, y: center.y - half))
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
    }

    private func drawEdgeLabels(
        layout: MermaidFlowLayout, context: GraphicsContext, textColor: Color,
        backgroundColor: Color
    ) {
        for edge in layout.edges where !edge.label.isEmpty {
            let midpoint: CGPoint
            if edge.waypoints.isEmpty {
                midpoint = CGPoint(
                    x: (edge.start.x + edge.end.x) / 2, y: (edge.start.y + edge.end.y) / 2)
            } else {
                midpoint = edge.waypoints[edge.waypoints.count / 2]
            }

            let text = Text(edge.label).font(.caption2).foregroundColor(textColor)
            let resolvedText = context.resolve(text)
            let textSize = resolvedText.measure(in: CGSize(width: 240, height: 40))
            let backgroundRect = CGRect(
                x: midpoint.x - textSize.width / 2 - 3, y: midpoint.y - textSize.height / 2 - 1,
                width: textSize.width + 6, height: textSize.height + 2)
            context.fill(
                Path(roundedRect: backgroundRect, cornerRadius: 3), with: .color(backgroundColor))
            context.draw(text, at: midpoint, anchor: .center)
        }
    }

    private func drawNodes(
        layout: MermaidFlowLayout, context: GraphicsContext, fillColor: Color, borderColor: Color,
        textColor: Color
    ) {
        for nodeFrame in layout.nodes {
            let path = nodePath(for: nodeFrame)
            context.fill(path, with: .color(fillColor))
            context.stroke(path, with: .color(borderColor), lineWidth: 1)

            if nodeFrame.shape == .subroutine {
                let frame = nodeFrame.frame
                var insetLines = Path()
                insetLines.move(to: CGPoint(x: frame.minX + 6, y: frame.minY))
                insetLines.addLine(to: CGPoint(x: frame.minX + 6, y: frame.maxY))
                insetLines.move(to: CGPoint(x: frame.maxX - 6, y: frame.minY))
                insetLines.addLine(to: CGPoint(x: frame.maxX - 6, y: frame.maxY))
                context.stroke(insetLines, with: .color(borderColor), lineWidth: 1)
            }

            context.draw(
                Text(label(for: nodeFrame.id)).font(.system(size: 12, weight: .medium))
                    .foregroundColor(textColor),
                at: CGPoint(x: nodeFrame.frame.midX, y: nodeFrame.frame.midY), anchor: .center)
        }
    }

    private func nodePath(for nodeFrame: MermaidFlowLayout.NodeFrame) -> Path {
        let frame = nodeFrame.frame
        switch nodeFrame.shape {
        case .rectangle, .subroutine:
            return Path(roundedRect: frame, cornerRadius: 4)
        case .round:
            return Path(roundedRect: frame, cornerRadius: frame.height / 2)
        case .circle:
            return Path(ellipseIn: frame)
        case .diamond:
            var path = Path()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.midY))
            path.addLine(to: CGPoint(x: frame.midX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.midY))
            path.closeSubpath()
            return path
        case .parallelogram:
            let slant = min(12, frame.width / 4)
            var path = Path()
            path.move(to: CGPoint(x: frame.minX + slant, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX - slant, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.closeSubpath()
            return path
        case .flag:
            let notch = min(10, frame.width / 4)
            var path = Path()
            path.move(to: CGPoint(x: frame.minX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX + notch, y: frame.midY))
            path.closeSubpath()
            return path
        }
    }

    private func normalizedVector(_ vector: CGVector) -> CGVector {
        let length = (vector.dx * vector.dx + vector.dy * vector.dy).squareRoot()
        guard length > 0 else { return CGVector(dx: 0, dy: 0) }
        return CGVector(dx: vector.dx / length, dy: vector.dy / length)
    }
}

struct MermaidUnsupportedView: View {
    @Environment(\.rafuTheme) private var theme
    let type: String
    let raw: String
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(noticeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(rafuHex: theme.ui.warning ?? theme.ui.textSecondary))
            Text(raw)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color(rafuHex: theme.ui.textPrimary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(rafuHex: theme.ui.elevatedBackground),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(rafuHex: theme.ui.borderSubtle))
        }
    }

    private var noticeText: String {
        if let reason {
            return "diagram type not supported in native preview — \(reason)"
        }
        return "diagram type not supported in native preview"
    }
}
