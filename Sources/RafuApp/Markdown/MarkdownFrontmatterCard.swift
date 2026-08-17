import AppKit
import SwiftUI

struct MarkdownFrontmatterCard: View {
    let result: MarkdownFrontmatterParseResult

    @Environment(\.rafuTheme) private var theme
    @State private var isCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                cardBody
            }
        }
        .background(theme.palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            titleRow
            if !isCollapsed,
                case .parsed(let metadata) = result,
                let description = metadata.description
            {
                Text(description)
                    .font(.system(size: 13.5))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space3)
        .overlay(alignment: .bottom) {
            if !isCollapsed {
                Divider().overlay(theme.palette.borderSubtle)
            }
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            if case .parsed(let metadata) = result {
                if let title = metadata.title {
                    Text(title)
                        .font(.system(size: 19, weight: .bold))
                        .tracking(-0.19)
                        .foregroundStyle(theme.palette.textPrimary)
                }
                Text("\(metadata.fieldCount) FIELDS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(theme.palette.textMuted)
            }

            Spacer(minLength: RafuMetrics.space2)
            copyButton
            collapseButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var copyButton: some View {
        Button {
            copyMetadata()
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
        .help("Copy metadata")
        .accessibilityLabel("Copy document metadata")
    }

    private var collapseButton: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
        }
        .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
        .help(isCollapsed ? "Expand metadata" : "Collapse metadata")
        .accessibilityLabel(isCollapsed ? "Expand metadata" : "Collapse metadata")
    }

    @ViewBuilder
    private var cardBody: some View {
        switch result {
        case .parsed(let metadata):
            VStack(alignment: .leading, spacing: 0) {
                ForEach(fieldItems(from: metadata.fields)) { item in
                    MarkdownFrontmatterFieldRow(
                        field: item.field,
                        showsDivider: item.index < metadata.fields.count - 1)
                }
            }
            .padding(RafuMetrics.space3)
            .textSelection(.enabled)

        case .unparsed(let raw):
            Text(verbatim: raw)
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(theme.palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(RafuMetrics.space3)
                .textSelection(.enabled)
        }
    }

    private func fieldItems(from fields: [MarkdownFrontmatter.Field])
        -> [MarkdownFrontmatterFieldItem]
    {
        fields.enumerated().map { index, field in
            MarkdownFrontmatterFieldItem(
                id: "\(index):\(field.key)", field: field, index: index)
        }
    }

    private func copyMetadata() {
        let raw: String
        switch result {
        case .parsed(let metadata): raw = metadata.raw
        case .unparsed(let value): raw = value
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(raw, forType: .string)
    }
}

private struct MarkdownFrontmatterFieldItem: Identifiable {
    let id: String
    let field: MarkdownFrontmatter.Field
    let index: Int
}

private struct MarkdownFrontmatterFieldRow: View {
    let field: MarkdownFrontmatter.Field
    let showsDivider: Bool

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Text(field.key)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(theme.palette.textMuted)
                .frame(width: 150, alignment: .leading)

            valueView
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, RafuMetrics.space1)
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider().overlay(theme.palette.borderSubtle.opacity(0.55))
            }
        }
    }

    @ViewBuilder
    private var valueView: some View {
        switch field.value {
        case .scalar(let value):
            HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space1) {
                if let color = swatchColor(for: value) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(color)
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(theme.palette.textPrimary.opacity(0.18))
                        )
                        .frame(width: 10, height: 10)
                }
                valueText(value)
            }

        case .list(let values):
            MarkdownFrontmatterFlowLayout(
                spacing: RafuMetrics.space1, lineSpacing: RafuMetrics.space1
            ) {
                ForEach(tokenItems(from: values)) { item in
                    Text(item.value)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(theme.palette.chipBackground)
                        )
                }
            }

        case .block(let value):
            valueText(value)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tokenItems(from values: [String]) -> [MarkdownFrontmatterToken] {
        values.enumerated().map { index, value in
            MarkdownFrontmatterToken(id: "\(index):\(value)", value: value)
        }
    }

    private func valueText(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 12.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(theme.palette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func swatchColor(for value: String) -> Color? {
        if let hex = expandedHex(value) {
            return Color(rafuHex: hex)
        }

        switch value.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "teal": return .teal
        case "cyan": return .cyan
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "gray": return .gray
        case "black": return .black
        case "white": return .white
        case "brown": return .brown
        case "indigo": return .indigo
        case "mint": return .mint
        default: return nil
        }
    }

    private func expandedHex(_ value: String) -> String? {
        guard value.first == "#" else { return nil }
        let digits = String(value.dropFirst())
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard digits.count == 3 || digits.count == 6,
            digits.unicodeScalars.allSatisfy({ allowed.contains($0) })
        else {
            return nil
        }
        guard digits.count == 3 else { return value }
        return "#" + digits.map { String(repeating: String($0), count: 2) }.joined()
    }
}

private struct MarkdownFrontmatterToken: Identifiable {
    let id: String
    let value: String
}

private struct MarkdownFrontmatterFlowLayout: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = rowIndices(maxWidth: maxWidth, subviews: subviews)
        let width = proposal.width ?? rows.map { rowWidth($0, subviews: subviews) }.max() ?? 0
        let height = rows.enumerated().reduce(CGFloat.zero) { total, pair in
            total + rowHeight(pair.element, subviews: subviews)
                + (pair.offset == rows.count - 1 ? 0 : lineSpacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rowIndices(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY

        for (rowIndex, row) in rows.enumerated() {
            var x = bounds.minX
            let height = rowHeight(row, subviews: subviews)
            for index in row {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += height + (rowIndex == rows.count - 1 ? 0 : lineSpacing)
        }
    }

    private func rowIndices(maxWidth: CGFloat, subviews: Subviews) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0

        for index in subviews.indices {
            let width = subviews[index].sizeThatFits(.unspecified).width
            let proposedWidth = current.isEmpty ? width : currentWidth + spacing + width
            if !current.isEmpty && proposedWidth > maxWidth {
                rows.append(current)
                current = []
                currentWidth = 0
            }
            current.append(index)
            currentWidth =
                current.isEmpty ? width : currentWidth + (current.count == 1 ? 0 : spacing) + width
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func rowWidth(_ row: [Int], subviews: Subviews) -> CGFloat {
        row.reduce(CGFloat.zero) { total, index in
            total + subviews[index].sizeThatFits(.unspecified).width
        } + spacing * CGFloat(max(0, row.count - 1))
    }

    private func rowHeight(_ row: [Int], subviews: Subviews) -> CGFloat {
        row.map { subviews[$0].sizeThatFits(.unspecified).height }.max() ?? 0
    }
}
