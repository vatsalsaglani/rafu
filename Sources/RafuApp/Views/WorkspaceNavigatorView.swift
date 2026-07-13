import SwiftUI

/// Right-hand utility panel hosting Search and Source Control.
/// The left sidebar is reserved for the file tree (see WorkspaceSidebarView);
/// this panel is toggled from the utility rail on the window's right edge.
struct WorkspaceUtilityPanelView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            panelHeader
            Divider().overlay(theme.palette.borderSubtle)
            panelContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.sidebarBackground.opacity(0.92))
    }

    private var panelHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: session.navigatorMode.symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
            Text(session.navigatorMode.title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.textMuted)
                .textCase(.uppercase)
                .kerning(0.6)
            Spacer()
            Button("Close Panel", systemImage: "xmark") {
                session.navigatorMode = .files
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
            .help("Close Panel")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch session.navigatorMode {
        case .files:
            EmptyView()
        case .search:
            WorkspaceSearchNavigatorView(session: session)
        case .sourceControl:
            if session.gitSnapshot != nil {
                GitInspectorView(session: session)
            } else {
                ContentUnavailableView(
                    "No Git Repository",
                    systemImage: "arrow.triangle.branch",
                    description: Text("Initialize Git in this workspace to use Source Control.")
                )
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
            Spacer()
        }
        .padding(.top, 10)
        .frame(width: 40)
        .frame(maxHeight: .infinity)
        .fixedSize(horizontal: true, vertical: false)
        .background(theme.palette.sidebarBackground.opacity(0.92))
    }

    private func railButton(_ mode: WorkspaceNavigatorMode) -> some View {
        let hasWorkspace = session.descriptor != nil
        let isActive = hasWorkspace && session.navigatorMode == mode
        return Button(mode.title, systemImage: mode.symbolName) {
            withAnimation(.spring(duration: 0.25)) {
                session.navigatorMode = isActive ? .files : mode
            }
        }
        .buttonStyle(RafuIconButtonStyle(isActive: isActive, size: 30, iconSize: 14))
        .disabled(!hasWorkspace)
        .help(hasWorkspace ? mode.title : "\(mode.title) — open a folder first")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

struct WorkspaceSearchNavigatorView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        WorkspaceSearchContent(session: session, search: session.workspaceSearch)
    }
}

private struct WorkspaceSearchContent: View {
    @Bindable var session: WorkspaceSession
    @Bindable var search: WorkspaceSearchModel
    @Environment(\.rafuTheme) private var theme
    @FocusState private var isQueryFocused: Bool
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
                    .textFieldStyle(.roundedBorder)
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
            HStack(spacing: 6) {
                TextField("files to include", text: $search.includePattern)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(performSearch)
                    .help("Include only matching files, e.g. *.swift, Sources/**")
                TextField("files to exclude", text: $search.excludePattern)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit(performSearch)
                    .help("Skip matching files and folders, e.g. *.md, Tests/**")
            }
            HStack(spacing: 6) {
                searchOptionButton("Case Sensitive", symbol: "textformat", option: .caseSensitive)
                searchOptionButton(
                    "Whole Word", symbol: "character.cursor.ibeam", option: .wholeWord)
                searchOptionButton(
                    "Regular Expression", symbol: "asterisk", option: .regularExpression)
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
                        .textFieldStyle(.roundedBorder)
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
        .padding(10)
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
            ContentUnavailableView(
                "Search Workspace",
                systemImage: "magnifyingglass",
                description: Text("Find or replace text across the open folder.")
            )
        }
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
        .buttonStyle(RafuIconButtonStyle(isActive: selected, size: 24))
        .help(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
