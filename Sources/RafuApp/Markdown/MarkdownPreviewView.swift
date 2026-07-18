import MarkdownUI
import SwiftUI

struct MarkdownPreviewView: View {
    @Environment(\.rafuTheme) private var theme
    @State private var segments: [MarkdownPreviewSegment] = []
    @State private var errorMessage: String?

    let document: EditorDocument
    private let fileService = WorkspaceFileService()

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
                        Markdown(source)
                            .markdownTheme(.basic)
                            .markdownTextStyle {
                                ForegroundColor(Color(rafuHex: theme.ui.textPrimary))
                                FontSize(15)
                            }
                            .markdownTextStyle(\.link) {
                                ForegroundColor(Color(rafuHex: theme.ui.accent))
                            }
                            .markdownBlockStyle(\.table) { configuration in
                                configuration.label
                                    .markdownTableBorderStyle(
                                        .init(
                                            color: Color(rafuHex: theme.ui.borderSubtle),
                                            width: 1
                                        )
                                    )
                                    .markdownTableBackgroundStyle(
                                        .alternatingRows(
                                            Color(rafuHex: theme.ui.elevatedBackground),
                                            Color.clear,
                                            header: Color(rafuHex: theme.ui.selection)
                                        )
                                    )
                            }
                            .markdownBlockStyle(\.codeBlock) { configuration in
                                codeBlockCard(configuration)
                            }
                            .tint(Color(rafuHex: theme.ui.accent))
                            .textSelection(.enabled)
                            .markdownCodeSyntaxHighlighter(
                                TreeSitterCodeSyntaxHighlighter(theme: theme))

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
                segments = MarkdownPreviewSegmentParser().parse(source)
                errorMessage = nil
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Renders a fenced code block as a flat card: a header row (language
    /// chip + copy action) over `cardBackground`, then the syntax-highlighted
    /// body (`TreeSitterCodeSyntaxHighlighter`, wired above via
    /// `.markdownCodeSyntaxHighlighter`) on a horizontally scrollable strip so
    /// long lines never force the preview column wide.
    private func codeBlockCard(_ configuration: CodeBlockConfiguration) -> some View {
        let language = configuration.language.flatMap { $0.isEmpty ? nil : $0 } ?? "text"
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                RafuChip(text: language.uppercased())
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration.content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .help("Copy code")
            }
            .padding(.horizontal, RafuMetrics.space3)
            .frame(height: RafuMetrics.sectionHeaderHeight)
            .background(theme.palette.cardBackground)
            .overlay(alignment: .bottom) {
                Divider().overlay(theme.palette.borderSubtle)
            }
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.15))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.94))
                    }
                    .padding(RafuMetrics.space3)
            }
        }
        .background(theme.palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
        .markdownMargin(top: .zero, bottom: .em(1))
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
