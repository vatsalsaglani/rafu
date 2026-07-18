import SwiftUI

/// Bounded, editor-hosted commit graph for the History section (GX3): a lane
/// canvas column, branch/tag chips, subject, and author/relative time,
/// replacing the plain row rendering `GitInspectorView.historyView` used
/// before. Owns its own `List(selection:)` bound to the SAME
/// `session.gitSelectedHistoryCommitID` binding the prior row list used, so
/// selection semantics and the `GitHistoryDetail` panel above it are
/// unchanged — only the row content and the header (search/branch/fetch/load
/// more) are new.
struct GitCommitGraphView: View {
    @Environment(\.rafuTheme) private var theme

    let commits: [GitCommitSummary]
    let currentBranch: String?
    let upstream: String?
    let lastFetchedAt: Date?
    let hasMore: Bool
    let isBusy: Bool
    @Binding var selection: String?
    let onSelect: (GitCommitSummary) -> Void
    let onFetch: () -> Void
    let onLoadMore: () -> Void

    @State private var searchTerm = ""

    /// Filters the LOADED commits only — never a repository-wide scan (ADR
    /// 0013). The header label makes this explicit.
    private var filteredCommits: [GitCommitSummary] {
        let trimmed = searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return commits }
        let needle = trimmed.lowercased()
        return commits.filter { commit in
            commit.subject.lowercased().contains(needle)
                || commit.authorName.lowercased().contains(needle)
                || commit.shortID.lowercased().contains(needle)
        }
    }

    var body: some View {
        // Compute the lane layout once per render (not once per row): reading a
        // computed `rowsByID` inside the ForEach would run the O(n) layout n
        // times, and re-run on every search keystroke. AGENTS: no expensive
        // work in `body` — hoist it here so it is built exactly once.
        let rowsByID = Dictionary(
            uniqueKeysWithValues: CommitGraphLayout.layout(commits).map { ($0.commitID, $0) })
        return VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            if filteredCommits.isEmpty {
                ContentUnavailableView(
                    "No matching commits",
                    systemImage: "magnifyingglass",
                    description: Text("No loaded commits match “\(searchTerm)”.")
                )
            } else {
                List(selection: $selection) {
                    Section("Commits") {
                        ForEach(filteredCommits) { commit in
                            GitCommitGraphRow(
                                commit: commit,
                                row: rowsByID[commit.id],
                                palette: colorPalette,
                                currentBranch: currentBranch
                            )
                            .tag(commit.id)
                            .contentShape(.rect)
                            .onTapGesture { onSelect(commit) }
                        }
                        if hasMore {
                            Button("Load More", systemImage: "ellipsis.circle") { onLoadMore() }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.palette.accent)
                                .disabled(isBusy)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }

    /// Lane colors derived from theme Git tokens (GD3, ADR 0013) — never a
    /// fixed rainbow palette — so the graph inherits every theme's palette.
    private var colorPalette: [Color] {
        [
            theme.palette.gitAdded, theme.palette.gitModified, theme.palette.gitDeleted,
            theme.palette.info, theme.palette.accent, theme.palette.warning,
        ]
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            HStack(spacing: RafuMetrics.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                TextField("Search in loaded commits", text: $searchTerm)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .rafuField()
            HStack(spacing: RafuMetrics.space2) {
                if let currentBranch {
                    RafuChip(text: currentBranch, foreground: theme.palette.accent)
                }
                if let upstream {
                    RafuChip(text: upstream)
                }
                Spacer(minLength: RafuMetrics.space2)
                Button("Fetch", systemImage: "arrow.clockwise") { onFetch() }
                    .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 11))
                    .disabled(isBusy)
                    .help(fetchHelp)
            }
        }
        .padding(RafuMetrics.space3)
    }

    private var fetchHelp: String {
        guard let lastFetchedAt else {
            return "Fetch from the remote — Rafu never fetches automatically"
        }
        let formatter = RelativeDateTimeFormatter()
        return "Last fetched \(formatter.localizedString(for: lastFetchedAt, relativeTo: Date()))"
    }
}

private struct GitCommitGraphRow: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary
    let row: GraphRow?
    let palette: [Color]
    let currentBranch: String?

    var body: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            laneCanvas
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    ForEach(decorationChips, id: \.self) { decoration in
                        RafuChip(
                            text: decoration,
                            foreground: decoration == currentBranch
                                ? theme.palette.accent : theme.palette.info
                        )
                    }
                    Text(commit.subject).font(.callout.weight(.medium)).lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(commit.shortID).font(.caption2.monospaced())
                    Text(commit.authorName).lineLimit(1)
                    Spacer()
                    Text(commit.authoredAt, style: .relative)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var decorationChips: [String] {
        Array(commit.decorations.prefix(3))
    }

    private var accessibilityLabel: String {
        let decorationText =
            commit.decorations.isEmpty ? "" : ", \(commit.decorations.joined(separator: ", "))"
        return "\(commit.subject), \(commit.shortID), \(commit.authorName)\(decorationText)"
    }

    private static let laneWidth: CGFloat = 14
    private static let laneCanvasWidth =
        CGFloat(CommitGraphLayout.visibleLaneCap) * laneWidth + 10

    private var laneCanvas: some View {
        Canvas { context, size in
            guard let row else { return }
            let midY = size.height / 2
            for edge in row.incomingEdges {
                var path = Path()
                path.move(to: CGPoint(x: laneX(edge.fromLane), y: 0))
                path.addLine(to: CGPoint(x: laneX(edge.toLane), y: midY))
                context.stroke(path, with: .color(color(for: edge.fromLane)), lineWidth: 1.5)
            }
            for edge in row.outgoingEdges {
                var path = Path()
                path.move(to: CGPoint(x: laneX(edge.fromLane), y: midY))
                path.addLine(to: CGPoint(x: laneX(edge.toLane), y: size.height))
                context.stroke(path, with: .color(color(for: edge.toLane)), lineWidth: 1.5)
            }
            let dotX = laneX(row.laneIndex)
            let dotRect = CGRect(x: dotX - 3, y: midY - 3, width: 6, height: 6)
            context.fill(Path(ellipseIn: dotRect), with: .color(color(for: row.laneIndex)))
            if row.overflowLaneCount > 0 {
                context.draw(
                    Text("+\(row.overflowLaneCount)").font(.system(size: 8)),
                    at: CGPoint(x: size.width - 8, y: midY)
                )
            }
        }
        .frame(width: Self.laneCanvasWidth, height: 30)
        .accessibilityHidden(true)
    }

    private func laneX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
    }

    private func color(for lane: Int) -> Color {
        palette[lane % palette.count]
    }
}
