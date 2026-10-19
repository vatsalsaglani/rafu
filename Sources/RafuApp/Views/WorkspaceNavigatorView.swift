import AppKit
import SwiftUI

/// The left sidebar's content: whichever section `session.navigatorMode`
/// selects. Files keeps its own tree view (`WorkspaceSidebarView`); this
/// hosts the other four sections, each a peer in the same pane.
struct WorkspaceSidebarPanelView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        panelContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // One sidebar tone for every section, so switching the rail
            // selection never changes the pane's own background — only
            // `WorkspaceSidebarView` painted this before; Search, Source
            // Control, Terminals, and History now share this same pane.
            .background(theme.palette.sidebarBackground)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch session.navigatorMode {
        case .files:
            WorkspaceSidebarView(session: session)
        case .search:
            WorkspaceSearchNavigatorView(session: session)
        case .sourceControl:
            SourceControlPanelView(session: session)
        case .terminals:
            WorkspaceTerminalsPanelView(session: session)
        case .history:
            AgentHistoryPanelView(session: session)
        }
    }
}

/// The one always-visible left icon rail (user decision 2026-10-19): every
/// navigator mode (Files, Search, Source Control, Terminals, History) lives
/// here, selecting which section the left sidebar shows. This supersedes
/// ADR 0003's right-rail mode placement — there is no right rail and no
/// right utility panel anymore. The rail itself is never gated on
/// `isSidebarCollapsed`; only the sidebar content below it is.
struct WorkspaceActivityRail: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            ForEach(WorkspaceNavigatorMode.allCases, id: \.self) { mode in
                railButton(mode)
            }
            Spacer()
        }
        // The rail starts below the titlebar row (`WindowTitlebarRow`) so
        // the traffic lights and sidebar toggle stay clear above it.
        .padding(.top, 8)
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .background(WindowDragHandle())
        .background(theme.palette.appBackground)
    }

    private func railButton(_ mode: WorkspaceNavigatorMode) -> some View {
        let hasWorkspace = session.descriptor != nil
        // Files needs no open workspace — it shows "Open a folder to begin"
        // itself — so it alone stays enabled and can show as selected
        // without one; the other four modes need a workspace for both.
        let isEnabled = mode == .files || hasWorkspace
        let isActive = isEnabled && session.navigatorMode == mode && !session.isSidebarCollapsed
        // Only computed for `.terminals` — deriving it for every rail
        // button would needlessly walk `terminal.sessions` on every render.
        let attentionCount =
            mode == .terminals
            ? TerminalsPanelModel.attentionCount(sessions: session.terminal.sessions)
            : 0
        let button =
            Button(mode.title, systemImage: mode.symbolName) {
                session.selectNavigatorRailIcon(mode)
            }
            .buttonStyle(
                RafuRailButtonStyle(
                    isSelected: isActive,
                    deckFacingEdge: .trailing,
                    tooltip: isEnabled ? mode.title : "\(mode.title) — open a folder first",
                    badge: mode == .terminals && attentionCount > 0 ? attentionCount : nil
                )
            )
            .disabled(!isEnabled)
        return Group {
            if mode == .terminals, attentionCount > 0 {
                button.accessibilityValue("\(attentionCount) needing attention")
            } else {
                button
            }
        }
    }
}

struct WorkspaceSearchNavigatorView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        VStack(spacing: 0) {
            RafuUtilityPanelHeader(
                icon: WorkspaceNavigatorMode.search.symbolName,
                title: "Search",
                closeAccessibilityLabel: "Close Search",
                onClose: { session.isSidebarCollapsed = true }
            ) {
                EmptyView()
            }
            WorkspaceSearchContent(session: session, search: session.workspaceSearch)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

nonisolated enum SearchFileFilterDisclosure {
    static func requiresExpandedFilters(includePattern: String, excludePattern: String) -> Bool {
        !includePattern.isEmpty || !excludePattern.isEmpty
    }
}

private struct WorkspaceSearchContent: View {
    @Bindable var session: WorkspaceSession
    @Bindable var search: WorkspaceSearchModel
    @Environment(\.rafuTheme) private var theme
    @FocusState private var isQueryFocused: Bool
    @FocusState private var isIncludeFocused: Bool
    @FocusState private var isExcludeFocused: Bool
    @FocusState private var isReplaceFocused: Bool
    @State private var isFileFiltersExpanded = false
    @State private var isApplyConfirmationPresented = false

    var body: some View {
        VStack(spacing: 0) {
            searchControls
            Divider().overlay(theme.palette.borderSubtle)
            searchResults
        }
        .defaultFocus($isQueryFocused, true)
        .alert("Workspace Search", isPresented: errorBinding) {
            Button("OK", role: .cancel) { search.clearError() }
        } message: {
            Text(search.errorMessage ?? "Search failed.")
        }
        .confirmationDialog(
            "Apply \(search.replacementPreview?.replacementCount ?? 0) replacements?",
            isPresented: $isApplyConfirmationPresented
        ) {
            Button("Apply Replacements") { Task { await session.applyWorkspaceReplacement() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Files changed since this preview was created will not be overwritten.")
        }
    }

    private var searchControls: some View {
        VStack(spacing: 7) {
            HStack(spacing: 6) {
                TextField("Search workspace", text: $search.query)
                    .textFieldStyle(.plain)
                    .rafuField(isFocused: isQueryFocused)
                    .focused($isQueryFocused)
                    .onSubmit(performSearch)
                Menu {
                    ForEach(search.recentQueries, id: \.self) { recentQuery in
                        Button(recentQuery) {
                            search.query = recentQuery
                            performSearch()
                        }
                    }
                } label: {
                    Label("Recent Searches", systemImage: "clock")
                }
                .menuStyle(.button)
                .buttonStyle(RafuIconButtonStyle(size: 24))
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(search.recentQueries.isEmpty)
                .help("Recent Searches")
                Button("Search", systemImage: "magnifyingglass", action: performSearch)
                    .buttonStyle(RafuIconButtonStyle(size: 24))
                    .disabled(search.query.isEmpty)
                    .help("Search")
                Button(
                    search.isReplacePresented ? "Hide Replace" : "Show Replace",
                    systemImage: search.isReplacePresented ? "chevron.down" : "chevron.right"
                ) { search.isReplacePresented.toggle() }
                .buttonStyle(RafuIconButtonStyle(isActive: search.isReplacePresented, size: 24))
                .help(search.isReplacePresented ? "Hide Replace" : "Show Replace")
            }
            DisclosureGroup("File filters", isExpanded: fileFiltersExpandedBinding) {
                HStack(spacing: 6) {
                    TextField("files to include", text: $search.includePattern)
                        .textFieldStyle(.plain)
                        .rafuField(isFocused: isIncludeFocused)
                        .focused($isIncludeFocused)
                        .controlSize(.small)
                        .onSubmit(performSearch)
                        .help("Include only matching files, e.g. *.swift, Sources/**")
                    TextField("files to exclude", text: $search.excludePattern)
                        .textFieldStyle(.plain)
                        .rafuField(isFocused: isExcludeFocused)
                        .focused($isExcludeFocused)
                        .controlSize(.small)
                        .onSubmit(performSearch)
                        .help("Skip matching files and folders, e.g. *.md, Tests/**")
                }
                .padding(.top, RafuMetrics.space1)
            }
            .font(.caption)
            .foregroundStyle(theme.palette.textSecondary)
            HStack(spacing: 4) {
                RafuOptionToggle(
                    glyph: .text("Aa"), label: "Match Case",
                    isOn: optionBinding(.caseSensitive))
                RafuOptionToggle(
                    glyph: .text("ab", underlined: true), label: "Whole Word",
                    isOn: optionBinding(.wholeWord))
                RafuOptionToggle(
                    glyph: .text(".*", monospaced: true), label: "Regular Expression",
                    isOn: optionBinding(.regularExpression))
                Spacer()
                if search.isSearching { ProgressView().controlSize(.small) }
                if let result = search.result {
                    Text("\(result.totalMatchCount) matches")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            if search.isReplacePresented {
                HStack(spacing: 6) {
                    TextField("Replace", text: $search.replacement)
                        .textFieldStyle(.plain)
                        .rafuField(isFocused: isReplaceFocused)
                        .focused($isReplaceFocused)
                        .onSubmit(previewReplacements)
                    Button("Preview", action: previewReplacements)
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .disabled(search.query.isEmpty)
                    if let preview = search.replacementPreview {
                        Button("Apply \(preview.replacementCount)") {
                            isApplyConfirmationPresented = true
                        }
                        .buttonStyle(RafuProminentButtonStyle(compact: true))
                        .disabled(preview.replacementCount == 0 || search.isApplying)
                    }
                }
            }
        }
        .padding(RafuMetrics.utilityBodyInset)
    }

    @ViewBuilder
    private var searchResults: some View {
        if let preview = search.replacementPreview {
            List {
                ForEach(preview.files) { file in
                    Section {
                        ForEach(file.edits) { edit in
                            Button {
                                session.openSearchLocation(fileURL: file.fileURL, range: edit.range)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Line \(edit.line)").font(.caption2)
                                        .foregroundStyle(theme.palette.textSecondary)
                                    Text(edit.originalPreview).font(.caption.monospaced())
                                        .foregroundStyle(theme.palette.error)
                                        .strikethrough(
                                            true, color: theme.palette.error.opacity(0.5)
                                        )
                                        .lineLimit(1)
                                    Text(edit.replacementPreview).font(.caption.monospaced())
                                        .foregroundStyle(theme.palette.success).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        fileHeader(
                            relativePath: file.relativePath, count: file.edits.count,
                            noun: "replacements")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else if let result = search.result, !result.groups.isEmpty {
            List {
                ForEach(result.groups) { group in
                    Section {
                        ForEach(group.matches) { match in
                            Button {
                                session.openSearchMatch(group, match: match)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text("\(match.line)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(theme.palette.textMuted)
                                        .frame(width: 32, alignment: .trailing)
                                    Text(snippetText(for: match))
                                        .font(.caption.monospaced())
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .help("Line \(match.line), column \(match.column)")
                            .accessibilityLabel(
                                "Line \(match.line), column \(match.column): \(match.preview)")
                        }
                    } header: {
                        fileHeader(
                            relativePath: group.relativePath, count: group.matches.count,
                            noun: "matches")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else if search.isSearching {
            ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            RafuPanelEmptyState(
                icon: "magnifyingglass",
                title: "Search Workspace",
                message: "Find or replace text across the open folder."
            )
        }
    }

    private var fileFiltersExpandedBinding: Binding<Bool> {
        Binding(
            get: {
                isFileFiltersExpanded
                    || SearchFileFilterDisclosure.requiresExpandedFilters(
                        includePattern: search.includePattern,
                        excludePattern: search.excludePattern
                    )
            },
            set: { requestedValue in
                guard
                    !SearchFileFilterDisclosure.requiresExpandedFilters(
                        includePattern: search.includePattern,
                        excludePattern: search.excludePattern
                    )
                else {
                    isFileFiltersExpanded = true
                    return
                }
                isFileFiltersExpanded = requestedValue
            }
        )
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { search.errorMessage != nil },
            set: { if !$0 { search.clearError() } }
        )
    }

    /// Every folder of the workspace, primary first; results are labelled
    /// by folder when there is more than one.
    private func performSearch() {
        guard session.rootURL != nil else { return }
        search.search(in: session.workspaceSearchRoots)
    }

    private func previewReplacements() {
        guard session.rootURL != nil else { return }
        search.previewReplacements(in: session.workspaceSearchRoots)
    }

    private func optionBinding(_ option: TextSearchOptions) -> Binding<Bool> {
        Binding(
            get: { search.options.contains(option) },
            set: { isOn in
                if isOn {
                    search.options.insert(option)
                } else {
                    search.options.remove(option)
                }
            }
        )
    }

    /// One result line: the match in the find-match colour, bold, with a little
    /// context on each side. The line is cut around the match, not at the start.
    private func snippetText(for match: WorkspaceSearchMatch) -> AttributedString {
        let snippet = SearchResultSnippet.make(
            preview: match.preview, column: match.column, matchLength: match.range.length)
        var before = AttributedString(snippet.prefix)
        before.foregroundColor = theme.palette.textSecondary
        var hit = AttributedString(snippet.match)
        hit.font = Font.caption.monospaced().bold()
        hit.foregroundColor = theme.palette.textPrimary
        hit.backgroundColor = Color(nsColor: theme.editorFindMatchBackgroundColor)
        var after = AttributedString(snippet.suffix)
        after.foregroundColor = theme.palette.textSecondary
        return before + hit + after
    }

    /// File header: icon, name, folder (secondary) and a match-count capsule.
    private func fileHeader(relativePath: String, count: Int, noun: String) -> some View {
        let parts = SearchResultPathParts.split(relativePath)
        let icon = FileIconProvider.fileIcon(named: parts.name)
        return HStack(spacing: 6) {
            FileIconView(icon: icon, size: 12)
                .accessibilityHidden(true)
            Text(parts.name)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !parts.folder.isEmpty {
                Text(parts.folder)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            RafuChip(text: "\(count)", monospacedDigit: true)
        }
        .textCase(nil)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(relativePath), \(count) \(noun)")
    }
}

/// Splits a workspace-relative path into the file name and its folder, for
/// the search result file header (name first, folder in secondary text).
nonisolated enum SearchResultPathParts {
    static func split(_ relativePath: String) -> (name: String, folder: String) {
        guard let slash = relativePath.lastIndex(of: "/") else { return (relativePath, "") }
        let name = String(relativePath[relativePath.index(after: slash)...])
        let folder = String(relativePath[..<slash])
        return (name.isEmpty ? relativePath : name, folder)
    }
}

/// A one-line search result cut around its match: a little leading context,
/// the match itself, and trailing context. Offsets are UTF-16 (`NSString`),
/// matching `WorkspaceSearchMatch.column` and `range`.
nonisolated struct SearchResultSnippet: Equatable, Sendable {
    let prefix: String
    let match: String
    let suffix: String

    static func make(
        preview: String,
        column: Int,
        matchLength: Int,
        contextBefore: Int = 24,
        maximumMatch: Int = 48,
        contextAfter: Int = 72
    ) -> SearchResultSnippet {
        let line = preview as NSString
        let length = line.length
        // Skip the indentation: a result starts at the first visible character.
        var firstVisible = 0
        while firstVisible < length, isWhitespace(line.character(at: firstVisible)) {
            firstVisible += 1
        }
        let matchStart = min(max(column - 1, 0), length)
        guard matchStart < length else {
            // The match lies beyond the clipped preview; show the line start.
            let text = line.substring(from: min(firstVisible, length))
            return SearchResultSnippet(prefix: text, match: "", suffix: "")
        }
        let lowerBound = min(firstVisible, matchStart)
        var begin = max(lowerBound, matchStart - contextBefore)
        if begin > lowerBound, begin < length {
            begin = line.rangeOfComposedCharacterSequence(at: begin).location
        }
        var matchEnd = min(matchStart + max(matchLength, 0), length)
        var matchWasCut = false
        if matchEnd - matchStart > maximumMatch {
            matchEnd = matchStart + maximumMatch
            matchWasCut = true
        }
        if matchEnd < length {
            matchEnd = NSMaxRange(line.rangeOfComposedCharacterSequence(at: max(matchEnd - 1, 0)))
        }
        var suffixEnd = min(matchEnd + contextAfter, length)
        if suffixEnd < length {
            suffixEnd = NSMaxRange(
                line.rangeOfComposedCharacterSequence(at: max(suffixEnd - 1, 0)))
        }
        let leading = begin > lowerBound ? "…" : ""
        let trailing = (suffixEnd < length || matchWasCut) ? "…" : ""
        return SearchResultSnippet(
            prefix: leading
                + line.substring(with: NSRange(location: begin, length: matchStart - begin)),
            match: line.substring(
                with: NSRange(location: matchStart, length: matchEnd - matchStart)),
            suffix: line.substring(with: NSRange(location: matchEnd, length: suffixEnd - matchEnd))
                + trailing
        )
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09
    }
}
