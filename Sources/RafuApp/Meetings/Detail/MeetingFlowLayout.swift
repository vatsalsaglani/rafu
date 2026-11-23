import SwiftUI

/// Places its children left to right and wraps to a new line when the
/// width ends: speaker pills and citation chips.
struct MeetingFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat?

    private var rowGap: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height =
            rows.reduce(0) { $0 + $1.height } + rowGap * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                let width = min(size.width, bounds.width)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: size.height))
                x += width + spacing
            }
            y += row.height + rowGap
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let width = min(size.width, maxWidth)
            let next = current.indices.isEmpty ? width : current.width + spacing + width
            if !current.indices.isEmpty, next > maxWidth {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? width : current.width + spacing + width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
