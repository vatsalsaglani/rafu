import AppKit
import SwiftUI

/// The side-by-side diff body shown by a Git diff auxiliary tab. The tab item
/// itself stays on the owning editor group's shelf (`EditorCanvasView`).
struct GitSideBySideDiffView: View {
    @Environment(\.rafuTheme) private var theme
    let openDiff: GitOpenDiff
    @Bindable var session: WorkspaceSession

    /// Cached per-side token spans for `openDiff`, computed off-main by
    /// `DiffSyntaxHighlighter` and re-run only when `openDiff.id` changes
    /// (`.task(id:)` below) — NOT on theme change, since spans carry only a
    /// `themeKey` and `GitDiffCell` resolves the actual color at render
    /// time. `nil` before the first computation and for a diff with no
    /// eligible grammar; `GitDiffCell` renders plainly in both cases.
    @State private var highlights: DiffSyntaxHighlighter.DiffHighlights?
    /// Row → per-side line-index lookup for `highlights`, precomputed
    /// alongside it so no row-position scanning happens in `body`.
    @State private var lineIndexMap = DiffLineIndexMap(rows: [])

    var body: some View {
        VStack(spacing: 0) {
            diffHeader
            Divider().overlay(theme.palette.borderSubtle)

            if openDiff.diff.isBinary {
                ContentUnavailableView(
                    "Binary file",
                    systemImage: "doc.zipper",
                    description: Text(
                        "Rafu cannot render a textual side-by-side diff for this file.")
                )
            } else if openDiff.diff.hunks.isEmpty {
                ContentUnavailableView(
                    "No textual changes",
                    systemImage: "checkmark.circle",
                    description: Text("Git reported no line changes for this selection.")
                )
            } else {
                diffTable
            }
        }
        .background(theme.palette.editorBackground)
        .task(id: openDiff.id) {
            // Guard the assignment against a superseded task: `.task(id:)`
            // cancels but does not await the prior task, and a parse that
            // finished before cancellation would otherwise briefly overwrite
            // the NEW diff's spans with the previous diff's. The check also
            // keeps `lineIndexMap`/`highlights` mutually consistent for the
            // same diff.
            let map = DiffLineIndexMap(rows: openDiff.diff.rows)
            let result = await DiffSyntaxHighlighter.highlights(for: openDiff.diff)
            if Task.isCancelled { return }
            lineIndexMap = map
            highlights = result
        }
    }

    /// New-side-only hover entry point (Part B, product decision: the old
    /// side and non-working-tree diffs never hover). Passed to
    /// `GitSideBySideDiffRow` only when `openDiff.scope == .workingTree`
    /// (view-level gating), and `session.diffHoverInfo` re-checks the same
    /// conditions independently, so a future call site can't accidentally
    /// bypass either gate.
    private func requestHover(line: Int, utf16Column: Int) async -> EditorHoverInfo? {
        await session.diffHoverInfo(path: openDiff.diff.path, line: line, utf16Column: utf16Column)
    }

    /// Builds one diff row, indexing `highlights`/`lineIndexMap` for its
    /// spans. Extracted out of `diffTable`'s `ForEach` closure (rather than
    /// inlined) purely to keep the surrounding `ScrollView`/`LazyVStack`
    /// result-builder chain within the type checker's inference budget —
    /// no behavior difference, still a pure index into the precomputed
    /// cache, no parse work.
    private func diffRowView(for row: GitDiffRow) -> some View {
        var hoverHandler: ((Int, Int) async -> EditorHoverInfo?)?
        if openDiff.scope == .workingTree {
            hoverHandler = requestHover
        }
        return GitSideBySideDiffRow(
            row: row,
            oldSpans: highlights.flatMap { lineIndexMap.oldSpans(for: row, in: $0) },
            newSpans: highlights.flatMap { lineIndexMap.newSpans(for: row, in: $0) },
            hover: hoverHandler
        )
    }

    /// One header (G8): path breadcrumb, the real comparison, and "+n −n".
    /// The tab already carries the file title, so it is not repeated here.
    private var diffHeader: some View {
        let components = GitDiffHeaderPresentation.breadcrumb(for: openDiff.diff.path)
        let fileName = (openDiff.diff.path as NSString).lastPathComponent
        return RafuCardHeaderRow {
            HStack(spacing: 6) {
                FileIconView(icon: FileIconProvider.fileIcon(named: fileName), size: 12)
                    .accessibilityHidden(true)
                ForEach(Array(components.enumerated()), id: \.offset) { item in
                    if item.offset > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(theme.palette.textMuted)
                            .accessibilityHidden(true)
                    }
                    let isLast = item.offset == components.count - 1
                    Text(item.element)
                        .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                        .foregroundStyle(
                            isLast ? theme.palette.textPrimary : theme.palette.textSecondary
                        )
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("·")
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
                Text(GitDiffHeaderPresentation.comparisonLabel(for: openDiff.scope))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(openDiff.diff.path), \(GitDiffHeaderPresentation.comparisonLabel(for: openDiff.scope))"
            )
        } trailing: {
            diffStats
        }
    }

    private var diffStats: some View {
        let counts = GitDiffHeaderPresentation.lineCounts(for: openDiff.diff)
        return HStack(spacing: 6) {
            RafuChip(
                text: "+\(counts.added)", foreground: theme.palette.gitAdded, monospacedDigit: true)
            RafuChip(
                text: "−\(counts.deleted)", foreground: theme.palette.gitDeleted,
                monospacedDigit: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(counts.added) lines added, \(counts.deleted) lines removed")
    }

    private var diffTable: some View {
        // A both-axes ScrollView centers content smaller than the viewport;
        // stretch the table to at least the viewport size, pinned top-leading.
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(openDiff.diff.hunks) { hunk in
                            hunkHeader(hunk)
                            ForEach(hunk.rows) { row in
                                diffRowView(for: row)
                            }
                        }
                    } header: {
                        HStack(spacing: 0) {
                            diffColumnTitle("Before", symbol: "minus")
                            Divider().overlay(theme.palette.borderSubtle)
                            diffColumnTitle("After", symbol: "plus")
                        }
                        .frame(height: 28)
                        .background(theme.palette.tabBarBackground)
                    }
                }
                .frame(
                    minWidth: max(900, viewport.size.width),
                    minHeight: viewport.size.height,
                    alignment: .topLeading
                )
            }
            .scrollIndicators(.visible)
        }
    }

    private func hunkHeader(_ hunk: GitDiffHunk) -> some View {
        HStack(spacing: 8) {
            // G8: no decorative "···" — the diff model has a fixed context
            // size, so there is no real "Show More Context" action to offer.
            Text(hunk.header)
                .font(.caption.monospaced())
                .foregroundStyle(theme.palette.textSecondary)
            Spacer(minLength: 12)
            if let action = hunkAction {
                Button(action.title) {
                    perform(action, on: hunk)
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .disabled(session.isGitBusy || session.isGitHunkActionBusy)
                .help(action.help)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.horizontal, 12)
        .background(theme.palette.selection.opacity(0.45))
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        .overlay(alignment: .bottom) { Divider().overlay(theme.palette.borderSubtle) }
        .contextMenu {
            if let action = hunkAction {
                Button(action.title, systemImage: action.systemImage) {
                    perform(action, on: hunk)
                }
                .disabled(session.isGitBusy || session.isGitHunkActionBusy)
            }
        }
    }

    private var hunkAction: HunkAction? {
        guard
            session.gitSnapshot?.changes.first(where: { $0.path == openDiff.diff.path })?.kind
                == .modified
        else { return nil }
        switch openDiff.scope {
        case .workingTree: return .stage
        case .staged: return .unstage
        case .commit, .between: return nil
        }
    }

    private func perform(_ action: HunkAction, on hunk: GitDiffHunk) {
        Task {
            switch action {
            case .stage: await session.stageHunk(hunk)
            case .unstage: await session.unstageHunk(hunk)
            }
        }
    }

    private enum HunkAction: Equatable {
        case stage
        case unstage

        var title: String { self == .stage ? "Stage Hunk" : "Unstage Hunk" }
        var systemImage: String { self == .stage ? "plus.circle" : "minus.circle" }
        var help: String {
            self == .stage
                ? "Stage only this hunk in the Git index"
                : "Remove only this hunk from the Git index"
        }
    }

    private func diffColumnTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
    }
}

private struct GitSideBySideDiffRow: View {
    @Environment(\.rafuTheme) private var theme
    let row: GitDiffRow
    var oldSpans: [SyntaxSpan]?
    var newSpans: [SyntaxSpan]?
    /// New-side-only hover request, `nil` for a history/commit-scoped diff
    /// (`GitSideBySideDiffView` never passes one). Threaded straight through
    /// to the new-side `GitDiffCell`; the old-side cell never receives it,
    /// so it structurally cannot hover.
    var hover: ((Int, Int) async -> EditorHoverInfo?)?

    var body: some View {
        let spans =
            row.kind == .modification
            ? IntralineDiff.changedSpans(
                old: row.oldLine?.content ?? "",
                new: row.newLine?.content ?? ""
            )
            : nil
        HStack(spacing: 0) {
            GitDiffCell(
                line: row.oldLine, side: .old, rowKind: row.kind,
                changedSpan: spans?.old, syntaxSpans: oldSpans
            )
            Divider().overlay(theme.palette.borderSubtle.opacity(0.6))
            GitDiffCell(
                line: row.newLine, side: .new, rowKind: row.kind,
                changedSpan: spans?.new, syntaxSpans: newSpans, hover: hover
            )
        }
        .frame(minHeight: 21)
    }
}

private struct GitDiffCell: View {
    enum Side { case old, new }

    @Environment(\.rafuTheme) private var theme
    let line: GitDiffLine?
    let side: Side
    let rowKind: GitDiffRowKind
    var changedSpan: Range<Int>?
    /// Precomputed token spans for this line (UTF-16, line-relative), or
    /// `nil` for plain rendering — no grammar, an unopened diff cache, or a
    /// side over `DiffSyntaxHighlighter`'s highlighted-length cap. No parse
    /// work happens here; this view only indexes into the cache.
    var syntaxSpans: [SyntaxSpan]?
    /// New-side-only hover request (`(line, utf16Column) async ->
    /// EditorHoverInfo?`). `nil` for the old-side cell always, and for the
    /// new-side cell of a history/commit-scoped diff — the product decision
    /// that only the new side of a working-tree diff ever hovers.
    var hover: ((Int, Int) async -> EditorHoverInfo?)?

    @State private var hoverDebounceTask: Task<Void, Never>?
    @State private var hoverInfo: EditorHoverInfo?
    @State private var isHoverPresented = false

    /// UTF-16-column advance for `.system(size: 12, design: .monospaced)` —
    /// the diff cell's fixed content font — computed once via `NSFont`
    /// metrics rather than per hover event. Pragmatic v1 column estimation
    /// (phase brief B3): `column ≈ pointerX / monospaceAdvance`, clamped to
    /// the line's UTF-16 length. Emoji/wide-glyph drift is accepted —
    /// `IdentifierUnderCaret` snaps to the nearest word, and a miss shows no
    /// card rather than a wrong one.
    private static let monospaceAdvance: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        return ("0" as NSString).size(withAttributes: [.font: font]).width
    }()

    /// Debounce before a stable hover resolves — matches the editor's own
    /// hover delay (`RafuTextView.hoverDelay`) so both surfaces feel
    /// consistent.
    private static let hoverDelay: Duration = EditorHoverTiming.documentationDelay

    var body: some View {
        HStack(spacing: 0) {
            Text(line.map { String($0.number) } ?? "")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(gutterColor)
                .frame(width: 42, alignment: .trailing)
                .padding(.trailing, 6)
                .frame(maxHeight: .infinity)
                .background(gutterBackground)
            Text(marker)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(markerColor)
                .frame(width: 16)
            Text(attributedContent)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let point):
                        scheduleHover(at: point.x)
                    case .ended:
                        cancelHover()
                    }
                }
                .popover(isPresented: $isHoverPresented, arrowEdge: .bottom) {
                    if let hoverInfo {
                        EditorHoverTooltipView(info: hoverInfo, theme: theme)
                    }
                }
        }
        .frame(maxWidth: .infinity, minHeight: 21, alignment: .leading)
        .background(backgroundColor)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .onDisappear(perform: cancelHover)
    }

    /// Schedules a debounced hover resolve at pointer x-offset `x` within
    /// the content `Text`'s local coordinate space. A no-op for the old
    /// side, a row without a `newLine`, a diff with no `hover` handler
    /// (history/commit scope), or a column with no identifier under it —
    /// every one of those cases must never show a card (AGENTS: state is
    /// never color-only, and old-side/history hover is an explicit
    /// non-goal). Cancels any in-flight resolve first so a fast pointer
    /// sweep never stacks requests or shows a stale card.
    private func scheduleHover(at x: CGFloat) {
        hoverDebounceTask?.cancel()
        guard side == .new, let line, let hover else {
            cancelHover()
            return
        }
        let column = Self.column(forX: x, in: line.content)
        guard IdentifierUnderCaret.word(in: line.content, at: column) != nil else {
            cancelHover()
            return
        }
        let requestedLine = line.number
        hoverDebounceTask = Task {
            try? await Task.sleep(for: Self.hoverDelay)
            if Task.isCancelled { return }
            let info = await hover(requestedLine, column)
            if Task.isCancelled { return }
            hoverInfo = info
            isHoverPresented = info != nil
        }
    }

    /// Cancels any in-flight/scheduled resolve and dismisses the card —
    /// pointer exit, row teardown, and a declined hover attempt all funnel
    /// through here so hover never lingers or blocks scrolling (AGENTS).
    private func cancelHover() {
        hoverDebounceTask?.cancel()
        hoverDebounceTask = nil
        isHoverPresented = false
    }

    private static func column(forX x: CGFloat, in content: String) -> Int {
        let length = (content as NSString).length
        guard monospaceAdvance > 0 else { return 0 }
        let raw = Int((x / monospaceAdvance).rounded())
        return max(0, min(raw, length))
    }

    private var attributedContent: AttributedString {
        guard let line else { return AttributedString("") }
        var text = AttributedString(line.content)
        text.foregroundColor = theme.palette.textPrimary

        if let syntaxSpans {
            let contentLength = (line.content as NSString).length
            for span in syntaxSpans {
                guard span.range.location >= 0, span.range.length > 0,
                    span.range.location + span.range.length <= contentLength,
                    let hex = theme.syntax[span.themeKey]?.color,
                    let range = Range<AttributedString.Index>(span.range, in: text)
                else { continue }
                text[range].foregroundColor = Color(rafuHex: hex)
            }
        }

        if let changedSpan, isChanged, !changedSpan.isEmpty,
            changedSpan.upperBound <= line.content.count
        {
            let start = text.index(text.startIndex, offsetByCharacters: changedSpan.lowerBound)
            let end = text.index(text.startIndex, offsetByCharacters: changedSpan.upperBound)
            text[start..<end].backgroundColor =
                side == .old
                ? theme.palette.diffRemovedWordBackground
                : theme.palette.diffAddedWordBackground
        }
        return text
    }

    private var isChanged: Bool {
        side == .old
            ? rowKind == .deletion || rowKind == .modification
            : rowKind == .addition || rowKind == .modification
    }

    private var marker: String {
        guard line != nil, isChanged else { return "" }
        return side == .old ? "−" : "+"
    }

    private var markerColor: Color {
        side == .old ? theme.palette.diffRemovedGutter : theme.palette.diffAddedGutter
    }

    private var gutterColor: Color {
        guard line != nil else { return theme.palette.gutterForeground.opacity(0.4) }
        return isChanged ? markerColor : theme.palette.gutterForeground
    }

    private var gutterBackground: Color {
        guard line != nil, isChanged else { return .clear }
        return
            (side == .old
            ? theme.palette.diffRemovedBackground
            : theme.palette.diffAddedBackground)
            .opacity(0.8)
    }

    private var backgroundColor: Color {
        guard line != nil else {
            return theme.palette.appBackground.opacity(0.35)
        }
        guard isChanged else { return .clear }
        return side == .old
            ? theme.palette.diffRemovedBackground
            : theme.palette.diffAddedBackground
    }

    private var accessibilityText: String {
        guard let line else { return "No corresponding line" }
        let change = marker == "+" ? "Added" : marker == "−" ? "Removed" : "Context"
        return "\(change), line \(line.number): \(line.content)"
    }
}
