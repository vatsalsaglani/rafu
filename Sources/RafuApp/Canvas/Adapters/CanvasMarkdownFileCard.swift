import AppKit
import MarkdownUI
import SwiftUI

extension WorkspaceSession {
    /// The open editor document that shows the workspace file at `path`, if any.
    /// A file card reads its buffer, even a dirty one, before the disk.
    func openDocument(forCanvasPath path: String) -> EditorDocument? {
        openDocuments.first { relativePath(for: $0.url) == path }
    }
}

/// A rendered Markdown view of a `.md` or `.markdown` file card: front matter,
/// headings, lists, tables, fenced code with the Tree-sitter highlighter, and
/// native Mermaid diagrams. Read-only, and never writes the file.
///
/// The text is read once per load (the open buffer, else the first 64 KiB of
/// the file), parsed off the main actor, and dropped; only the parsed rows stay
/// in state. Rows sit in a `LazyVStack`, one MarkdownUI view per top-level
/// block, so a long file builds only the blocks scrolled to. The card does not
/// watch the file: it reloads when the path or the matching open document's
/// revision (a save or an external reload) changes.
struct CanvasMarkdownFileCard: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let path: String
    let board: CanvasBoardState
    let session: WorkspaceSession
    var activate: () -> Void = {}
    @State private var items: [CanvasMarkdownCard.Item] = []
    @State private var notice: String?
    @State private var isTruncated = false
    @State private var hasLoaded = false

    private struct LoadKey: Hashable {
        let path: String
        let revision: Int?
    }

    private var isContentActive: Bool {
        board.contentIsActive && board.focusedCardID == card.id
    }

    private var loadKey: LoadKey {
        LoadKey(path: path, revision: session.openDocument(forCanvasPath: path)?.revision)
    }

    /// The file's own folder, so a relative image or link resolves as it does
    /// in the editor preview. `CanvasNoteLink` still confines it to the workspace.
    private var documentDirectory: URL? {
        CanvasNoteLink.baseURL(
            for: session.rootURL?.appending(path: path).deletingLastPathComponent())
    }

    var body: some View {
        let baseURL = documentDirectory
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let notice {
                    Text(notice).font(.system(size: 12)).foregroundStyle(
                        theme.palette.textSecondary)
                } else if hasLoaded, items.isEmpty {
                    Text("This file is empty.").font(.system(size: 12)).foregroundStyle(
                        theme.palette.textMuted)
                }
                ForEach(items) { item in
                    CanvasMarkdownItemView(item: item, baseURL: baseURL, root: session.rootURL)
                        .padding(.top, item.gap)
                }
                if isTruncated {
                    Text("Preview shows the first 64 KB")
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                        .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .textSelection(.enabled)
        }
        // The board already keeps wheel events while the card is not active
        // (`capturesScroll`); this also stops drag and key scrolling.
        .scrollDisabled(!isContentActive)
        .background(theme.palette.editorBackground)
        .environment(
            \.openURL,
            OpenURLAction { url in
                MainActor.assumeIsolated { open(url) }
                return .handled
            }
        )
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .simultaneousGesture(TapGesture(count: 2).onEnded { session.openCanvasFile(path) })
        .help("Double-click to open \(path) in the editor")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(path), Markdown preview")
        .task(id: loadKey) { await load() }
        .canvasCardFill()
        .clipped()
    }

    private func open(_ url: URL) {
        switch CanvasNoteLink.classify(url, root: session.rootURL) {
        case .workspaceFile(let target): session.openCanvasFile(target)
        case .external(let target): NSWorkspace.shared.open(target)
        case .ignored: NSSound.beep()
        }
    }

    private func load() async {
        guard let root = session.rootURL else { return }
        let limit = CanvasLimits.markdownPreviewBytes
        let text: String
        if let snapshot = session.openDocument(forCanvasPath: path)?.textSnapshotProvider {
            text = String(decoding: snapshot().utf8.prefix(limit), as: UTF8.self)
        } else {
            do {
                text = try await CanvasPreviewLoader.text(path: path, root: root, limit: limit)
            } catch is CancellationError {
                return
            } catch {
                notice = error.localizedDescription
                hasLoaded = true
                return
            }
        }
        let cut = CanvasMarkdownCard.truncatedAtLastLine(text, limitBytes: limit)
        let parsed = await CanvasMarkdownCard.parsedItems(from: cut.text)
        guard !Task.isCancelled else { return }
        notice = nil
        isTruncated = cut.isTruncated
        items = parsed
        hasLoaded = true
    }
}

/// One row: a top-level Markdown block through the shared MarkdownUI boundary,
/// a native Mermaid diagram, or the front-matter card. Task boxes get no
/// `canvasNoteTasks` context, so they stay inert: a file card never edits the
/// file.
private struct CanvasMarkdownItemView: View {
    let item: CanvasMarkdownCard.Item
    let baseURL: URL?
    let root: URL?

    var body: some View {
        switch item.kind {
        case .block(let block):
            markdown(block.text)
                .markdownImageProvider(CanvasNoteImageProvider(root: root))
                .rafuNoteMarkdownStyling()
                .canvasNoteBlockSpace()
                .frame(maxWidth: .infinity, alignment: .leading)
        case .mermaid(let result):
            MermaidDiagramView(result: result)
        case .frontmatter(let result):
            MarkdownFrontmatterCard(result: result)
        }
    }

    @ViewBuilder
    private func markdown(_ text: String) -> some View {
        if let baseURL {
            Markdown(text, baseURL: baseURL, imageBaseURL: baseURL)
        } else {
            Markdown(text)
        }
    }
}
