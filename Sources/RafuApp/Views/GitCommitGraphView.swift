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

/// Holds the memo outside SwiftUI observation. `body` asks it for the layout of
/// the current commits, so the very first frame already has lanes (no empty
/// first pass), and a selection or search pass reuses the cached rows. The
/// layout runs only when the commit IDs differ. Mutating this reference during
/// `body` invalidates nothing, because nothing observes it.
final class CommitGraphLayoutCache {
    private var memo = CommitGraphLayoutMemo()
    private var laneColorKey = ""
    private var laneColors: [Color] = []

    var layoutRunCount: Int { memo.layoutRunCount }

    func layout(for commits: [GitCommitSummary]) -> CommitGraphLayoutMemo {
        memo.update(for: commits)
        return memo
    }

    /// The eight lane colors of `theme`, derived once per theme.
    func laneColors(for theme: RafuTheme) -> [Color] {
        let key = "\(theme.name)|\(theme.ui.accent)|\(theme.git?.modified ?? "")"
        if key != laneColorKey || laneColors.isEmpty {
            laneColors = CommitGraphPalette.lanes(from: theme.palette)
            laneColorKey = key
        }
        return laneColors
    }
}

/// Layout constants shared by the graph rows and the expanded commit row.
nonisolated enum GitCommitGraphMetrics {
    static let rowHeight: CGFloat = 22
    static let laneWidth: CGFloat = 12
    /// The first lane's centre from the canvas's leading edge. The HEAD
    /// ring (radius 5.5, 1.5 pt stroke) then starts 1.75 pt inside it.
    static let firstLaneCenter: CGFloat = 8
    /// Room right of the last lane's centre: the HEAD ring's radius plus
    /// half its stroke, rounded up. Nothing wider is reserved.
    static let laneTrailingPadding: CGFloat = 7
    /// Leading 6 pt: with `firstLaneCenter`, the outer edge of the first
    /// node's ring sits about 8 pt inside the row's selection pill.
    static let rowInsets = EdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)

    static func laneX(_ lane: Int) -> CGFloat {
        CGFloat(lane) * laneWidth + firstLaneCenter
    }

    /// The lane column's width for `laneCount` lanes: up to the last lane's
    /// node plus its ring, so the subject starts right after the widest
    /// lane the loaded rows use (never the 8-lane cap's width).
    static func laneCanvasWidth(laneCount: Int) -> CGFloat {
        laneX(max(1, laneCount) - 1) + laneTrailingPadding
    }
}

/// Bounded, editor-hosted commit graph for the History section (GX3, ADR
/// 0013 amendment 2026-10-20): GitLens-style single-line rows with
/// continuous lane rails, ref pills, and a hover card. Owns its own
/// `List(selection:)` bound to `session.gitSelectedHistoryCommitID`, so
/// selection semantics are unchanged. G11: the selected commit's files
/// expand as their own non-selectable row directly under it.
struct GitCommitGraphView: View {
    @Environment(\.rafuTheme) private var theme

    let commits: [GitCommitSummary]
    /// Only names the remote for "Open on GitHub"; not shown in the header.
    let upstream: String?
    let lastFetchedAt: Date?
    let hasMore: Bool
    let isBusy: Bool
    /// The repository the commits come from. Hover details load from it.
    let rootURL: URL?
    /// The checked-out commit. Its row is tinted and its node has a ring.
    let headOID: String?
    @Binding var selection: String?
    let detailChanges: [GitCommitFileChange]
    let isDetailLoading: Bool
    let onSelect: (GitCommitSummary) -> Void
    let onOpenDiff: (GitCommitFileChange) -> Void
    let onFetch: () -> Void
    let onLoadMore: () -> Void

    @State private var searchTerm = ""
    /// Lane layout of `commits`, recomputed only when the commit IDs change.
    @State private var layoutCache = CommitGraphLayoutCache()
    @State private var detailStore = GitCommitDetailStore()
    /// The commit whose hover card is shown. Only that row's popover is
    /// presented; every other row's binding reads `false`.
    @State private var hoverCardID: String?
    @State private var isPointerInCard = false
    @State private var hoverTask: Task<Void, Never>?
    /// The selection this view already asked the session to load, so a tap
    /// and the selection change it causes load the commit once.
    @State private var requestedSelectionID: String?

    private static let hoverDelay: Duration = .milliseconds(450)
    /// Time for the pointer to travel from the row into the card.
    private static let dismissGrace: Duration = .milliseconds(220)

    private var trimmedSearch: String {
        searchTerm.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Filters the LOADED commits only — never a repository-wide scan (ADR
    /// 0013). The field's placeholder makes this explicit.
    private var filteredCommits: [GitCommitSummary] {
        let trimmed = trimmedSearch
        guard !trimmed.isEmpty else { return commits }
        let needle = trimmed.lowercased()
        return commits.filter { commit in
            commit.subject.lowercased().contains(needle)
                || commit.authorName.lowercased().contains(needle)
                || commit.shortID.lowercased().contains(needle)
        }
    }

    /// The remote whose web page "Open on GitHub" uses: the upstream's
    /// remote, else `origin`.
    private var remoteName: String {
        guard let upstream, let slash = upstream.firstIndex(of: "/") else { return "origin" }
        return String(upstream[..<slash])
    }

    var body: some View {
        // The lane layout and colors are cached (see
        // `CommitGraphLayoutCache`), so the first frame has lanes and a
        // search or selection pass reuses them. AGENTS: no expensive work
        // in `body`.
        let layoutMemo = layoutCache.layout(for: commits)
        let rowsByID = layoutMemo.rowsByID
        let laneColors = layoutCache.laneColors(for: theme)
        let visibleCommits = filteredCommits
        // A filtered list skips commits, so its rails would not connect.
        let showsRails = trimmedSearch.isEmpty
        // The lane column is only as wide as the widest lane the LOADED
        // window uses (recomputed when a page loads); linear history
        // collapses to a single narrow lane. One width for every row keeps
        // the rails aligned.
        let laneCanvasWidth = GitCommitGraphMetrics.laneCanvasWidth(
            laneCount: layoutMemo.laneCount)
        return VStack(spacing: 0) {
            header
            Divider().overlay(theme.palette.borderSubtle)
            if visibleCommits.isEmpty {
                ContentUnavailableView(
                    "No matching commits",
                    systemImage: "magnifyingglass",
                    description: Text("No loaded commits match “\(searchTerm)”.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(visibleCommits) { commit in
                        let row = rowsByID[commit.id]
                        GitCommitGraphRow(
                            commit: commit,
                            row: row,
                            laneColors: laneColors,
                            isHead: commit.id == headOID,
                            showsRails: showsRails,
                            laneCanvasWidth: laneCanvasWidth
                        )
                        .tag(commit.id)
                        .contentShape(.rect)
                        .onTapGesture { select(commit) }
                        .onHover { inside in rowHoverChanged(commit.id, inside: inside) }
                        .popover(
                            isPresented: hoverBinding(for: commit.id), arrowEdge: .trailing
                        ) {
                            hoverCard(for: commit, row: row, laneColors: laneColors)
                        }
                        .listRowInsets(GitCommitGraphMetrics.rowInsets)
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            commit.id == headOID ? theme.palette.accent.opacity(0.10) : nil)
                        if selection == commit.id {
                            GitCommitInlineDetail(
                                commit: commit,
                                railLanes: showsRails ? (row?.lanesBelow ?? []) : [],
                                laneColors: laneColors,
                                laneCanvasWidth: laneCanvasWidth,
                                detail: rootURL.flatMap {
                                    detailStore.state(for: commit.id, rootURL: $0)
                                },
                                changes: detailChanges,
                                isLoading: isDetailLoading,
                                openDiff: onOpenDiff
                            )
                            .selectionDisabled()
                            .listRowInsets(GitCommitGraphMetrics.rowInsets)
                            .listRowSeparator(.hidden)
                        }
                    }
                    if hasMore {
                        Button("Load More", systemImage: "ellipsis.circle") { onLoadMore() }
                            .buttonStyle(.plain)
                            .foregroundStyle(theme.palette.textSecondary)
                            .disabled(isBusy)
                            .padding(.vertical, 4)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, GitCommitGraphMetrics.rowHeight)
                .onScrollPhaseChange { _, phase in
                    if phase != .idle { dismissHoverCard() }
                }
            }
        }
        .onChange(of: selection) { _, newValue in
            selectionChanged(to: newValue)
        }
        .onAppear {
            // The session already holds the selected commit's files; only
            // the body and totals for the expanded row load here.
            if let selection, let rootURL { detailStore.load(selection, rootURL: rootURL) }
        }
        .onDisappear {
            hoverTask?.cancel()
            hoverTask = nil
            hoverCardID = nil
            detailStore.cancelAll()
        }
    }

    // MARK: Header

    /// One 28 pt row: search (loaded commits only) and Fetch. The branch and
    /// upstream are not repeated here: the repository row above the tabs
    /// (branch menu and sync state) already shows both, and in a narrow
    /// sidebar the search field squeezed a branch chip to an empty capsule.
    private var header: some View {
        HStack(spacing: RafuMetrics.space2) {
            HStack(spacing: RafuMetrics.space2) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
                TextField("Search loaded commits", text: $searchTerm)
                    .textFieldStyle(.plain)
                    .font(.caption)
            }
            .rafuField()
            .layoutPriority(1)
            Button("Fetch", systemImage: "arrow.clockwise") { onFetch() }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 11))
                .disabled(isBusy)
                .help(fetchHelp)
        }
        .frame(minHeight: 28)
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
    }

    private var fetchHelp: String {
        guard let lastFetchedAt else {
            return "Fetch from the remote — Rafu never fetches automatically"
        }
        return "Last fetched \(GitRelativeTime.label(for: lastFetchedAt))"
    }

    // MARK: Selection

    private func select(_ commit: GitCommitSummary) {
        requestedSelectionID = commit.id
        onSelect(commit)
    }

    /// Keyboard selection (arrow keys) changes the binding without a tap, so
    /// the expanded row would show the previous commit's files. Load the
    /// newly selected commit here unless this view already asked for it.
    private func selectionChanged(to id: String?) {
        dismissHoverCard()
        guard let id else {
            requestedSelectionID = nil
            return
        }
        if let rootURL { detailStore.load(id, rootURL: rootURL) }
        guard id != requestedSelectionID,
            let commit = commits.first(where: { $0.id == id })
        else { return }
        requestedSelectionID = id
        onSelect(commit)
    }

    // MARK: Hover card

    private func hoverBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { hoverCardID == id },
            set: { isPresented in
                if !isPresented, hoverCardID == id { dismissHoverCard() }
            }
        )
    }

    @ViewBuilder
    private func hoverCard(
        for commit: GitCommitSummary, row: GraphRow?, laneColors: [Color]
    ) -> some View {
        let laneColor = laneColors[(row?.laneIndex ?? 0) % laneColors.count]
        GitCommitHoverCard(
            commit: commit,
            refs: GitRefLabels.labels(from: commit.decorations),
            laneColor: laneColor,
            detail: rootURL.flatMap { detailStore.state(for: commit.id, rootURL: $0) },
            gitHubURL: rootURL.flatMap {
                detailStore.gitHubCommitURL(for: commit.id, rootURL: $0, remote: remoteName)
            },
            onHoverChange: cardHoverChanged
        )
        // A popover is its own window: install the theme and its tint.
        .rafuTheme(theme)
    }

    private func rowHoverChanged(_ id: String, inside: Bool) {
        hoverTask?.cancel()
        if inside {
            guard hoverCardID != id else { return }
            // Moving onto another row closes the open card at once; the
            // card sits beside the rows, so the pointer never crosses a row
            // on its way into it.
            if hoverCardID != nil { dismissHoverCard() }
            hoverTask = Task {
                try? await Task.sleep(for: Self.hoverDelay)
                guard !Task.isCancelled else { return }
                showHoverCard(for: id)
            }
        } else if hoverCardID == id {
            scheduleDismissal()
        }
    }

    private func cardHoverChanged(_ inside: Bool) {
        isPointerInCard = inside
        if inside {
            hoverTask?.cancel()
        } else {
            scheduleDismissal()
        }
    }

    private func scheduleDismissal() {
        hoverTask?.cancel()
        hoverTask = Task {
            try? await Task.sleep(for: Self.dismissGrace)
            guard !Task.isCancelled, !isPointerInCard else { return }
            dismissHoverCard()
        }
    }

    private func showHoverCard(for id: String) {
        hoverCardID = id
        guard let rootURL else { return }
        detailStore.load(id, rootURL: rootURL)
        detailStore.resolveRemote(remoteName, rootURL: rootURL)
    }

    /// Closes the card and stops its unfinished load (the selected commit's
    /// load is kept: the expanded row shows it too).
    private func dismissHoverCard() {
        hoverTask?.cancel()
        hoverTask = nil
        isPointerInCard = false
        guard let id = hoverCardID else { return }
        hoverCardID = nil
        if id != selection, let rootURL { detailStore.cancel(id, rootURL: rootURL) }
    }
}

/// One 22 pt history row: lane canvas, subject, dimmed author, ref pills, and
/// relative time. The checked-out commit's subject is semibold, and its row
/// is tinted by the parent.
private struct GitCommitGraphRow: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary
    let row: GraphRow?
    let laneColors: [Color]
    let isHead: Bool
    let showsRails: Bool
    /// Computed once per render by the parent from `CommitGraphLayout.laneCount`
    /// over ALL loaded rows, so every row shares one canvas width — a
    /// per-row width would misalign the rails between rows.
    let laneCanvasWidth: CGFloat

    var body: some View {
        let refs = GitRefLabels.labels(from: commit.decorations)
        let laneColor = laneColors[(row?.laneIndex ?? 0) % laneColors.count]
        HStack(spacing: GitCommitRowPlan.spacing) {
            GitCommitLaneCanvas(
                row: row,
                laneColors: laneColors,
                isHead: isHead,
                showsRails: showsRails
            )
            .frame(width: laneCanvasWidth, height: GitCommitGraphMetrics.rowHeight)
            // Subject, author, ref pills, and time share the rest of the row
            // by `GitCommitRowPlan`: the subject keeps its floor, the pills
            // step down (full, short, icon only, "+n"), and the author shows
            // only with room for it. Every pill density is a subview; the
            // layout gives the unused ones zero width.
            GitCommitRowLayout {
                Text(commit.subject)
                    .font(.system(size: 12.5, weight: isHead ? .semibold : .regular))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .commitRowSlot(.subject)
                Text(commit.authorName)
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .commitRowSlot(.author)
                if !refs.isEmpty {
                    ForEach(GitRefPillDensity.allCases, id: \.self) { density in
                        GitRefPillGroup(refs: refs, density: density, laneColor: laneColor)
                            .commitRowSlot(.pills(density))
                    }
                }
                Text(GitRelativeTime.label(for: commit.authoredAt))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
                    .commitRowSlot(.time)
            }
        }
        .frame(height: GitCommitGraphMetrics.rowHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(refs: refs))
    }

    private func accessibilityLabel(refs: [GitRefLabel]) -> String {
        var parts = [
            commit.subject, commit.authorName, GitRelativeTime.label(for: commit.authoredAt),
        ]
        if isHead { parts.append("current") }
        if row?.isMerge == true { parts.append("merge commit") }
        parts += refs.map { GitRefPill.kindTitle(for: $0.kind) + " " + $0.name }
        return parts.joined(separator: ", ")
    }
}

/// How a history row's text column divides its width (ADR 0013 amendment,
/// round 5). The subject always wins: it keeps a floor before anything
/// else gets room. The ref pills come next and step down in density until
/// they fit; they are never squeezed below their own width. The subject
/// then takes what is left, and the author shows only when there is room
/// for it. Pure, so the order is tested without a view.
nonisolated struct GitCommitRowPlan: Equatable, Sendable {
    /// Gap between the slots, and between the lane canvas and the subject.
    static let spacing: CGFloat = 6
    /// The subject's floor is this, or `subjectShare` of the text column
    /// when that is wider. A shorter subject needs only its own width.
    static let minimumSubjectWidth: CGFloat = 90
    static let subjectShare: CGFloat = 0.4
    /// The author shows with this much room, or room for the whole name;
    /// never as a one-letter fragment. The hover card and VoiceOver keep it.
    static let minimumAuthorWidth: CGFloat = 60

    var subjectWidth: CGFloat
    /// `nil` hides the author.
    var authorWidth: CGFloat?
    /// Index into the `pills` widths given to `make` (densest last); `nil`
    /// hides the pills.
    var pillLevel: Int?
    var pillWidth: CGFloat
    var timeWidth: CGFloat

    /// - Parameters:
    ///   - width: the whole text column, time included.
    ///   - subject, author, time: each slot's ideal (untruncated) width.
    ///   - pills: the pill strip's ideal width at each density, in the
    ///     order they are tried; empty when the commit has no refs.
    static func make(
        width: CGFloat, subject: CGFloat, author: CGFloat, pills: [CGFloat], time: CGFloat
    ) -> GitCommitRowPlan {
        let text = max(0, width - time - spacing)
        let subjectFloor = min(subject, max(minimumSubjectWidth, text * subjectShare))
        let pillRoom = text - subjectFloor - spacing
        let pillLevel = pills.firstIndex { $0 <= pillRoom }
        let pillWidth = pillLevel.map { pills[$0] } ?? 0
        let afterPills = pillLevel == nil ? text : text - pillWidth - spacing
        let subjectWidth = max(0, min(subject, afterPills))
        let authorRoom = afterPills - subjectWidth - spacing
        let showsAuthor = author > 0 && authorRoom >= min(author, minimumAuthorWidth)
        return GitCommitRowPlan(
            subjectWidth: subjectWidth,
            authorWidth: showsAuthor ? min(author, authorRoom) : nil,
            pillLevel: pillLevel,
            pillWidth: pillWidth,
            timeWidth: time
        )
    }
}

/// One subview of `GitCommitRowLayout`.
nonisolated enum GitCommitRowSlot: Hashable, Sendable {
    case subject
    case author
    case pills(GitRefPillDensity)
    case time
}

private nonisolated struct GitCommitRowSlotKey: LayoutValueKey {
    static let defaultValue = GitCommitRowSlot.subject
}

extension View {
    /// Marks a `GitCommitRowLayout` subview. The flexible, clipped frame
    /// lets the layout hide a slot by proposing zero width; a bare `Text`
    /// proposed zero width can still draw an ellipsis.
    fileprivate func commitRowSlot(_ slot: GitCommitRowSlot) -> some View {
        frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .layoutValue(key: GitCommitRowSlotKey.self, value: slot)
    }
}

/// Places a history row's subject, author, ref pills, and time by
/// `GitCommitRowPlan`. Each subview's ideal width is measured once into
/// the cache (no `GeometryReader`, no second pass). Every pill density is a
/// subview; the ones the plan does not choose get zero width.
private struct GitCommitRowLayout: Layout {
    struct Cache {
        var slots: [GitCommitRowSlot] = []
        var idealWidths: [CGFloat] = []
        var height: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        var cache = Cache()
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            cache.slots.append(subview[GitCommitRowSlotKey.self])
            cache.idealWidths.append(size.width)
            cache.height = max(cache.height, size.height)
        }
        return cache
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache)
        -> CGSize
    {
        if let width = proposal.width, width.isFinite {
            return CGSize(width: width, height: cache.height)
        }
        let full = plan(width: .infinity, cache: cache)
        let gaps = CGFloat(full.pillLevel == nil ? 1 : 2) * GitCommitRowPlan.spacing
        let ideal =
            full.subjectWidth + (full.authorWidth.map { $0 + GitCommitRowPlan.spacing } ?? 0)
            + full.pillWidth + full.timeWidth + gaps
        return CGSize(width: ideal, height: cache.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache
    ) {
        let spacing = GitCommitRowPlan.spacing
        let plan = plan(width: bounds.width, cache: cache)
        let chosenDensity = plan.pillLevel.map { pillDensities(cache)[$0] }
        let textEnd = bounds.maxX - plan.timeWidth - spacing
        for index in subviews.indices {
            let x: CGFloat
            let width: CGFloat?
            switch cache.slots[index] {
            case .subject:
                (x, width) = (bounds.minX, plan.subjectWidth)
            case .author:
                (x, width) = (bounds.minX + plan.subjectWidth + spacing, plan.authorWidth)
            case .pills(let density):
                (x, width) = (
                    textEnd - plan.pillWidth, density == chosenDensity ? plan.pillWidth : nil
                )
            case .time:
                (x, width) = (bounds.maxX - plan.timeWidth, plan.timeWidth)
            }
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width ?? 0, height: bounds.height))
        }
    }

    private func pillDensities(_ cache: Cache) -> [GitRefPillDensity] {
        cache.slots.compactMap { slot in
            if case .pills(let density) = slot { density } else { nil }
        }
    }

    private func plan(width: CGFloat, cache: Cache) -> GitCommitRowPlan {
        func idealWidth(_ slot: GitCommitRowSlot) -> CGFloat {
            cache.slots.firstIndex(of: slot).map { cache.idealWidths[$0] } ?? 0
        }
        return GitCommitRowPlan.make(
            width: width,
            subject: idealWidth(.subject),
            author: idealWidth(.author),
            pills: pillDensities(cache).map { idealWidth(.pills($0)) },
            time: idealWidth(.time)
        )
    }
}

/// A row's ref pills at one density: up to three pills plus "+n" for the
/// rest, or (`counter`) a single "+n" capsule for every ref. Each pill and
/// the counter keep the full ref name in their tooltip; the row's
/// VoiceOver label lists every ref.
private struct GitRefPillGroup: View {
    @Environment(\.rafuTheme) private var theme
    let refs: [GitRefLabel]
    let density: GitRefPillDensity
    let laneColor: Color

    private static let visibleRefs = 3

    var body: some View {
        if density == .counter {
            Text("+\(refs.count)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, 5)
                .frame(height: 16)
                .background(Capsule().fill(laneColor.opacity(0.16)))
                .overlay(
                    Capsule().strokeBorder(laneColor.opacity(0.45), lineWidth: RafuMetrics.hairline)
                )
                .fixedSize()
                .help(
                    refs.map { GitRefPill.kindTitle(for: $0.kind) + " " + $0.name }
                        .joined(separator: "\n"))
        } else {
            HStack(spacing: 3) {
                ForEach(refs.prefix(Self.visibleRefs), id: \.self) { ref in
                    GitRefPill(label: ref, laneColor: laneColor, density: density)
                }
                if refs.count > Self.visibleRefs {
                    Text("+\(refs.count - Self.visibleRefs)")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .fixedSize()
                }
            }
        }
    }
}

/// The lane column of one row: pass-through rails, the own lane's rails,
/// curved connectors into and out of the node, then the node. A merge node
/// is a ring with a transparent center; the checked-out commit gets an
/// outer accent ring. One `Canvas` per row, drawn only for visible rows.
private struct GitCommitLaneCanvas: View {
    @Environment(\.rafuTheme) private var theme
    let row: GraphRow?
    let laneColors: [Color]
    let isHead: Bool
    let showsRails: Bool

    private static let lineWidth: CGFloat = 1.5
    private static let nodeRadius: CGFloat = 3.5
    private static let headRingRadius: CGFloat = 5.5

    var body: some View {
        Canvas { context, size in
            guard let row else { return }
            let height = size.height
            let midY = height / 2
            let ownX = GitCommitGraphMetrics.laneX(row.laneIndex)

            if showsRails {
                for lane in row.passingLanes {
                    stroke(
                        &context, from: CGPoint(x: x(lane), y: 0),
                        to: CGPoint(x: x(lane), y: height), lane: lane)
                }
                if row.hasIncomingRail {
                    stroke(
                        &context, from: CGPoint(x: ownX, y: 0), to: CGPoint(x: ownX, y: midY),
                        lane: row.laneIndex)
                }
                if row.hasOutgoingRail {
                    stroke(
                        &context, from: CGPoint(x: ownX, y: midY),
                        to: CGPoint(x: ownX, y: height), lane: row.laneIndex)
                }
                for edge in row.incomingEdges {
                    curve(
                        &context, from: CGPoint(x: x(edge.fromLane), y: 0),
                        to: CGPoint(x: x(edge.toLane), y: midY), lane: edge.fromLane)
                }
                for edge in row.outgoingEdges {
                    if edge.fromLane == edge.toLane {
                        // The first parent is not loaded yet: a short dashed
                        // stub. "Load More" continues it.
                        var path = Path()
                        path.move(to: CGPoint(x: ownX, y: midY))
                        path.addLine(to: CGPoint(x: ownX, y: height))
                        context.stroke(
                            path, with: .color(color(edge.toLane).opacity(0.6)),
                            style: StrokeStyle(lineWidth: Self.lineWidth, dash: [2, 2]))
                    } else {
                        curve(
                            &context, from: CGPoint(x: x(edge.fromLane), y: midY),
                            to: CGPoint(x: x(edge.toLane), y: height), lane: edge.toLane)
                    }
                }
            }

            let nodeColor = color(row.laneIndex)
            let center = CGPoint(x: ownX, y: midY)
            let nodeRect = CGRect(
                x: center.x - Self.nodeRadius, y: center.y - Self.nodeRadius,
                width: Self.nodeRadius * 2, height: Self.nodeRadius * 2)
            if row.isMerge {
                // Punch the rails out of the ring's center so it reads as
                // hollow on any background.
                var clear = context
                clear.blendMode = .clear
                clear.fill(Path(ellipseIn: nodeRect), with: .color(.black))
                context.stroke(
                    Path(ellipseIn: nodeRect.insetBy(dx: 0.75, dy: 0.75)),
                    with: .color(nodeColor), lineWidth: Self.lineWidth)
            } else {
                context.fill(Path(ellipseIn: nodeRect), with: .color(nodeColor))
            }
            if isHead {
                let ring = CGRect(
                    x: center.x - Self.headRingRadius, y: center.y - Self.headRingRadius,
                    width: Self.headRingRadius * 2, height: Self.headRingRadius * 2)
                context.stroke(
                    Path(ellipseIn: ring), with: .color(theme.palette.accent),
                    lineWidth: Self.lineWidth)
            }
            if row.overflowLaneCount > 0 {
                context.draw(
                    Text("+\(row.overflowLaneCount)")
                        .font(.system(size: 8))
                        .foregroundStyle(theme.palette.textMuted),
                    at: CGPoint(x: size.width - 6, y: midY)
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func x(_ lane: Int) -> CGFloat { GitCommitGraphMetrics.laneX(lane) }

    private func color(_ lane: Int) -> Color { laneColors[lane % laneColors.count] }

    private func stroke(
        _ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, lane: Int
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color(lane)), lineWidth: Self.lineWidth)
    }

    /// A cubic connector that leaves `start` and reaches `end` vertically, so
    /// it joins the straight rails above and below without a kink.
    private func curve(
        _ context: inout GraphicsContext, from start: CGPoint, to end: CGPoint, lane: Int
    ) {
        let middle = (start.y + end.y) / 2
        var path = Path()
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x, y: middle),
            control2: CGPoint(x: end.x, y: middle))
        context.stroke(
            path, with: .color(color(lane)),
            style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
    }
}

/// Straight rails for the lanes that continue under an expanded commit, so
/// the graph stays continuous through the inline detail row.
private struct GitCommitRailColumn: View {
    let lanes: [Int]
    let laneColors: [Color]

    var body: some View {
        Canvas { context, size in
            for lane in lanes {
                let x = GitCommitGraphMetrics.laneX(lane)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    path, with: .color(laneColors[lane % laneColors.count]), lineWidth: 1.5)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The expanded commit (G11) directly under its row: a meta line (short hash
/// with Copy, author, date), the message body and line totals once loaded,
/// then one 22 pt row per changed file — file icon, name, dimmed folder,
/// trailing status letter. Clicking a file opens its diff. The lanes that
/// continue below the commit run through the left column.
private struct GitCommitInlineDetail: View {
    @Environment(\.rafuTheme) private var theme
    let commit: GitCommitSummary
    let railLanes: [Int]
    let laneColors: [Color]
    let laneCanvasWidth: CGFloat
    let detail: GitCommitDetailStore.State?
    let changes: [GitCommitFileChange]
    let isLoading: Bool
    let openDiff: (GitCommitFileChange) -> Void

    @State private var didCopy = false

    /// Bounds the non-lazy file list for very large commits.
    private static let maximumFileRows = 200
    private static let maximumBodyLines = 8

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Color.clear.frame(width: laneCanvasWidth)
            VStack(alignment: .leading, spacing: 4) {
                metaLine
                if case .loaded(let loaded) = detail {
                    if !loaded.displayBody.isEmpty {
                        Text(loaded.displayBody)
                            .font(.system(size: 11.5))
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(Self.maximumBodyLines)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    GitCommitStatsText(detail: loaded)
                        .font(.system(size: 11))
                }
                files
            }
            .padding(.vertical, 4)
        }
        .background(alignment: .leading) {
            GitCommitRailColumn(lanes: railLanes, laneColors: laneColors)
                .frame(width: laneCanvasWidth)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text(commit.shortID)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(theme.palette.textPrimary)
                .textSelection(.enabled)
                .accessibilityLabel("Commit hash")
                .accessibilityValue(commit.id)
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
            .buttonStyle(RafuIconButtonStyle(size: 18, iconSize: 10))
            .help("Copy Full Hash")
            Text(
                "\(commit.authorName) · \(commit.authoredAt.formatted(date: .abbreviated, time: .shortened))"
            )
            .font(.system(size: 11))
            .foregroundStyle(theme.palette.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help("\(commit.authorName) <\(commit.authorEmail)>")
        }
    }

    @ViewBuilder
    private var files: some View {
        if isLoading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Loading changed files")
        } else if changes.isEmpty {
            Text("This commit has no file changes.")
                .font(.system(size: 11.5))
                .foregroundStyle(theme.palette.textSecondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
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
                FileIconView(icon: FileIconProvider.fileIcon(named: parts.name), size: 12)
                    .frame(width: 14)
                    .accessibilityHidden(true)
                Text(parts.name)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
                if let folder = parts.folder {
                    Text(folder)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
                GitStatusLetterBadge(kind: change.kind)
            }
            .frame(height: GitCommitGraphMetrics.rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Open diff for \(change.path)")
        .accessibilityLabel(
            "\(change.path), \(GitStatusPresentation.title(for: change.kind)). Opens the diff.")
    }
}
