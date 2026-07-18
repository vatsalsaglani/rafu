import SwiftUI

/// Blame-hover popover content (GX2): header (author + relative + absolute
/// date), body (commit summary + sha chip), footer (Copy SHA / Show in
/// History / Open Blame Canvas). Anchored to the GX1 inline-blame ghost
/// annotation; LSP hover keeps priority inside code — this card only ever
/// anchors to the annotation, never an identifier (see
/// `RafuTextView.mouseMoved`). `NSHostingController` does not inherit the
/// SwiftUI environment, so the theme is threaded explicitly, matching
/// `EditorHoverTooltipView`.
struct GitBlameHoverCard: View {
    let line: GitBlameLine
    let theme: RafuTheme
    let copySHA: () -> Void
    let showInHistory: () -> Void
    let openBlameCanvas: () -> Void

    private static let contentWidth: CGFloat = 360

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            summaryBody
            Divider().overlay(theme.palette.borderSubtle)
            footer
        }
        .frame(width: Self.contentWidth)
        .background(theme.palette.cardBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(line.author)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            HStack(spacing: 6) {
                Text(line.time, style: .relative)
                Text("•")
                Text(line.time, style: .date)
            }
            .font(.caption2)
            .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryBody: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            Text(line.summary)
                .font(.callout)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            RafuChip(text: line.shortID)
        }
        .padding(RafuMetrics.space3)
    }

    private var footer: some View {
        HStack(spacing: RafuMetrics.space3) {
            Button("Copy SHA", action: copySHA)
            Button("Show in History", action: showInHistory)
            Button("Open Blame Canvas", action: openBlameCanvas)
            Spacer(minLength: 0)
        }
        .buttonStyle(.link)
        .controlSize(.small)
        .font(.caption)
        .tint(theme.palette.accent)
        .padding(RafuMetrics.space3)
    }

    private var accessibilityLabel: String {
        "\(line.author), \(line.shortID), \(line.summary)"
    }
}
