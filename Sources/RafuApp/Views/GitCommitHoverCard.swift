import AppKit
import SwiftUI

/// History graph hover card (ADR 0013 GX3 amendment): author and email, the
/// relative and absolute date, the full message, "N files changed, X
/// insertions(+), Y deletions(-)", every ref pill, and the short hash with
/// Copy and, for a GitHub remote, "Open on GitHub". Same anatomy as
/// `GitBlameHoverCard`: header, hairline, body, hairline, footer on
/// `cardBackground`. It has no avatar and makes no network request.
struct GitCommitHoverCard: View {
    @Environment(\.rafuTheme) private var theme

    let commit: GitCommitSummary
    let refs: [GitRefLabel]
    let laneColor: Color
    let detail: GitCommitDetailStore.State?
    let gitHubURL: URL?
    /// Reports pointer enter/exit so the card stays open while the pointer
    /// moves from the row into the card.
    let onHoverChange: (Bool) -> Void

    @State private var didCopy = false

    private static let contentWidth: CGFloat = 340
    private static let maximumBodyLines = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            message
            if !refs.isEmpty {
                Divider().overlay(theme.palette.borderSubtle)
                GitRefPillFlow(spacing: 4, lineSpacing: 4) {
                    ForEach(refs, id: \.self) { ref in
                        GitRefPill(label: ref, laneColor: laneColor)
                    }
                }
                .padding(RafuMetrics.space3)
            }
            Divider().overlay(theme.palette.borderSubtle)
            footer
        }
        .frame(width: Self.contentWidth)
        .background(theme.palette.cardBackground)
        .onHover(perform: onHoverChange)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commit \(commit.shortID) by \(commit.authorName)")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(commit.authorName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                Text("<\(commit.authorEmail)>")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textSecondary)
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Text(GitCommitDateText.hoverLine(for: commit.authoredAt))
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(commit.subject)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if case .loaded(let loaded) = detail {
                let rest = GitCommitStatsPresentation.bodyWithoutSubject(loaded.body)
                if !rest.isEmpty {
                    Text(rest)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(Self.maximumBodyLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
                GitCommitStatsText(detail: loaded)
                    .font(.system(size: 11.5))
            } else if detail == .loading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading commit details")
            }
        }
        .textSelection(.enabled)
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: RafuMetrics.space2) {
            Text(commit.shortID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel("Short hash")
                .accessibilityValue(commit.shortID)
            Button(
                didCopy ? "Copied" : "Copy Hash",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            ) {
                copyHash()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(RafuIconButtonStyle(size: 20, iconSize: 10))
            .help("Copy Full Hash")
            .accessibilityLabel(didCopy ? "Copied" : "Copy full hash")
            Spacer(minLength: 0)
            if let gitHubURL {
                Button("Open on GitHub", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(gitHubURL)
                }
                .buttonStyle(.link)
                .controlSize(.small)
                .font(.caption)
                .tint(theme.palette.accent)
                .help("Open this commit on GitHub in the browser")
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
    }

    private func copyHash() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commit.id, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(RafuMotion.successHold))
            didCopy = false
        }
    }
}

/// "2 files changed, 5 insertions(+), 1 deletion(-)" with the insertions in
/// `gitAdded` and the deletions in `gitDeleted`. The words carry the meaning,
/// so the color is never the only signal.
struct GitCommitStatsText: View {
    @Environment(\.rafuTheme) private var theme
    let detail: GitCommitDetail

    var body: some View {
        let separator = Text(", ").foregroundStyle(theme.palette.textSecondary)
        (Text(GitCommitStatsPresentation.filesText(detail.filesChanged))
            .foregroundStyle(theme.palette.textSecondary)
            + separator
            + Text(GitCommitStatsPresentation.insertionsText(detail.insertions))
            .foregroundStyle(theme.palette.gitAdded)
            + separator
            + Text(GitCommitStatsPresentation.deletionsText(detail.deletions))
            .foregroundStyle(theme.palette.gitDeleted))
            .accessibilityLabel(GitCommitStatsPresentation.summary(for: detail))
    }
}

/// Dates for the hover card: "3 days ago (16 October 2026 at 12:12)".
nonisolated enum GitCommitDateText {
    static func hoverLine(for date: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named, unitsStyle: .wide))
        let absolute = date.formatted(.dateTime.day().month(.wide).year().hour().minute())
        return "\(relative) (\(absolute))"
    }
}

/// One ref pill: an SF Symbol for the kind (`target` local branch, `cloud`
/// remote branch, `tag` tag, `arrow.right.circle.fill` the checked-out
/// branch), then the name. The icon and tint use the commit's lane color;
/// the checked-out branch uses the accent. The name stays in `textPrimary`
/// so it keeps full contrast on every theme. Long names truncate in the
/// middle.
struct GitRefPill: View {
    @Environment(\.rafuTheme) private var theme
    let label: GitRefLabel
    let laneColor: Color

    static let maximumWidth: CGFloat = 120

    var body: some View {
        let tint = label.kind == .head ? theme.palette.accent : laneColor
        HStack(spacing: 3) {
            Image(systemName: Self.symbolName(for: label.kind))
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(label.name)
                .font(.system(size: 10.5, weight: label.kind == .head ? .semibold : .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 5)
        .frame(height: 16)
        .frame(maxWidth: Self.maximumWidth)
        .background(Capsule().fill(tint.opacity(0.16)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: RafuMetrics.hairline))
        .help(Self.kindTitle(for: label.kind) + " " + label.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.kindTitle(for: label.kind) + " " + label.name)
    }

    static func symbolName(for kind: GitRefLabel.Kind) -> String {
        switch kind {
        case .head: "arrow.right.circle.fill"
        case .local: "target"
        case .remote: "cloud"
        case .tag: "tag"
        }
    }

    static func kindTitle(for kind: GitRefLabel.Kind) -> String {
        switch kind {
        case .head: "Current branch"
        case .local: "Branch"
        case .remote: "Remote branch"
        case .tag: "Tag"
        }
    }
}

/// Wraps the card's ref pills onto several lines.
struct GitRefPillFlow: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let lines = arrange(maxWidth: proposal.width ?? .infinity, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height =
            lines.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                lines.append(current)
                current = Line()
            }
            current.width =
                current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}
