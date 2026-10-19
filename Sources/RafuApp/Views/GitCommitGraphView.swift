import SwiftUI

/// Caches the lane layout for the loaded commit window. The layout is O(n)
/// and depends only on the commits (a commit ID fixes its parents), so a
/// search keystroke, a selection change, or a theme change must not re-run it.
nonisolated struct CommitGraphLayoutMemo: Equatable {
    private(set) var commitIDs: [String] = []
    private(set) var rowsByID: [String: GraphRow] = [:]
    private(set) var laneCount = 1
    /// How many times the layout ran. Tests use it to prove the cache hits.
    private(set) var layoutRunCount = 0

    /// Re-runs the layout only when the commit IDs differ from the cached ones.
    @discardableResult
    mutating func update(for commits: [GitCommitSummary]) -> Bool {
        let ids = commits.map(\.id)
        guard ids != commitIDs else { return false }
        let rows = CommitGraphLayout.layout(commits)
        commitIDs = ids
        rowsByID = Dictionary(
            rows.map { ($0.commitID, $0) }, uniquingKeysWith: { first, _ in first })
        laneCount = CommitGraphLayout.laneCount(rows)
        layoutRunCount += 1
        return true
    }
}

/// Bounded, editor-hosted commit graph for the History section (GX3): a lane
/// canvas column, branch/tag chips, subject, and author/relative time,
/// replacing the plain row rendering `GitInspectorView.historyView` used
/// before. Owns its own `List(selection:)` bound to the SAME
/// `session.gitSelectedHistoryCommitID` binding the prior row list used, so
/// selection semantics are unchanged. G11: the selected commit's details
/// expand as their own non-selectable row directly under it, instead of a
/// block at the bottom of the panel.
struct GitCommitGraphView: View {
    @Environment(\.rafuTheme) private var theme

    let commits: [GitCommitSummary]
    let currentBranch: String?
    let upstream: String?
    let lastFetchedAt: Date?
    let hasMore: Bool
    let isBusy: Bool
    @Binding var selection: String?
    let detailChanges: [GitCommitFileChange]
    let isDetailLoading: Bool
    let onSelect: (GitCommitSummary) -> Void
    let onOpenDiff: (GitCommitFileChange) -> Void
    let onFetch: () -> Void
    let onLoadMore: () -> Void

    @State private var searchTerm = ""
    /// Lane layout of `commits`, refreshed only when the commit IDs change.
    @State private var layoutMemo = CommitGraphLayoutMemo()

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
        // The lane layout is cached in `layoutMemo` (refreshed by `onChange`
        // below), so a search keystroke never re-runs the O(n) layout.
        // AGENTS: no expensive work in `body`.
        let rowsByID = layoutMemo.rowsByID
        let visibleCommits = filteredCommits
        // The lane column only needs to be as wide as the widest lane the
        // LOADED window actually uses, not a fixed `visibleLaneCap` column —
        // linear history collapses to a single narrow lane.
        let laneCanvasWidth = CGFloat(layoutMemo.laneCount) * GitCommitGraphRow.laneWidth + 10
        return VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            if visibleCommits.isEmpty {
                ContentUnavailableView(
                    "No matching commits",
                    systemImage: "magnifyingglass",
                    description: Text("No loaded commits match “\(searchTerm)”.")
                )
            } else {
                List(selection: $selection) {
                    Section("Commits") {
                        ForEach(visibleCommits) { commit in
                            GitCommitGraphRow(
                                commit: commit,
                                row: rowsByID[commit.id],
                                palette: colorPalette,
                                currentBranch: currentBranch,
                                laneCanvasWidth: laneCanvasWidth
                            )
                            .tag(commit.id)
                            .contentShape(.rect)
                            .onTapGesture { onSelect(commit) }
                            if selection == commit.id {
                                GitCommitInlineDetail(
                                    commit: commit,
                                    changes: detailChanges,
                                    isLoading: isDetailLoading,
                                    openDiff: onOpenDiff
                                )
                                .selectionDisabled()
                                .listRowSeparator(.hidden)
                            }
                        }
                        if hasMore {
                            Button("Load More", systemImage: "ellipsis.circle") { onLoadMore() }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.palette.textSecondary)
                                .disabled(isBusy)
                                .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .onChange(of: commits.map(\.id), initial: true) {
            layoutMemo.update(for: commits)
        }
    }

    /// Lane colors derived from theme Git tokens (GD3, ADR 0013) — never a
    /// fixed rainbow palette — so the graph inherits every theme's palette.
    /// Gold stays out of the lanes: it is reserved for focus and selection.
    private var colorPalette: [Color] {
        [
            theme.palette.gitAdded, theme.palette.gitModified, theme.palette.gitDeleted,
            theme.palette.info, theme.palette.textSecondary, theme.palette.warning,
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
                    RafuChip(text: currentBranch, foreground: theme.palette.textPrimary)
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
        return "Last fetched \(GitRelativeTime.label(for: lastFetchedAt))"
    }
}

/// Two-line history row (G10): the title on line 1 at full width, with the
/// refs as neutral capsules after it; "short hash · author · time" on line 2.
private struct GitCommitGraphRow: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary
    let row: GraphRow?
    let palette: [Color]
    let currentBranch: String?
    /// Computed once per render by the parent from `CommitGraphLayout.laneCount`
    /// over ALL loaded rows (not just this row) so every row in the list
    /// shares one canvas width — a per-row width would make edges between
    /// rows misalign.
    let laneCanvasWidth: CGFloat

    private static let rowHeight: CGFloat = 40
    private static let visibleRefs = 3

    var body: some View {
        let refs = GitRefLabels.chips(from: commit.decorations)
        HStack(alignment: .center, spacing: RafuMetrics.space2) {
            laneCanvas
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(commit.subject)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    ForEach(refs.prefix(Self.visibleRefs), id: \.self) { ref in
                        RafuChip(
                            text: ref,
                            foreground: ref == currentBranch || ref == "HEAD"
                                ? theme.palette.textPrimary : theme.palette.textSecondary
                        )
                        .fixedSize()
                    }
                    if refs.count > Self.visibleRefs {
                        RafuChip(text: "+\(refs.count - Self.visibleRefs)").fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    Text(commit.shortID)
                        .font(.system(size: 11.5, design: .monospaced))
                    Text("·")
                    Text(commit.authorName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("·")
                    Text(GitRelativeTime.label(for: commit.authoredAt))
                        .lineLimit(1)
                        .fixedSize()
                }
                .font(.system(size: 11.5))
                .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(height: Self.rowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        let refs = GitRefLabels.chips(from: commit.decorations)
        let decorationText = refs.isEmpty ? "" : ", \(refs.joined(separator: ", "))"
        return
            "\(commit.subject), \(commit.shortID), \(commit.authorName), \(GitRelativeTime.label(for: commit.authoredAt))\(decorationText)"
    }

    fileprivate static let laneWidth: CGFloat = 14

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
        .frame(width: laneCanvasWidth, height: Self.rowHeight)
        .accessibilityHidden(true)
    }

    private func laneX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * Self.laneWidth + Self.laneWidth / 2
    }

    private func color(for lane: Int) -> Color {
        palette[lane % palette.count]
    }
}

/// Commit details shown directly under the selected history row (G11):
/// subject, author, date, the full hash in SF Mono with a Copy button, and the
/// changed files. The hash is split into fixed-width lines by character count,
/// so it never breaks at a hyphen and a copy always yields the exact hash.
private struct GitCommitInlineDetail: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary
    let changes: [GitCommitFileChange]
    let isLoading: Bool
    let openDiff: (GitCommitFileChange) -> Void

    @State private var didCopy = false

    /// Bounds the non-lazy file list for very large commits.
    private static let maximumFileRows = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(commit.subject)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(commit.authorName) <\(commit.authorEmail)>")
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(commit.authoredAt.formatted(date: .abbreviated, time: .shortened))
            }
            .font(.system(size: 11.5))
            .foregroundStyle(theme.palette.textSecondary)
            .textSelection(.enabled)
            hashRow
            Divider().overlay(theme.palette.borderSubtle)
            files
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.cardBackground)
        .clipShape(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
        )
        .padding(.vertical, 2)
    }

    private var hashRow: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(GitHashDisplay.lines(for: commit.id).enumerated()), id: \.offset) {
                    item in
                    Text(item.element)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Commit hash")
            .accessibilityValue(commit.id)
            Spacer(minLength: 4)
            Button(
                didCopy ? "Copied" : "Copy Hash",
                systemImage: didCopy ? "checkmark" : "doc.on.doc"
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(commit.id, forType: .string)
                didCopy = true
                Task {
                    try? await Task.sleep(for: .seconds(RafuMotion.successHold))
                    didCopy = false
                }
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 11))
            .help("Copy Full Hash")
        }
    }

    @ViewBuilder
    private var files: some View {
        if isLoading {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        } else if changes.isEmpty {
            Text("This commit has no file changes.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Files (\(changes.count))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.bottom, 2)
                ForEach(changes.prefix(Self.maximumFileRows)) { change in
                    fileRow(change)
                }
                if changes.count > Self.maximumFileRows {
                    Text("\(changes.count - Self.maximumFileRows) more files not shown")
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.top, 4)
                }
            }
        }
    }

    private func fileRow(_ change: GitCommitFileChange) -> some View {
        let parts = GitChangePathParts(path: change.path)
        return Button {
            openDiff(change)
        } label: {
            HStack(spacing: 6) {
                GitStatusLetterBadge(kind: change.kind)
                FileIconView(icon: FileIconProvider.fileIcon(named: parts.name), size: 12)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(parts.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let folder = parts.folder {
                    Text(folder)
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
            }
            .frame(height: 24)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open diff for \(change.path)")
    }
}
