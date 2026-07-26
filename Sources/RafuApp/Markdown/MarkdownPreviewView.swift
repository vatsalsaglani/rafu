import MarkdownUI
import SwiftUI

struct MarkdownPreviewView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var segments: [MarkdownPreviewSegment] = []
    @State private var errorMessage: String?

    let document: EditorDocument
    private let fileService = WorkspaceFileService()

    /// Directory the current document lives in, used to resolve relative
    /// and absolute local image/link references in the rendered Markdown
    /// (`Markdown(_:baseURL:imageBaseURL:)`). Cheap `URL` manipulation, safe
    /// to recompute per render.
    private var documentDirectory: URL {
        document.url.deletingLastPathComponent()
    }

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
        let parsed = await Task.detached { MarkdownPreviewSegmentParser().parse(source) }.value
        segments = parsed
        errorMessage = nil
    }

}

nonisolated struct MarkdownPreviewSegment: Identifiable, Sendable {
    enum Content: Sendable {
        case markdown(String)
        case mermaid(MermaidParseResult)
    }

    let id = UUID()
    let content: Content
}

nonisolated struct MarkdownPreviewSegmentParser: Sendable {
    func parse(_ source: String) -> [MarkdownPreviewSegment] {
        let expression = try? NSRegularExpression(
            pattern: #"(?is)```mermaid[^\n]*\n(.*?)```"#
        )
        guard let expression else {
            return [.init(content: .markdown(source))]
        }

        let sourceString = source as NSString
        let fullRange = NSRange(location: 0, length: sourceString.length)
        let matches = expression.matches(in: source, range: fullRange)
        guard !matches.isEmpty else {
            return [.init(content: .markdown(source))]
        }

        var result: [MarkdownPreviewSegment] = []
        var cursor = 0
        for match in matches {
            if match.range.location > cursor {
                let markdown = sourceString.substring(
                    with: NSRange(location: cursor, length: match.range.location - cursor)
                )
                if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(.init(content: .markdown(markdown)))
                }
            }
            if match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                let mermaid = sourceString.substring(with: match.range(at: 1))
                result.append(
                    .init(content: .mermaid(MarkdownParser().parseMermaid(mermaid)))
                )
            }
            cursor = match.range.location + match.range.length
        }

        if cursor < sourceString.length {
            let markdown = sourceString.substring(
                with: NSRange(location: cursor, length: sourceString.length - cursor)
            )
            if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(.init(content: .markdown(markdown)))
            }
        }
        return result
    }
}
