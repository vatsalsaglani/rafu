import Foundation
import SwiftUI

struct CommandPaletteView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.rafuTheme) private var theme
    @AppStorage("themeChoice") private var themeChoice: String = RafuThemeChoice.system.rawValue
    @Bindable var session: WorkspaceSession
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var fileMatches: [String] = []
    @State private var symbolScan = SymbolScanState.idle
    @State private var workspaceSymbolMatches: [WorkspaceSymbolMatch] = []
    @FocusState private var searchFocused: Bool

    private static let maximumFileRows = 100

    private enum SymbolScanState: Equatable {
        case idle
        case scanning
        case unavailable(String)
        case ready([BufferSymbol])
    }

    /// Keys the file-mode query task off both the search term and the
    /// index-build generation: a build that completes while the palette is
    /// open (or was already open when it started) must re-run the query, or
    /// results stay empty forever until the next keystroke.
    private struct FileQueryKey: Equatable {
        let term: String
        let generation: Int
    }

    /// Keys the workspace-symbol query task off the search term, the symbol
    /// index generation, and whether `#` mode is active — the last so that
    /// switching INTO `#` mode with an already-typed term still fires the
    /// query, and switching out stops re-querying.
    private struct WorkspaceSymbolQueryKey: Equatable {
        let isActive: Bool
        let term: String
        let generation: Int
    }

    var body: some View {
        let parsed = PaletteQueryParser.parse(query)
        let rows = rows(for: parsed)
        VStack(spacing: 0) {
            paletteHeader(parsed: parsed, rows: rows)
            if let caption = fileIndexCaption(for: parsed) {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }
            Divider().overlay(theme.palette.borderSubtle)
            if rows.isEmpty {
                emptyState(for: parsed)
            } else {
                resultsList(rows: rows)
            }
            paletteFooterHints
        }
        .frame(width: 580, height: 400)
        .background(paletteBackground)
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderStrong.opacity(0.5))
        )
        .onKeyPress(.downArrow) {
            moveSelection(1, count: rows.count)
            return .handled
        }
        .onKeyPress(.upArrow) {
            moveSelection(-1, count: rows.count)
            return .handled
        }
        .onChange(of: query) { _, _ in selectedIndex = 0 }
        .onChange(of: parsed.mode) { _, newMode in
            if newMode == .symbols { prepareSymbolsIfNeeded() }
        }
        .task(
            id: FileQueryKey(
                term: PaletteQueryParser.parse(query).term,
                generation: session.fileIndexGeneration
            )
        ) {
            await runFileQuery(term: PaletteQueryParser.parse(query).term)
        }
        .task(
            id: WorkspaceSymbolQueryKey(
                isActive: PaletteQueryParser.parse(query).mode == .workspaceSymbols,
                term: PaletteQueryParser.parse(query).term,
                generation: session.symbolIndexGeneration
            )
        ) {
            await runWorkspaceSymbolQuery(parsed: PaletteQueryParser.parse(query))
        }
        .task {
            query = session.commandPaletteSeed
            if PaletteQueryParser.parse(session.commandPaletteSeed).mode == .symbols {
                prepareSymbolsIfNeeded()
            }
            searchFocused = true
        }
    }

    private func paletteHeader(
        parsed: PaletteQueryParser.ParsedQuery,
        rows: [PaletteRow]
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: headerSymbolName(for: parsed.mode))
                    .frame(width: 18)
                    .foregroundStyle(theme.palette.accent)
                TextField(
                    "Go to file… > commands, @ file symbols, # workspace symbols", text: $query
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { run(rows, at: selectedIndex) }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                    .fill(theme.palette.fieldBackground)
            )
            RafuChip(text: "⌘P")
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func headerSymbolName(for mode: PaletteQueryParser.Mode) -> String {
        switch mode {
        case .files: "doc.text.magnifyingglass"
        case .commands: "command"
        case .symbols: "at"
        case .workspaceSymbols: "number.square"
        }
    }

    private func emptyState(for parsed: PaletteQueryParser.ParsedQuery) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 22))
                .foregroundStyle(theme.palette.textMuted)
            Text(emptyStateMessage(for: parsed))
                .foregroundStyle(theme.palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyStateMessage(for parsed: PaletteQueryParser.ParsedQuery) -> String {
        switch parsed.mode {
        case .commands:
            return "No matching commands"
        case .files:
            switch session.fileIndexState {
            case .idle:
                return "Open a folder to search its files"
            case .building where fileMatches.isEmpty:
                return "Indexing files…"
            case .building, .ready:
                return "No matching files"
            }
        case .symbols:
            switch symbolScan {
            case .idle, .scanning:
                return "Scanning symbols…"
            case .unavailable(let message):
                return message
            case .ready(let symbols):
                return symbols.isEmpty ? "No symbols found in this file" : "No matching symbols"
            }
        case .workspaceSymbols:
            switch session.symbolIndexState {
            case .idle:
                return "Open a folder to search its symbols"
            case .building where workspaceSymbolMatches.isEmpty:
                return "Indexing symbols…"
            case .building, .ready:
                return "No matching symbols"
            }
        }
    }

    private func resultsList(rows: [PaletteRow]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        paletteRowView(row, isSelected: index == selectedIndex)
                            .id(index)
                            .onHover { hovering in
                                if hovering { selectedIndex = index }
                            }
                    }
                }
                .padding(6)
            }
            .onChange(of: selectedIndex) { _, newValue in
                proxy.scrollTo(newValue, anchor: nil)
            }
        }
    }

    private var paletteBackground: some View {
        theme.palette.cardBackground
    }

    /// A trailing capsule chip for a genuine keyboard-shortcut hint (e.g.
    /// "⌃`"); longer descriptive detail (paths, hunk headers, summaries)
    /// keeps reading as a plain secondary line under the title.
    private func isShortcutHint(_ detail: String) -> Bool {
        !detail.isEmpty && detail.allSatisfy { "⌘⌃⇧⌥⌫⏎`".contains($0) }
    }

    private func paletteRowView(_ row: PaletteRow, isSelected: Bool) -> some View {
        Button {
            row.action()
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let fileIcon = row.fileIcon {
                        FileIconView(icon: fileIcon, size: 13)
                    } else {
                        Image(systemName: row.symbolName)
                            .foregroundStyle(iconColor(for: row, isSelected: isSelected))
                    }
                }
                .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                    if let detail = row.detail, !isShortcutHint(detail) {
                        Text(detail).font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if let detail = row.detail, isShortcutHint(detail) {
                    RafuChip(text: detail)
                }
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .contentShape(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
            )
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var paletteFooterHints: some View {
        HStack(spacing: 14) {
            footerHint(symbol: "arrow.up.arrow.down", label: "Navigate")
            footerHint(symbol: "return", label: "Open")
            footerHint(symbol: "escape", label: "Close")
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: RafuMetrics.statusBarHeight)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
        .accessibilityHidden(true)
    }

    private func footerHint(symbol: String, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(theme.palette.textMuted)
    }

    private func iconColor(for row: PaletteRow, isSelected: Bool) -> Color {
        if let tint = row.iconTint { return theme.palette.color(for: tint) }
        return isSelected ? theme.palette.accent : theme.palette.textSecondary
    }

    private func moveSelection(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        selectedIndex = (selectedIndex + delta + count) % count
    }

    private func run(_ rows: [PaletteRow], at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows[index].action()
    }

    // MARK: - Rows per mode

    private func rows(for parsed: PaletteQueryParser.ParsedQuery) -> [PaletteRow] {
        switch parsed.mode {
        case .files: fileRows(matching: parsed.term)
        case .commands: commandRows(matching: parsed.term)
        case .symbols: symbolRows(matching: parsed.term)
        case .workspaceSymbols: workspaceSymbolRows(matching: parsed.term)
        }
    }

    /// `fileMatches` is already ranked and top-N limited by the background
    /// index query (`runFileQuery`); this only turns the relative paths it
    /// found into rows.
    private func fileRows(matching term: String) -> [PaletteRow] {
        fileMatches.map { relativePath in
            let name = (relativePath as NSString).lastPathComponent
            let icon = FileIconProvider.fileIcon(named: name)
            return PaletteRow(
                id: "file:\(relativePath)",
                symbolName: icon.symbol,
                iconTint: icon.tint,
                fileIcon: icon,
                title: name,
                detail: relativePath == name ? nil : relativePath
            ) {
                dismiss()
                session.openFile(atRelativePath: relativePath)
            }
        }
    }

    /// Queries the background file-name index off-main; superseded by the
    /// next keystroke or index rebuild via `.task(id:)` cancellation.
    /// `ensureFileIndexReady()` transparently rebuilds an index a
    /// memory-pressure shed emptied — a no-op the rest of the time.
    private func runFileQuery(term: String) async {
        session.ensureFileIndexReady()
        do {
            let results = try await session.queryFileIndex(term: term, limit: Self.maximumFileRows)
            fileMatches = results
        } catch is CancellationError {
        } catch {
            fileMatches = []
        }
    }

    private func fileIndexCaption(for parsed: PaletteQueryParser.ParsedQuery) -> String? {
        switch parsed.mode {
        case .files:
            guard case .ready(_, true) = session.fileIndexState else { return nil }
            return
                "Showing top \(Self.maximumFileRows) matches — file index truncated at "
                + "\(WorkspaceFileNameIndex.maximumEntries) files"
        case .workspaceSymbols:
            guard case .ready(_, true) = session.symbolIndexState else { return nil }
            return
                "Showing top \(Self.maximumFileRows) matches — symbol index truncated at "
                + "\(WorkspaceSymbolIndex.maximumSymbols) symbols"
        case .commands, .symbols:
            return nil
        }
    }

    /// `workspaceSymbolMatches` is already ranked and top-N limited by the
    /// background index query (`runWorkspaceSymbolQuery`); this only turns the
    /// matches into rows. Selection jumps directly to the declaration (no peek
    /// UI this increment — that is 10b).
    private func workspaceSymbolRows(matching term: String) -> [PaletteRow] {
        workspaceSymbolMatches.map { match in
            PaletteRow(
                id: "wsymbol:\(match.relativePath):\(match.range.location):\(match.name)",
                symbolName: Self.symbolIcon(for: match.kind),
                iconTint: .accent,
                title: match.name,
                detail: "\(match.relativePath) · \(match.kind)"
            ) {
                dismiss()
                session.openWorkspaceSymbol(relativePath: match.relativePath, range: match.range)
            }
        }
    }

    /// Queries the background workspace-symbol index off-main; superseded by
    /// the next keystroke or index rebuild via `.task(id:)` cancellation. Only
    /// runs while `#` mode is active. `ensureSymbolIndexReady()` transparently
    /// rebuilds an index a memory-pressure shed emptied.
    private func runWorkspaceSymbolQuery(parsed: PaletteQueryParser.ParsedQuery) async {
        guard parsed.mode == .workspaceSymbols else { return }
        session.ensureSymbolIndexReady()
        do {
            workspaceSymbolMatches = try await session.queryWorkspaceSymbols(
                term: parsed.term, limit: Self.maximumFileRows)
        } catch is CancellationError {
        } catch {
            workspaceSymbolMatches = []
        }
    }

    private static func symbolIcon(for kind: String) -> String {
        switch kind {
        case "function", "method": "function"
        case "class", "interface": "cube"
        case "property": "circle"
        case "constant": "number"
        case "module": "shippingbox"
        default: "curlybraces"
        }
    }

    private func commandRows(matching term: String) -> [PaletteRow] {
        let commands = makeCommands()
        let indices = CommandPaletteMatcher.rank(
            query: term,
            candidates: commands.map(\.searchText)
        )
        return indices.map { index in
            let command = commands[index]
            return PaletteRow(
                id: command.id ?? "command:\(command.title)",
                symbolName: command.symbolName,
                iconTint: nil,
                title: command.title,
                detail: command.detail,
                action: command.action
            )
        }
    }

    private func symbolRows(matching term: String) -> [PaletteRow] {
        guard case .ready(let symbols) = symbolScan,
            let document = session.selectedDocument
        else { return [] }
        let indices = CommandPaletteMatcher.rank(
            query: term,
            candidates: symbols.map(\.name)
        )
        return indices.map { index in
            let symbol = symbols[index]
            return PaletteRow(
                id: "symbol:\(symbol.range.location):\(symbol.name)",
                symbolName: symbol.kind.symbolName,
                iconTint: .accent,
                title: symbol.name,
                detail: symbol.detail
            ) {
                dismiss()
                session.findState(for: document).select(symbol.range)
            }
        }
    }

    // MARK: - Symbol scanning

    private func prepareSymbolsIfNeeded() {
        guard case .idle = symbolScan else { return }
        guard let document = session.selectedDocument else {
            symbolScan = .unavailable("Open a file to browse its symbols")
            return
        }
        guard let provider = document.textSnapshotProvider else {
            symbolScan = .unavailable("Symbols are unavailable for this view")
            return
        }
        guard !document.suppressesSyntax else {
            symbolScan = .unavailable("Symbols are off for this large file")
            return
        }
        let text = provider()
        let fileExtension = document.url.pathExtension.lowercased()
        symbolScan = .scanning
        Task {
            symbolScan = .ready(await Self.scanSymbols(text: text, fileExtension: fileExtension))
        }
    }

    /// Grammar-backed extraction (increment 9) wins when the file maps to a
    /// packaged grammar with a vendored `tags.scm` and one-shot parsing
    /// succeeds; `nil` from `scanUsingGrammar` (no grammar, no `tags.scm`,
    /// parser rejection) falls back to the regex `BufferSymbolScanner` —
    /// e.g. any language without a packaged grammar. Markdown is routed to
    /// the regex path unconditionally (symbol-coverage lane increment C):
    /// its `tags.scm` captures headings as a flat `section` kind for the
    /// workspace symbol index, while `@`-mode display wants the regex
    /// scanner's `.heading(level:)` so palette rows keep showing H1–H6.
    @concurrent
    private static func scanSymbols(text: String, fileExtension: String) async -> [BufferSymbol] {
        if let grammarID = GrammarLanguageID.languageID(forExtension: fileExtension, fileName: ""),
            grammarID != .markdown,
            let symbols = await BufferSymbolScanner.scanUsingGrammar(
                text: text, grammarID: grammarID)
        {
            return symbols
        }
        return BufferSymbolScanner.scan(text: text, fileExtension: fileExtension)
    }

    // MARK: - Commands

    private func makeCommands() -> [PaletteCommand] {
        var commands: [PaletteCommand] = [
            .init(title: "Open Folder…", symbolName: "folder.badge.plus", keywords: ["workspace"]) {
                dismiss()
                session.requestOpenFolder()
            },
            .init(
                title: "New Workspace Window", symbolName: "macwindow.badge.plus",
                keywords: ["window"]
            ) {
                dismiss()
                openWindow(id: "workspace")
            },
            .init(
                title: "Search Workspace", symbolName: "magnifyingglass",
                keywords: ["find", "replace"]
            ) {
                dismiss()
                session.navigatorMode = .search
            },
            .init(
                title: "Find in File", symbolName: "doc.text.magnifyingglass",
                keywords: ["find", "replace"]
            ) {
                dismiss()
                session.showDocumentFind()
            },
            .init(
                title: "Show Source Control", symbolName: "arrow.triangle.branch",
                keywords: ["git", "changes"]
            ) {
                dismiss()
                session.navigatorMode = .sourceControl
            },
            .init(
                title: "Hide Utility Panel", symbolName: "sidebar.right",
                keywords: ["close", "panel"]
            ) {
                dismiss()
                session.navigatorMode = .files
            },
            .init(title: "New File", symbolName: "doc.badge.plus", keywords: ["create"]) {
                dismiss()
                session.requestFileCreation(isDirectory: false)
            },
            .init(title: "New Folder", symbolName: "folder.badge.plus", keywords: ["create"]) {
                dismiss()
                session.requestFileCreation(isDirectory: true)
            },
            .init(
                title: "Toggle Terminal", detail: "⌃`",
                symbolName: "terminal", keywords: ["shell", "console", "panel"]
            ) {
                dismiss()
                session.toggleTerminal()
            },
            .init(
                title: "New Terminal Tab", detail: "⌃⇧`",
                symbolName: "plus.rectangle.on.rectangle",
                keywords: ["shell", "console", "terminal", "tab"]
            ) {
                dismiss()
                session.newTerminalTab()
            },
            .init(
                title: "Install rafu CLI", detail: "Installs to ~/.local/bin",
                symbolName: "terminal", keywords: ["command line"]
            ) {
                dismiss()
                session.installCLI()
            },
            .init(
                id: NavigationCommandID.showResources,
                title: "Show Resources", symbolName: "memorychip",
                keywords: ["memory", "process", "resources"]
            ) {
                dismiss()
                session.showResources()
            },
        ]

        if let openDiff = session.gitOpenDiff,
            !session.isGitBusy,
            !session.isGitHunkActionBusy,
            session.gitSnapshot?.changes.first(where: { $0.path == openDiff.diff.path })?.kind
                == .modified
        {
            let action: (verb: String, symbol: String, perform: (GitDiffHunk) async -> Void)? =
                switch openDiff.scope {
                case .workingTree:
                    ("Stage", "plus.circle", { await session.stageHunk($0) })
                case .staged:
                    ("Unstage", "minus.circle", { await session.unstageHunk($0) })
                case .commit, .between:
                    nil
                }
            if let action {
                for (offset, hunk) in openDiff.diff.hunks.enumerated() {
                    let title =
                        openDiff.diff.hunks.count == 1
                        ? "\(action.verb) Hunk"
                        : "\(action.verb) Hunk \(offset + 1)"
                    commands.append(
                        .init(
                            id: "git.\(action.verb.lowercased())-hunk.\(hunk.id)",
                            title: title,
                            detail: hunk.header,
                            symbolName: action.symbol,
                            keywords: ["git", "index", "patch"]
                        ) {
                            dismiss()
                            Task { await action.perform(hunk) }
                        }
                    )
                }
            }
        }

        if session.gitSnapshot?.changes.contains(where: { $0.kind != .untracked }) == true,
            !session.isGitBusy,
            !session.isGitHunkActionBusy
        {
            commands.append(
                .init(
                    id: "git.stash-changes",
                    title: "Stash Changes",
                    detail: "Tracked files; Source Control has message and untracked options",
                    symbolName: "archivebox",
                    keywords: ["git", "save", "worktree"]
                ) {
                    dismiss()
                    Task { await session.stashChanges(message: "", includeUntracked: false) }
                }
            )
        }

        if let document = session.selectedDocument,
            !document.isDirty,
            session.gitSnapshot != nil,
            !session.isGitBusy
        {
            commands.append(
                .init(
                    id: "git.blame-file",
                    title: "Blame File",
                    detail: "Read-only line attribution",
                    symbolName: "person.text.rectangle",
                    keywords: ["git", "author", "history", "ownership"]
                ) {
                    dismiss()
                    Task { await session.openBlameForSelectedFile() }
                }
            )
        }

        for choice in RafuThemeChoice.allCases {
            commands.append(
                .init(
                    title: "Theme: \(choice.title)",
                    detail: themeChoice == choice.rawValue ? "Active" : nil,
                    symbolName: "paintpalette",
                    keywords: ["theme", "appearance", "color"]
                ) {
                    themeChoice = choice.rawValue
                    dismiss()
                }
            )
        }
        return commands
    }
}

/// One palette result row, regardless of mode. IDs are prefixed per mode so
/// files, commands, and symbols never collide.
private struct PaletteRow: Identifiable {
    let id: String
    let symbolName: String
    let iconTint: FileIconProvider.Tint?
    var fileIcon: FileIconProvider.Icon? = nil
    let title: String
    let detail: String?
    let action: @MainActor () -> Void
}

private struct PaletteCommand {
    /// Stable identifier for commands that also have a menu/status-item
    /// counterpart (e.g. `NavigationCommandID.showResources`). `nil` for
    /// commands only reachable from the palette, which fall back to a
    /// title-derived row id.
    var id: String?
    let title: String
    var detail: String?
    let symbolName: String
    var keywords: [String]
    let action: @MainActor () -> Void

    var searchText: String { ([title, detail ?? ""] + keywords).joined(separator: " ") }
}

/// Splits a palette query into its mode prefix and search term: plain text
/// searches files, ">" prefixes commands, "@" prefixes active-buffer symbols.
nonisolated enum PaletteQueryParser {
    enum Mode: Equatable, Sendable {
        case files
        case commands
        case symbols
        case workspaceSymbols
    }

    struct ParsedQuery: Equatable, Sendable {
        let mode: Mode
        let term: String
    }

    static func parse(_ query: String) -> ParsedQuery {
        if let first = query.first, let mode = prefixModes[first] {
            return ParsedQuery(
                mode: mode,
                term: String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
            )
        }
        return ParsedQuery(mode: .files, term: query.trimmingCharacters(in: .whitespaces))
    }

    private static let prefixModes: [Character: Mode] = [
        ">": .commands, "@": .symbols, "#": .workspaceSymbols,
    ]
}

nonisolated enum CommandPaletteMatcher {
    /// A tier above any full-path substring score, so a filename match
    /// always outranks a same-strength path match (e.g. typing "view" finds
    /// `Sources/RafuApp/Views/CommandPaletteView.swift` ahead of a file that
    /// merely lives under a `View`-named directory).
    private static let filenameBonus = 6_000

    /// Ranks full workspace-relative file paths for the command palette's
    /// file mode. Unlike `rank`, this scores the filename (last path
    /// component) and the full path independently and keeps the higher of
    /// the two (filename boosted), so a strong filename match always beats
    /// a weaker path-only match regardless of nesting depth. Runs inside
    /// `WorkspaceFileNameIndex`, checking for cancellation periodically so a
    /// keystroke supersedes an in-flight rank over a large index.
    static func rankFiles(query: String, paths: [String], limit: Int) async throws -> [String] {
        let needle = normalized(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return Array(paths.prefix(max(0, limit))) }

        var scored: [(score: Int, index: Int)] = []
        scored.reserveCapacity(paths.count)
        for (index, path) in paths.enumerated() {
            if index.isMultiple(of: 4_096) { try Task.checkCancellation() }
            guard let matchScore = fileScore(needle: needle, path: path) else { continue }
            scored.append((matchScore, index))
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let lhsPath = paths[lhs.index]
            let rhsPath = paths[rhs.index]
            if lhsPath.count != rhsPath.count { return lhsPath.count < rhsPath.count }
            return lhsPath < rhsPath
        }
        return scored.prefix(max(0, limit)).map { paths[$0.index] }
    }

    private static func fileScore(needle: String, path: String) -> Int? {
        let fullPathScore = score(needle: needle, candidate: normalized(path))
        let fileName = (path as NSString).lastPathComponent
        let filenameScore = score(needle: needle, candidate: normalized(fileName))
            .map { $0 + filenameBonus }
        switch (filenameScore, fullPathScore) {
        case (.some(let a), .some(let b)): return max(a, b)
        case (.some(let a), nil): return a
        case (nil, .some(let b)): return b
        case (nil, nil): return nil
        }
    }

    static func rank(query: String, candidates: [String]) -> [Int] {
        let needle = normalized(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return Array(candidates.indices) }

        return candidates.enumerated().compactMap { index, candidate -> (Int, Int)? in
            score(needle: needle, candidate: normalized(candidate)).map { ($0, index) }
        }
        .sorted { lhs, rhs in
            lhs.0 == rhs.0 ? lhs.1 < rhs.1 : lhs.0 > rhs.0
        }
        .map(\.1)
    }

    static func score(query: String, candidate: String) -> Int? {
        let needle = normalized(query).filter { !$0.isWhitespace }
        guard !needle.isEmpty else { return 0 }
        return score(needle: needle, candidate: normalized(candidate))
    }

    private static func score(needle: String, candidate: String) -> Int? {
        if needle == candidate { return 10_000 }
        if let range = candidate.range(of: needle) {
            return 5_000 - candidate.distance(from: candidate.startIndex, to: range.lowerBound)
        }

        let needleCharacters = Array(needle)
        let candidateCharacters = Array(candidate)
        var needleIndex = 0
        var score = max(0, 200 - candidateCharacters.count)
        var previousMatchIndex: Int?

        for index in candidateCharacters.indices {
            guard needleIndex < needleCharacters.count,
                candidateCharacters[index] == needleCharacters[needleIndex]
            else { continue }

            if let previousMatchIndex {
                let gap = index - previousMatchIndex - 1
                score += gap == 0 ? 24 : max(1, 8 - gap)
            } else {
                score += index == 0 ? 32 : max(1, 12 - index)
            }
            if index == 0 || !candidateCharacters[index - 1].isLetter {
                score += 18
            }
            previousMatchIndex = index
            needleIndex += 1
        }
        return needleIndex == needleCharacters.count ? score : nil
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
