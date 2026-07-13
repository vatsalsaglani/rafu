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
    @State private var fileEntries: [PaletteFileEntry] = []
    @State private var symbolScan = SymbolScanState.idle
    @FocusState private var searchFocused: Bool

    private static let maximumFileRows = 100

    private enum SymbolScanState: Equatable {
        case idle
        case scanning
        case unavailable(String)
        case ready([BufferSymbol])
    }

    var body: some View {
        let parsed = PaletteQueryParser.parse(query)
        let rows = rows(for: parsed)
        VStack(spacing: 0) {
            paletteHeader(parsed: parsed, rows: rows)
            Divider().overlay(theme.palette.borderSubtle)
            if rows.isEmpty {
                emptyState(for: parsed)
            } else {
                resultsList(rows: rows)
            }
        }
        .frame(width: 580, height: 400)
        .background(paletteBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        .task {
            query = session.commandPaletteSeed
            fileEntries = PaletteFileEntry.flatten(session.fileTree)
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
            Image(systemName: headerSymbolName(for: parsed.mode))
                .frame(width: 18)
                .foregroundStyle(theme.palette.accent)
            TextField("Go to file… type > for commands, @ for symbols", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .onSubmit { run(rows, at: selectedIndex) }
            Text("⌘P").font(.caption.monospaced())
                .foregroundStyle(theme.palette.textMuted)
        }
        .padding(.horizontal, 16)
        .frame(height: 46)
    }

    private func headerSymbolName(for mode: PaletteQueryParser.Mode) -> String {
        switch mode {
        case .files: "doc.text.magnifyingglass"
        case .commands: "command"
        case .symbols: "at"
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
            return fileEntries.isEmpty ? "Open a folder to search its files" : "No matching files"
        case .symbols:
            switch symbolScan {
            case .idle, .scanning:
                return "Scanning symbols…"
            case .unavailable(let message):
                return message
            case .ready(let symbols):
                return symbols.isEmpty ? "No symbols found in this file" : "No matching symbols"
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
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            theme.palette.elevatedBackground.opacity(0.72)
        }
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
                    if let detail = row.detail {
                        Text(detail).font(.caption)
                            .foregroundStyle(theme.palette.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : .clear)
            )
        }
        .buttonStyle(.plain)
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
        }
    }

    private func fileRows(matching term: String) -> [PaletteRow] {
        let indices = CommandPaletteMatcher.rank(
            query: term,
            candidates: fileEntries.map(\.searchText)
        )
        return indices.prefix(Self.maximumFileRows).map { index in
            let node = fileEntries[index].node
            let icon = FileIconProvider.fileIcon(named: node.name)
            return PaletteRow(
                id: "file:\(node.url.path)",
                symbolName: icon.symbol,
                iconTint: icon.tint,
                fileIcon: icon,
                title: node.name,
                detail: node.relativePath == node.name ? nil : node.relativePath
            ) {
                dismiss()
                session.open(node)
            }
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
                id: "command:\(command.title)",
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
        let text = provider()
        let fileExtension = document.url.pathExtension.lowercased()
        symbolScan = .scanning
        Task {
            symbolScan = .ready(await Self.scanSymbols(text: text, fileExtension: fileExtension))
        }
    }

    @concurrent
    private static func scanSymbols(text: String, fileExtension: String) async -> [BufferSymbol] {
        BufferSymbolScanner.scan(text: text, fileExtension: fileExtension)
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
        ]
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
    let title: String
    var detail: String?
    let symbolName: String
    var keywords: [String]
    let action: @MainActor () -> Void

    var searchText: String { ([title, detail ?? ""] + keywords).joined(separator: " ") }
}

/// Flattened, files-only view of the workspace tree, built once per
/// palette presentation.
private struct PaletteFileEntry {
    let node: WorkspaceFileNode
    let searchText: String

    init(node: WorkspaceFileNode) {
        self.node = node
        searchText = node.name + " " + node.relativePath
    }

    static func flatten(_ nodes: [WorkspaceFileNode]) -> [PaletteFileEntry] {
        var entries: [PaletteFileEntry] = []
        appendFiles(from: nodes, into: &entries)
        return entries
    }

    private static func appendFiles(
        from nodes: [WorkspaceFileNode],
        into entries: inout [PaletteFileEntry]
    ) {
        for node in nodes {
            if node.isDirectory {
                appendFiles(from: node.children ?? [], into: &entries)
            } else {
                entries.append(PaletteFileEntry(node: node))
            }
        }
    }
}

/// Splits a palette query into its mode prefix and search term: plain text
/// searches files, ">" prefixes commands, "@" prefixes active-buffer symbols.
nonisolated enum PaletteQueryParser {
    enum Mode: Equatable, Sendable {
        case files
        case commands
        case symbols
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

    private static let prefixModes: [Character: Mode] = [">": .commands, "@": .symbols]
}

nonisolated enum CommandPaletteMatcher {
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
