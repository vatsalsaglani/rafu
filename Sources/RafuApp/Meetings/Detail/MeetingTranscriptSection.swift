import AppKit
import RafuCore
import SwiftUI

/// The pinned bar over the transcript: "TRANSCRIPT", the search field, the
/// match count with up and down, and the repeated-lines menu.
struct MeetingTranscriptBar: View {
    @Bindable var model: MeetingDetailModel
    /// Goes up when Command-F asks for the search field.
    let focusRequest: Int

    @Environment(\.rafuTheme) private var theme
    @FocusState private var searchFocused: Bool

    private struct SearchKey: Equatable {
        var query: String
        var showsRepeated: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            HStack(spacing: RafuMetrics.space2) {
                Text("TRANSCRIPT")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: RafuMetrics.space2)
                searchField
                if !model.searchQuery.isEmpty {
                    matchControls
                }
                repeatedMenu
            }
            if model.searchHitLimit, !model.searchQuery.isEmpty {
                Text(MeetingDetailPresentation.searchLimitNote)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
            }
        }
        .frame(maxWidth: MeetingNotesColumn.textColumnWidth, alignment: .leading)
        .padding(.horizontal, RafuMetrics.space5)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rafuDeckFill(theme.palette.editorBackground, .deck)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.palette.borderSubtle).frame(height: 1)
        }
        .onChange(of: focusRequest) { searchFocused = true }
        .task(
            id: SearchKey(
                query: model.searchQuery, showsRepeated: model.showsRepeated)
        ) {
            // A short pause, so the search runs once the user stops typing.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            await model.runSearch()
        }
    }

    private var searchField: some View {
        HStack(spacing: RafuMetrics.space1) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            TextField("Search the transcript", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .onSubmit { model.nextMatch() }
                .onKeyPress(.escape) {
                    guard !model.searchQuery.isEmpty else { return .ignored }
                    model.searchQuery = ""
                    return .handled
                }
                .accessibilityLabel("Search the transcript")
        }
        .rafuField(isFocused: searchFocused)
        .frame(maxWidth: 220)
    }

    private var matchControls: some View {
        HStack(spacing: 2) {
            Text(
                MeetingDetailPresentation.searchCountText(
                    current: model.searchIndex, total: model.searchMatches.count)
            )
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(theme.palette.textMuted)
            .fixedSize()
            Button("Previous Match", systemImage: "chevron.up") { model.previousMatch() }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .labelStyle(.iconOnly)
                .disabled(model.searchMatches.isEmpty)
                .help("Previous match")
            Button("Next Match", systemImage: "chevron.down") { model.nextMatch() }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .labelStyle(.iconOnly)
                .disabled(model.searchMatches.isEmpty)
                .help("Next match (Return)")
        }
    }

    @ViewBuilder
    private var repeatedMenu: some View {
        if let count = model.overview?.repeatedCount, count > 0 {
            Menu {
                Toggle(
                    MeetingDetailPresentation.repeatedToggleTitle(count: count),
                    isOn: $model.showsRepeated)
            } label: {
                Label("Transcript Options", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.button)
            .buttonStyle(RafuIconButtonStyle(isActive: model.showsRepeated, size: 22, iconSize: 11))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(MeetingDetailPresentation.repeatedHelp)
            .accessibilityLabel("Transcript options")
        }
    }
}

/// The transcript rows: one group for each run of one speaker, the "Load
/// more" button, and the empty text.
struct MeetingTranscriptSection: View {
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let groups = model.groups
        let order = model.speakerOrder
        let matches = Set(model.searchMatches)
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            if model.isReady, groups.isEmpty, !model.hasMoreTurns {
                Text("This meeting has no text.")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            ForEach(groups) { group in
                MeetingTurnGroupView(
                    model: model, group: group,
                    shape: MeetingDetailPresentation.shape(for: group.speaker, in: order),
                    name: model.displayName(for: group.speaker),
                    matches: matches
                )
                .id(group.id)
            }
            if model.hasMoreTurns {
                Button("Load More") { Task { await model.loadMoreTurns() } }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, RafuMetrics.space4)
    }
}

/// One group: the speaker row (shape, name, start time) and the lines.
/// The speaker row opens the rename popover.
struct MeetingTurnGroupView: View {
    let model: MeetingDetailModel
    let group: MeetingTurnGroup
    let shape: String
    let name: String
    let matches: Set<MeetingTurnID>

    @Environment(\.rafuTheme) private var theme
    @State private var isRenaming = false

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                Button {
                    isRenaming = true
                } label: {
                    Text("\(shape) \(name)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                }
                .buttonStyle(.plain)
                .help("Rename \(name)")
                .accessibilityLabel("\(name). Rename")
                .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
                    MeetingSpeakerRenamePopover(model: model, label: group.speaker) {
                        isRenaming = false
                    }
                }
                Text(MeetingsFormat.clock(group.start))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityLabel(MeetingsFormat.spokenDuration(group.start))
            }
            .padding(.leading, MeetingTurnLine.gutterWidth)
            ForEach(group.turns) { turn in
                MeetingTurnLine(
                    turn: turn,
                    query: matches.contains(turn.id) ? model.searchQuery : nil,
                    isMarked: model.highlightedTurn == turn.id
                        || model.currentSearchMatch == turn.id,
                    onRename: { isRenaming = true })
            }
        }
    }
}

/// One line: the time in the left margin on hover, the text (14 pt, line
/// spacing 4), the "Repeated" chip, the search marks, and the mark of the
/// current line (a fill and a 2 pt accent bar).
private struct MeetingTurnLine: View {
    let turn: MeetingTurn
    /// The search query when this line matches it.
    let query: String?
    let isMarked: Bool
    let onRename: () -> Void

    static let gutterWidth: CGFloat = 44

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(MeetingsFormat.clock(turn.start))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
                .opacity(isHovering || isMarked ? 1 : 0)
                .frame(width: Self.gutterWidth, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                Text(attributedText)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(
                        turn.isEcho ? theme.palette.textSecondary : theme.palette.textPrimary
                    )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if turn.isEcho {
                    RafuChip(text: "Repeated")
                        .help(MeetingDetailPresentation.repeatedHelp)
                }
            }
        }
        .padding(.vertical, 2)
        .background(alignment: .leading) {
            if isMarked {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseSelection)
                        .fill(theme.palette.lineHighlight)
                    Rectangle().fill(theme.palette.accent).frame(width: 2)
                }
                .accessibilityHidden(true)
            }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(turn.text, forType: .string)
            }
            Button("Rename Speaker…", action: onRename)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(MeetingsFormat.spokenDuration(turn.start)). \(turn.isEcho ? "Repeated. " : "")\(turn.text)"
        )
    }

    /// The text with each match of the query on the soft accent.
    private var attributedText: AttributedString {
        var result = AttributedString(turn.text)
        guard let query else { return result }
        for range in MeetingDetailPresentation.matchRanges(of: query, in: turn.text) {
            guard let attributed = Range(range, in: result) else { continue }
            result[attributed].backgroundColor = theme.palette.accentSoft
        }
        return result
    }
}
