import SwiftUI

/// Right-hand utility panel hosting Search and Source Control.
/// The left sidebar is reserved for the file tree (see WorkspaceSidebarView);
/// this panel is toggled from the utility rail on the window's right edge.
struct WorkspaceUtilityPanelView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        panelContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(theme.palette.elevatedBackground)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch session.navigatorMode {
        case .files:
            EmptyView()
        case .search:
            WorkspaceSearchNavigatorView(session: session)
        case .sourceControl:
            SourceControlPanelView(session: session)
        case .terminals:
            WorkspaceTerminalsPanelView(session: session)
        case .runs:
            ConductorRunsPanelView(session: session)
        }
    }
}

/// Slim column pinned to the window's LEFT edge, mirroring
/// `WorkspaceUtilityRail` on the right. The app's ONE sidebar toggle
/// (ADR 0002) visually sits at the top of this rail, but the button itself
/// lives in `WindowTopLeftControlCluster`, overlaid by
/// `WorkspaceWindowView`: the window content extends into the titlebar zone
/// (`.ignoresSafeArea(.top)` + `FlatWindowChrome`), and the toggle must
/// slide right of the traffic lights when they reveal — a 40 pt column
/// cannot host that travel.
struct WorkspaceSidebarRail: View {
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        WindowDragHandle()
            .frame(width: 40)
            .frame(maxHeight: .infinity)
            .background(theme.palette.sidebarBackground)
    }
}

/// The window's top-left control cluster, overlaid in the titlebar zone.
/// Holds the sidebar toggle and, in front of it, the space the traffic
/// lights occupy when revealed. Outside full screen the lights stay hidden
/// (`FlatWindowChrome.hidesTrafficLights`) until the pointer enters this
/// cluster; the toggle then slides right to clear them (the cmux-style
/// hover-reveal validated in the TitleBarProto spike).
struct WindowTopLeftControlCluster: View {
    @Bindable var session: WorkspaceSession
    /// The traffic lights currently occupy top-left window space.
    let lightsVisible: Bool
    /// Hover tracking is meaningless in full screen, where the system owns
    /// the (auto-hidden) lights.
    let hoverTrackingEnabled: Bool
    let onHoverChange: (Bool) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Width of the zone the system traffic lights occupy (x ≈ 12…70).
    private static let trafficLightSpan: CGFloat = 76
    /// Matches the tab-strip / sidebar-header top row.
    private static let rowHeight: CGFloat = 36

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: lightsVisible ? Self.trafficLightSpan : 0, height: Self.rowHeight)
            Button("Toggle Sidebar", systemImage: "sidebar.left") {
                if reduceMotion {
                    session.toggleSidebar()
                } else {
                    withAnimation(.spring(duration: 0.25)) {
                        session.toggleSidebar()
                    }
                }
            }
            .buttonStyle(
                RafuRailButtonStyle(
                    isSelected: !session.isSidebarCollapsed,
                    deckFacingEdge: .trailing,
                    tooltip: session.isSidebarCollapsed
                        ? "Show Sidebar (⌘B)" : "Hide Sidebar (⌘B)"
                )
            )
            .accessibilityLabel("Toggle Sidebar")
            .accessibilityValue(session.isSidebarCollapsed ? "Hidden" : "Shown")
            .padding(.leading, lightsVisible ? 0 : 5)
        }
        // Breathing room below the window's top edge; also drops the toggle
        // onto the traffic lights' own baseline when they reveal.
        .padding(.top, 6)
        .frame(height: Self.rowHeight + 6, alignment: .top)
        // The cluster is exactly as wide as its content: rail-width while
        // the lights are hidden, lights + toggle while revealed. Keeping the
        // collapsed zone narrow matters — a wider invisible zone would eat
        // clicks meant for the sidebar header's leading edge.
        .contentShape(Rectangle())
        .onHover { inside in
            guard hoverTrackingEnabled else { return }
            if reduceMotion {
                onHoverChange(inside)
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    onHoverChange(inside)
                }
            }
        }
    }
}

/// Slim icon rail pinned to the window's right edge. Toggles the utility panel.
struct WorkspaceUtilityRail: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 8) {
            railButton(.search)
            railButton(.sourceControl)
            railButton(.terminals)
            railButton(.runs)
            Spacer()
        }
        // Centers the first 30 pt button on the sidebar toggle's baseline
        // (center ≈ 24 pt) now that the rail reaches the window's top edge.
        .padding(.top, 9)
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .background(WindowDragHandle())
        .background(theme.palette.sidebarBackground)
    }

    private func railButton(_ mode: WorkspaceNavigatorMode) -> some View {
        let hasWorkspace = session.descriptor != nil
        let isActive = hasWorkspace && session.navigatorMode == mode
        // Only computed for `.terminals` — deriving it for every rail
        // button would needlessly walk `terminal.sessions` on every render.
        let attentionCount =
            mode == .terminals
            ? TerminalsPanelModel.attentionCount(sessions: session.terminal.sessions)
            : 0
        let button =
            Button(mode.title, systemImage: mode.symbolName) {
                session.navigatorMode = isActive ? .files : mode
            }
            .buttonStyle(
                RafuRailButtonStyle(
                    isSelected: isActive,
                    deckFacingEdge: .leading,
                    tooltip: hasWorkspace ? mode.title : "\(mode.title) — open a folder first",
                    badge: mode == .terminals && attentionCount > 0 ? attentionCount : nil
                )
            )
            .disabled(!hasWorkspace)
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
                onClose: { session.navigatorMode = .files }
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
            HStack(spacing: 6) {
                searchOptionButton(
                    "Case", accessibilityLabel: "Case Sensitive",
                    symbol: "textformat", option: .caseSensitive)
                searchOptionButton(
                    "Whole Word", accessibilityLabel: "Whole Word",
                    symbol: "character.cursor.ibeam", option: .wholeWord)
                searchOptionButton(
                    "Regex", accessibilityLabel: "Regular Expression",
                    symbol: "asterisk", option: .regularExpression)
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
                    Section(file.relativePath) {
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
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        } else if let result = search.result, !result.groups.isEmpty {
            List {
                ForEach(result.groups) { group in
                    Section(group.relativePath) {
                        ForEach(group.matches) { match in
                            Button {
                                session.openSearchMatch(group, match: match)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 7) {
                                    Text("\(match.line):\(match.column)")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(theme.palette.textMuted)
                                        .frame(width: 44, alignment: .trailing)
                                    Text(match.preview).font(.caption.monospaced())
                                        .foregroundStyle(theme.palette.textPrimary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
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

    private func performSearch() {
        guard let rootURL = session.rootURL else { return }
        search.search(in: rootURL)
    }

    private func previewReplacements() {
        guard let rootURL = session.rootURL else { return }
        search.previewReplacements(in: rootURL)
    }

    private func searchOptionButton(
        _ title: String,
        accessibilityLabel: String,
        symbol: String,
        option: TextSearchOptions
    ) -> some View {
        let selected = search.options.contains(option)
        return Button(title, systemImage: symbol) {
            if selected {
                search.options.remove(option)
            } else {
                search.options.insert(option)
            }
        }
        .font(.caption)
        .foregroundStyle(selected ? theme.palette.textPrimary : theme.palette.textSecondary)
        .padding(.horizontal, 6)
        .frame(minHeight: 24)
        .background(
            selected ? theme.palette.selection : Color.clear,
            in: RoundedRectangle(
                cornerRadius: RafuMetrics.radiusDenseSelection,
                style: .continuous
            )
        )
        .overlay {
            RoundedRectangle(
                cornerRadius: RafuMetrics.radiusDenseSelection,
                style: .continuous
            )
            .strokeBorder(
                selected ? theme.palette.borderStrong : theme.palette.borderSubtle,
                lineWidth: RafuMetrics.hairline
            )
        }
        .buttonStyle(.plain)
        .help(accessibilityLabel)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
