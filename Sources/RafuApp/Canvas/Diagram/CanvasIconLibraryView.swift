import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board the icon library adds to. Weak, so a closed window is not kept.
@MainActor
final class CanvasIconLibraryTarget {
    weak var board: CanvasBoardState?
    weak var session: WorkspaceSession?
}

/// The Icon Library grid (UX Round C): five 72 pt tiles with 32 pt icons and
/// 11 pt labels. The panel width follows from them.
nonisolated enum CanvasIconLibraryMetrics {
    static let columns = 5
    static let tile: CGFloat = 72
    static let icon: CGFloat = 32
    static let label: CGFloat = 11
    static let spacing: CGFloat = 8
    static let padding: CGFloat = 12
    /// The grid's own width: 5 × 72 + 4 × 8 + 2 × 12 = 416 pt.
    static var panelWidth: CGFloat {
        CGFloat(columns) * tile + CGFloat(columns - 1) * spacing + 2 * padding
    }
    /// The panel and view minimum: the grid plus room for a scroller.
    static var minimumPanelWidth: CGFloat { panelWidth + 24 }
}

/// Arrow-key movement over the Icon Library's fixed-column grid. Pure, so
/// it is unit-tested.
nonisolated enum CanvasIconLibraryNavigation {
    static let columns = CanvasIconLibraryMetrics.columns

    enum Direction { case left, right, up, down }

    static func move(_ index: Int, _ direction: Direction, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let index = min(max(index, 0), count - 1)
        switch direction {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, count - 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down: return index + columns < count ? index + columns : index
        }
    }
}

/// Searchable icon grid in the Rafu popup language. Click an icon, or move
/// with the arrow keys and press Return, to add it to the Ensemble.
struct CanvasIconLibraryView: View {
    @Environment(\.rafuTheme) private var theme
    let target: CanvasIconLibraryTarget
    var close: () -> Void = {}
    @State private var library = CanvasIconPackLibrary.shared
    @State private var query = ""
    @State private var packID = Self.allPacks
    @State private var results: [CanvasServiceIconMatch] = []
    @State private var highlighted = 0
    @FocusState private var searchFocused: Bool

    private static let allPacks = "*"
    private let columns = Array(
        repeating: GridItem(
            .fixed(CanvasIconLibraryMetrics.tile), spacing: CanvasIconLibraryMetrics.spacing),
        count: CanvasIconLibraryMetrics.columns)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuPopupHeader(
                symbol: "square.grid.3x3", title: "Icon Library", subtitle: subtitle
            ) {
                Picker("Pack", selection: $packID) {
                    Text("All Packs").tag(Self.allPacks)
                    ForEach(library.packs) { pack in Text(pack.name).tag(pack.id) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Show one icon pack")
            }
            RafuPopupSearchField(
                prompt: "Search icons", text: $query,
                hint: CanvasBoardKeyMap.serviceIconKey.map(CanvasBoardKeyMap.display),
                focus: $searchFocused
            )
            .onSubmit(addHighlighted)
            .onKeyPress(.downArrow) { move(.down) }
            .onKeyPress(.upArrow) { move(.up) }
            .onKeyPress(.leftArrow) {
                guard query.isEmpty else { return .ignored }
                return move(.left)
            }
            .onKeyPress(.rightArrow) {
                guard query.isEmpty else { return .ignored }
                return move(.right)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            RafuPopupDivider()
            grid
            RafuPopupFooter(hints: [("↑↓←→", "Move"), ("↩", "Add"), ("esc", "Close")]) {
                Button("Import Pack…") { CanvasDiagramPanels.showImport() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .frame(
            minWidth: CanvasIconLibraryMetrics.minimumPanelWidth, minHeight: 400, alignment: .top
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .rafuPopupEntrance()
        .onAppear { searchFocused = true }
        .onExitCommand(perform: close)
        .task { await library.loadIfNeeded() }
        .task(id: searchKey) { refresh() }
    }

    private var subtitle: String {
        if let notice = library.notice { return notice }
        guard let board = target.board else { return "Open an Ensemble to add icons." }
        return "Click an icon to add it to “\(board.title)”."
    }

    private var searchKey: String {
        "\(packID)\u{1F}\(query)\u{1F}\(library.packs.map(\.id).joined(separator: ","))"
    }

    private func refresh() {
        let matches = library.search(query, limit: packID == Self.allPacks ? 240 : 2_000)
        results =
            packID == Self.allPacks
            ? matches : Array(matches.filter { $0.packID == packID }.prefix(240))
        highlighted = 0
    }

    private func move(_ direction: CanvasIconLibraryNavigation.Direction) -> KeyPress.Result {
        highlighted = CanvasIconLibraryNavigation.move(highlighted, direction, count: results.count)
        return .handled
    }

    @ViewBuilder private var grid: some View {
        if results.isEmpty {
            RafuEmptyState(
                symbol: "square.grid.3x3",
                message: query.isEmpty ? "No icons installed." : "No icons match “\(query)”.",
                actionTitle: query.isEmpty ? "Import Pack…" : nil,
                action: query.isEmpty ? { CanvasDiagramPanels.showImport() } : nil)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: CanvasIconLibraryMetrics.spacing) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, match in
                            CanvasIconLibraryTile(
                                match: match, query: query, isHighlighted: index == highlighted
                            ) { add(match) }
                            .id(match.id)
                        }
                    }
                    .padding(CanvasIconLibraryMetrics.padding)
                }
                .onChange(of: highlighted) { _, index in
                    guard results.indices.contains(index) else { return }
                    proxy.scrollTo(results[index].id, anchor: nil)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func addHighlighted() {
        guard results.indices.contains(highlighted) else { return }
        add(results[highlighted])
    }

    private func add(_ match: CanvasServiceIconMatch) {
        guard let board = target.board, let session = target.session else { return }
        session.performCanvasEdit(board) { try board.addServiceIcon(match.icon) }
    }
}

private struct CanvasIconLibraryTile: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    let match: CanvasServiceIconMatch
    /// The search text; the matched part of the name is bold.
    let query: String
    let isHighlighted: Bool
    let add: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: add) {
            VStack(spacing: 4) {
                CanvasServiceIconImage(icon: match.icon)
                    .frame(
                        width: CanvasIconLibraryMetrics.icon, height: CanvasIconLibraryMetrics.icon)
                // Weight, not colour, marks the match.
                Text(CanvasIconNameHighlight.attributed(match.entry.name, query: query))
                    .font(.system(size: CanvasIconLibraryMetrics.label))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .padding(4)
            .frame(width: CanvasIconLibraryMetrics.tile)
            .frame(minHeight: CanvasIconLibraryMetrics.tile)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isHighlighted ? border : .clear, lineWidth: 1)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(match.entry.name) — \(match.packName), \(match.entry.category)")
        .accessibilityLabel("Add \(match.entry.name)")
        .accessibilityHint("\(match.packName) icon, \(match.entry.category)")
        .accessibilityAddTraits(isHighlighted ? .isSelected : [])
    }

    private var fill: Color {
        if isHighlighted { return theme.palette.selection }
        return isHovering ? theme.palette.hover : .clear
    }

    private var border: Color {
        contrast == .increased ? theme.palette.borderStrong : theme.palette.borderSubtle
    }
}

/// Import Icon Pack…: where to get the official packs, a chooser, and the
/// installed packs.
struct CanvasIconPackImportView: View {
    @Environment(\.rafuTheme) private var theme
    let dismiss: () -> Void
    @State private var library = CanvasIconPackLibrary.shared
    /// The download waiting for the user's confirmation.
    @State private var pendingDownload: CanvasIconPackSource?

    var body: some View {
        if let source = pendingDownload {
            downloadConfirmation(source)
        } else {
            content
        }
    }

    /// The user sees the vendor, the exact source, the size and the terms
    /// before anything is fetched.
    private func downloadConfirmation(_ source: CanvasIconPackSource) -> some View {
        let vendor = source.vendor.title
        let size = CanvasIconPackDownloads.approximateSize(source.approximateBytes)
        return RafuConfirmPopup(
            symbol: "arrow.down.circle", title: "Download \(vendor) icons?",
            message: """
                Source: \(source.url.absoluteString)
                Size: about \(size)

                Rafu checks the file, then copies its SVG and PNG icons into its support folder. \
                Use the icons under \(vendor)'s terms: \(source.pageURL.absoluteString)
                """,
            actions: [
                .init("View Terms") { NSWorkspace.shared.open(source.pageURL) },
                .init("Download") {
                    pendingDownload = nil
                    library.startDownload(source)
                },
            ],
            defaultActionID: "Download"
        ) {
            pendingDownload = nil
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Icon Pack")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
            Text(
                "Download an official icon set with one click, or download it yourself and choose the ZIP file or its folder. Rafu copies SVG and PNG icons into its own support folder; nothing is uploaded. Use each vendor's icons under its terms."
            )
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            sources
            installed
            if let notice = library.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                if library.isImporting {
                    ProgressView().controlSize(.small)
                    Text("Importing…").font(.callout)
                }
                Spacer()
                Button("Done", action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Choose ZIP or Folder…", action: choose)
                    .keyboardShortcut(.defaultAction)
                    .disabled(library.isImporting || library.download != nil)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 400, alignment: .top)
        .task { await library.loadIfNeeded() }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([CanvasIconPackVendor.aws, .azure, .googleCloud], id: \.self) { vendor in
                CanvasIconPackSourceRow(vendor: vendor, library: library) { source in
                    pendingDownload = source
                }
            }
            if let download = library.download {
                HStack(spacing: 8) {
                    if let fraction = download.fraction {
                        ProgressView(value: fraction).frame(maxWidth: 200)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text("Downloading \(download.vendor.title) icons…").font(.callout)
                    Button("Cancel") { library.cancelDownload() }
                        .controlSize(.small)
                        .accessibilityLabel("Cancel download")
                }
            }
        }
    }

    @ViewBuilder private var installed: some View {
        let imported = library.importedPacks
        if !imported.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Installed")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                ForEach(imported) { pack in
                    HStack {
                        Text("\(pack.name) — \(pack.entries.count) icons")
                            .foregroundStyle(theme.palette.textSecondary)
                        Spacer()
                        Button("Remove") { Task { await library.remove(packID: pack.id) } }
                            .controlSize(.small)
                            .accessibilityLabel("Remove \(pack.name) icons")
                    }
                }
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = "Import"
        panel.message = "Choose an icon pack ZIP file or folder."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await CanvasIconPackLibrary.shared.importPack(from: url) }
        }
    }
}

/// One vendor: its official page, and a one-click Download of the pinned file.
private struct CanvasIconPackSourceRow: View {
    @Environment(\.rafuTheme) private var theme
    let vendor: CanvasIconPackVendor
    let library: CanvasIconPackLibrary
    /// Asks the import view to confirm the download first.
    let confirm: (CanvasIconPackSource) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let url = vendor.downloadPage {
                Link(destination: url) {
                    Label("\(vendor.title) icons (official page)", systemImage: "link")
                }
                .help(url.absoluteString)
            }
            Spacer(minLength: 8)
            if let source = CanvasIconPackDownloads.source(for: vendor) {
                Button("Download") { confirm(source) }
                    .controlSize(.small)
                    .disabled(library.download != nil || library.isImporting)
                    .help(
                        "Download \(CanvasIconPackDownloads.approximateSize(source.approximateBytes)) from \(source.url.host() ?? "the vendor")"
                    )
                    .accessibilityLabel("Download \(vendor.title) icons")
            }
        }
    }
}
