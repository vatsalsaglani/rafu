import MarkdownUI
import SwiftUI

struct MarkdownPreviewView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var segments: [MarkdownPreviewSegment] = []
    @State private var errorMessage: String?
    /// The MDX component registry, loaded off the main actor with each
    /// disk read and reused by the live-buffer refresh. Nil for Markdown.
    @State private var mdxRegistry: MDXComponentRegistry?

    let document: EditorDocument
    private let fileService = WorkspaceFileService()

    /// Directory the current document lives in, used to resolve relative
    /// and absolute local image/link references in the rendered Markdown
    /// (`Markdown(_:baseURL:imageBaseURL:)`). Cheap `URL` manipulation, safe
    /// to recompute per render.
    private var documentDirectory: URL {
        document.url.deletingLastPathComponent()
    }

    private var isMDX: Bool { document.url.pathExtension.lowercased() == "mdx" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if let errorMessage {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                }

                if let warnings = mdxRegistry?.warnings, !warnings.isEmpty {
                    MDXRegistryWarningsView(warnings: warnings)
                }

                ForEach(segments) { segment in
                    switch segment.content {
                    case .markdown(let source):
                        Markdown(
                            source, baseURL: documentDirectory, imageBaseURL: documentDirectory
                        )
                        .markdownImageProvider(LocalFileImageProvider())
                        .rafuMarkdownStyling()
                        .textSelection(.enabled)

                    case .mermaid(let result):
                        MermaidDiagramView(result: result)

                    case .frontmatter(let result):
                        MarkdownFrontmatterCard(result: result)

                    case .component(let block):
                        MDXComponentView(block: block, baseURL: documentDirectory)
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.vertical, 30)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(Color(rafuHex: theme.editor.background))
        .task(id: "\(document.url.path)#\(document.revision)") {
            do {
                let source = try await fileService.readText(at: document.url)
                if isMDX {
                    let url = document.url
                    mdxRegistry = await Task.detached {
                        MDXComponentRegistry.load(forDocumentAt: url)
                    }.value
                }
                await applySegments(from: source)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        // Live-buffer preview for `.split` mode: re-parses from the mounted
        // editor's in-memory text (never disk) on a trailing debounce after
        // each edit delta. View-lifetime (no `.task(id:)`), so it starts
        // once per mount and stops when this view is torn down —
        // `MarkdownEditorPresentation.renderedPreview` already mounts this
        // view with `.id(document.id)`, so a document switch remounts fresh.
        // In pure `.preview` mode no `CodeEditorView` is mounted, so
        // `textSnapshotProvider` stays `nil` and no edit deltas are ever
        // recorded — this task is inert there, and the disk-read `.task`
        // above remains the only source of truth for pure preview and for
        // external reloads.
        .task {
            // Trailing debounce: each new delta cancels the previous
            // pending refresh `Task` before its sleep completes, so only
            // the last delta in a burst actually reparses. The `Task`
            // reference itself is the cancellation token; `Task.sleep`'s
            // `CancellationError` is swallowed by returning early.
            var pendingRefresh: Task<Void, Never>?
            for await _ in document.editDeltas() {
                pendingRefresh?.cancel()
                pendingRefresh = Task {
                    do {
                        try await Task.sleep(for: .milliseconds(200))
                    } catch {
                        return
                    }
                    guard let snapshot = document.textSnapshotProvider else { return }
                    let text = snapshot()
                    await applySegments(from: text)
                }
            }
        }
    }

    /// Parses `source` into preview segments off the main actor and applies
    /// the result. `source` is always a local value — a disk read or a
    /// one-shot editor text snapshot — never retained; only the parsed
    /// `segments` persist in view state.
    private func applySegments(from source: String) async {
        let context: MDXParseContext? =
            isMDX
            ? MDXParseContext(registry: mdxRegistry ?? .builtIn, baseURL: documentDirectory)
            : nil
        let parsed = await Task.detached {
            MarkdownPreviewSegmentParser().parse(source, mdx: context)
        }.value
        segments = parsed
        errorMessage = nil
    }

}

nonisolated struct MarkdownPreviewSegment: Identifiable, Sendable {
    enum Content: Sendable {
        case markdown(String)
        case mermaid(MermaidParseResult)
        case frontmatter(MarkdownFrontmatterParseResult)
        /// An MDX component block (`.mdx` documents only, ADR 0034).
        case component(MDXBlock)
    }

    let id = UUID()
    let content: Content
}

nonisolated struct MarkdownPreviewSegmentParser: Sendable {
    /// One piece of a Markdown chunk after Mermaid fences are lifted out.
    enum Piece: Sendable {
        case markdown(String)
        case mermaid(MermaidParseResult)
    }

    /// `mdx` is non-nil for `.mdx` documents only (ADR 0034). Plain Markdown
    /// never goes through the MDX scanner.
    func parse(_ source: String, mdx: MDXParseContext? = nil) -> [MarkdownPreviewSegment] {
        var prefix: [MarkdownPreviewSegment] = []
        var markdownSource = source
        if let scanned = MarkdownFrontmatterScanner().scan(source) {
            if case .parsed(let metadata) = scanned.result,
                metadata.fieldCount == 0,
                metadata.raw.isEmpty
            {
                markdownSource = scanned.remainder
            } else {
                prefix.append(.init(content: .frontmatter(scanned.result)))
                markdownSource = scanned.remainder
            }
        }

        guard let mdx else {
            return prefix + Self.segments(fromMarkdown: markdownSource, keepsBlank: true)
        }
        var result = prefix
        var builder = MDXBlockBuilder(context: mdx)
        for content in MDXBlockScanner().scan(markdownSource) {
            switch content {
            case .markdown(let text):
                result.append(contentsOf: Self.segments(fromMarkdown: text, keepsBlank: false))
            case .component(let node):
                result.append(.init(content: .component(builder.build(node))))
            }
        }
        return result
    }

    private static func segments(fromMarkdown markdown: String, keepsBlank: Bool)
        -> [MarkdownPreviewSegment]
    {
        let pieces = splitMermaid(markdown)
        if pieces.isEmpty {
            return keepsBlank ? [.init(content: .markdown(markdown))] : []
        }
        return pieces.map { piece in
            switch piece {
            case .markdown(let text): .init(content: .markdown(text))
            case .mermaid(let result): .init(content: .mermaid(result))
            }
        }
    }

    /// Lifts ```` ```mermaid ```` fences out of `markdown`. Blank Markdown
    /// between diagrams is dropped; with no fence the whole text is one
    /// piece (empty when it is blank).
    static func splitMermaid(_ markdown: String) -> [Piece] {
        let isBlank = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let expression = try? NSRegularExpression(
            pattern: #"(?is)```mermaid[^\n]*\n(.*?)```"#
        )
        guard let expression else {
            return isBlank ? [] : [.markdown(markdown)]
        }

        let sourceString = markdown as NSString
        let fullRange = NSRange(location: 0, length: sourceString.length)
        let matches = expression.matches(in: markdown, range: fullRange)
        guard !matches.isEmpty else {
            return isBlank ? [] : [.markdown(markdown)]
        }

        var result: [Piece] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let text = sourceString.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.markdown(text))
                }
            }
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let mermaid = sourceString.substring(with: match.range(at: 1))
                result.append(.mermaid(MarkdownParser().parseMermaid(mermaid)))
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < sourceString.length {
            let text = sourceString.substring(
                with: NSRange(location: cursor, length: sourceString.length - cursor)
            )
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.markdown(text))
            }
        }
        return result
    }
}
