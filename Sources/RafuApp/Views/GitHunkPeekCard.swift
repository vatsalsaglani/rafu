import SwiftUI

/// Hunk-peek popover content (GX2): the −/+ rows for one hunk, sliced
/// verbatim from the already-captured working-tree diff via `HunkPeekSlice`
/// — never a re-diff. Footer offers Stage Hunk and Open Full Diff; there is
/// no discard action here (ADR 0013 excludes discard-from-peek as
/// destructive). When the hunk was truncated (over `HunkPeekSlice.maximumRows`
/// rows) the body shows a summary and only "Open Full Diff" is offered.
struct GitHunkPeekCard: View {
    let hunk: GitDiffHunk
    let rows: [GitDiffRow]
    let isTruncated: Bool
    let theme: RafuTheme
    let isBusy: Bool
    let stageHunk: () -> Void
    let openFullDiff: () -> Void

    private static let contentWidth: CGFloat = 460
    private static let maxContentHeight: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            if isTruncated {
                truncatedSummary
            } else {
                rowsList
            }
            Divider().overlay(theme.palette.borderSubtle)
            footer
        }
        .frame(width: Self.contentWidth)
        .background(theme.palette.cardBackground)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: RafuMetrics.space2) {
            Text("Working Tree ↔ HEAD")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: RafuMetrics.space2)
            RafuChip(text: hunk.header)
        }
        .padding(RafuMetrics.space3)
    }

    private var rowsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Self.peekLines(rows)) { line in
                    GitHunkPeekLineRow(line: line)
                }
            }
        }
        .frame(maxHeight: Self.maxContentHeight)
    }

    private var truncatedSummary: some View {
        Text(
            "This hunk has more than \(HunkPeekSlice.maximumRows) lines — too large to peek. Open the full diff to review it."
        )
        .font(.caption)
        .foregroundStyle(theme.palette.textSecondary)
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: RafuMetrics.space2) {
            if !isTruncated {
                Button("Stage Hunk", action: stageHunk)
                    .buttonStyle(RafuProminentButtonStyle(compact: true))
                    .disabled(isBusy)
            }
            Button("Open Full Diff", action: openFullDiff)
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            Spacer(minLength: 0)
        }
        .padding(RafuMetrics.space3)
    }

    /// One unified −/+/context display line, flattening `GitDiffRow`'s
    /// paired old/new representation (used for the side-by-side canvas) into
    /// the peek card's compact unified list — a modification row yields a
    /// deletion line followed by an addition line.
    private struct PeekLine: Identifiable {
        let id: Int
        let content: String
        let kind: GitDiffRowKind
        let isAddition: Bool
    }

    private static func peekLines(_ rows: [GitDiffRow]) -> [PeekLine] {
        var lines: [PeekLine] = []
        for row in rows {
            switch row.kind {
            case .context:
                lines.append(
                    PeekLine(
                        id: lines.count,
                        content: row.newLine?.content ?? row.oldLine?.content ?? "",
                        kind: .context, isAddition: false))
            case .addition:
                lines.append(
                    PeekLine(
                        id: lines.count, content: row.newLine?.content ?? "", kind: .addition,
                        isAddition: true))
            case .deletion:
                lines.append(
                    PeekLine(
                        id: lines.count, content: row.oldLine?.content ?? "", kind: .deletion,
                        isAddition: false))
            case .modification:
                if let oldLine = row.oldLine {
                    lines.append(
                        PeekLine(
                            id: lines.count, content: oldLine.content, kind: .deletion,
                            isAddition: false))
                }
                if let newLine = row.newLine {
                    lines.append(
                        PeekLine(
                            id: lines.count, content: newLine.content, kind: .addition,
                            isAddition: true))
                }
            }
        }
        return lines
    }

    private struct GitHunkPeekLineRow: View {
        @Environment(\.rafuTheme) private var theme
        let line: PeekLine

        var body: some View {
            HStack(spacing: 6) {
                Text(marker)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(markerColor)
                    .frame(width: 14, alignment: .center)
                Text(line.content)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, RafuMetrics.space3)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }

        private var marker: String {
            switch line.kind {
            case .addition: "+"
            case .deletion: "−"
            case .modification, .context: " "
            }
        }

        private var markerColor: Color {
            switch line.kind {
            case .addition: theme.palette.diffAddedGutter
            case .deletion: theme.palette.diffRemovedGutter
            case .modification, .context: theme.palette.textMuted
            }
        }

        private var background: Color {
            switch line.kind {
            case .addition: theme.palette.diffAddedBackground
            case .deletion: theme.palette.diffRemovedBackground
            case .modification, .context: .clear
            }
        }
    }
}
