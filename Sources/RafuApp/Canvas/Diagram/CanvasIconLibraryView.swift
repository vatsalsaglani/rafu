import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The board the icon library adds to. Weak, so a closed window is not kept.
@MainActor
final class CanvasIconLibraryTarget {
    weak var board: CanvasBoardState?
    weak var session: WorkspaceSession?
}

/// Searchable icon grid. Click an icon to add it to the Canvas.
struct CanvasIconLibraryView: View {
    @Environment(\.rafuTheme) private var theme
    let target: CanvasIconLibraryTarget
    @State private var library = CanvasIconPackLibrary.shared
    @State private var query = ""
    @State private var packID = Self.allPacks
    @State private var results: [CanvasServiceIconMatch] = []

    private static let allPacks = "*"
    private let columns = [GridItem(.adaptive(minimum: 84, maximum: 110), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            CanvasIconLibraryHeader(
                query: $query, packID: $packID, packs: library.packs, allPacks: Self.allPacks)
            Divider()
            grid
            Divider()
            footer
        }
        .frame(minWidth: 340, minHeight: 380, alignment: .top)
        .background(theme.palette.elevatedBackground)
        .task { await library.loadIfNeeded() }
        .task(id: searchKey) { refresh() }
    }

    private var searchKey: String {
        "\(packID)\u{1F}\(query)\u{1F}\(library.packs.map(\.id).joined(separator: ","))"
    }

    private func refresh() {
        let matches = library.search(query, limit: packID == Self.allPacks ? 240 : 2_000)
        results =
            packID == Self.allPacks
            ? matches : Array(matches.filter { $0.packID == packID }.prefix(240))
    }

    @ViewBuilder private var grid: some View {
        if results.isEmpty {
            Text(query.isEmpty ? "No icons installed." : "No icons match “\(query)”.")
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(results) { match in
                        CanvasIconLibraryTile(match: match) { add(match) }
                    }
                }
                .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(footerText)
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button("Import Icon Pack…") { CanvasDiagramPanels.showImport() }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerText: String {
        if let notice = library.notice { return notice }
        guard let board = target.board else { return "Open a Canvas to add icons." }
        return "Click an icon to add it to “\(board.title)”."
    }

    private func add(_ match: CanvasServiceIconMatch) {
        guard let board = target.board, let session = target.session else { return }
        session.performCanvasEdit(board) { try board.addServiceIcon(match.icon) }
    }
}

private struct CanvasIconLibraryHeader: View {
    @Environment(\.rafuTheme) private var theme
    @Binding var query: String
    @Binding var packID: String
    let packs: [CanvasIconPack]
    let allPacks: String
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(theme.palette.textSecondary)
                    .accessibilityHidden(true)
                TextField("Search icons", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Search icons")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchField)
                    .fill(theme.palette.fieldBackground)
            )
            Picker("Pack", selection: $packID) {
                Text("All Packs").tag(allPacks)
                ForEach(packs) { pack in Text(pack.name).tag(pack.id) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Show one icon pack")
        }
        .padding(10)
        .onAppear { searchFocused = true }
    }
}

private struct CanvasIconLibraryTile: View {
    @Environment(\.rafuTheme) private var theme
    let match: CanvasServiceIconMatch
    let add: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: add) {
            VStack(spacing: 4) {
                CanvasServiceIconImage(icon: match.icon)
                    .frame(width: 40, height: 40)
                Text(match.entry.name)
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 84)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovering ? theme.palette.hover : Color.clear)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("\(match.entry.name) — \(match.packName), \(match.entry.category)")
        .accessibilityLabel("Add \(match.entry.name)")
        .accessibilityHint("\(match.packName) icon, \(match.entry.category)")
    }
}

/// Import Icon Pack…: where to get the official packs, a chooser, and the
/// installed packs.
struct CanvasIconPackImportView: View {
    @Environment(\.rafuTheme) private var theme
    let dismiss: () -> Void
    @State private var library = CanvasIconPackLibrary.shared

    var body: some View {
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
                CanvasIconPackSourceRow(vendor: vendor, library: library)
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

    /// The user sees the vendor, the exact source, the size and the terms
    /// before anything is fetched.
    private func confirm(_ source: CanvasIconPackSource) {
        let alert = NSAlert()
        alert.messageText = "Download \(vendor.title) icons?"
        let size = CanvasIconPackDownloads.approximateSize(source.approximateBytes)
        alert.informativeText = """
            Source: \(source.url.absoluteString)
            Size: about \(size)

            Rafu checks the file, then copies its SVG and PNG icons into its support folder. \
            Use the icons under \(vendor.title)'s terms: \(source.pageURL.absoluteString)
            """
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "View Terms")
        let window = NSApp.keyWindow
        Task {
            let response: NSApplication.ModalResponse
            if let window {
                response = await alert.beginSheetModal(for: window)
            } else {
                response = alert.runModal()
            }
            switch response {
            case .alertFirstButtonReturn: library.startDownload(source)
            case .alertThirdButtonReturn: NSWorkspace.shared.open(source.pageURL)
            default: break
            }
        }
    }
}
