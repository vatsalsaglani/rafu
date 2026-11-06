import CoreGraphics
import Foundation

/// One dashed placeholder on an empty board (UX Round A, O1/S3). Its rect
/// is the rect the card it stands for takes when the user clicks it.
nonisolated struct CanvasSeed: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case note, terminal, drop }

    let id: Kind
    /// Board units.
    let rect: CanvasRect
}

/// Where the three seeds of an empty board sit: Note, Terminal and Drop, at
/// the default sizes of the cards they make, centred in the visible board.
/// One row when it fits the visible board width; otherwise Note and Terminal
/// on the first row and Drop below; otherwise one column.
nonisolated enum CanvasSeedLayout {
    static let gap = 32.0

    static func size(of kind: CanvasSeed.Kind) -> CGSize {
        switch kind {
        case .note: CanvasBoardDropGeometry.defaultSize(for: .note(snapshot: ""))
        case .terminal:
            CanvasBoardDropGeometry.defaultSize(for: .terminal(groupID: TerminalGroupID()))
        case .drop: CanvasBoardDropGeometry.defaultSize(for: .file(path: ""))
        }
    }

    static func seeds(visible: CGSize, viewport: CanvasViewport) -> [CanvasSeed] {
        guard visible.width > 0, visible.height > 0, viewport.scale > 0 else { return [] }
        let scale = viewport.scale
        let visibleWidth = Double(visible.width) / scale
        let centre = CGPoint(
            x: (Double(visible.width) / 2 - viewport.x) / scale,
            y: (Double(visible.height) / 2 - viewport.y) / scale)
        let kinds: [CanvasSeed.Kind] = [.note, .terminal, .drop]
        let rows: [[CanvasSeed.Kind]]
        if rowWidth(kinds) <= visibleWidth {
            rows = [kinds]
        } else if rowWidth([.note, .terminal]) <= visibleWidth {
            rows = [[.note, .terminal], [.drop]]
        } else {
            rows = kinds.map { [$0] }
        }
        let rowHeights = rows.map { row in row.map { Double(size(of: $0).height) }.max() ?? 0 }
        let totalHeight = rowHeights.reduce(0, +) + gap * Double(rows.count - 1)
        var seeds: [CanvasSeed] = []
        var top = Double(centre.y) - totalHeight / 2
        for (index, row) in rows.enumerated() {
            var left = Double(centre.x) - rowWidth(row) / 2
            for kind in row {
                let size = size(of: kind)
                // Each seed sits on its row's vertical centre line.
                let y = top + (rowHeights[index] - Double(size.height)) / 2
                seeds.append(
                    CanvasSeed(
                        id: kind,
                        rect: CanvasRect(
                            x: min(50_000, max(-50_000, left.rounded())),
                            y: min(50_000, max(-50_000, y.rounded())),
                            width: Double(size.width), height: Double(size.height))))
                left += Double(size.width) + gap
            }
            top += rowHeights[index] + gap
        }
        return seeds
    }

    private static func rowWidth(_ row: [CanvasSeed.Kind]) -> Double {
        row.map { Double(size(of: $0).width) }.reduce(0, +) + gap * Double(max(0, row.count - 1))
    }
}
