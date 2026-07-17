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

struct MermaidDiagramView: View {
    @Environment(\.rafuTheme) private var theme
    let result: MermaidParseResult

    var body: some View {
        switch result {
        case .flow(let flow):
            diagramBody {
                ForEach(flow.edges, id: \.id) { edge in
                    HStack(spacing: 10) {
                        node(flow.nodes[edge.from] ?? edge.from)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(Color(rafuHex: theme.ui.accent))
                        if !edge.label.isEmpty {
                            Text(edge.label).font(.caption).foregroundStyle(.secondary)
                        }
                        node(flow.nodes[edge.to] ?? edge.to)
                    }
                }
            }
        case .sequence(let seq):
            diagramBody {
                HStack {
                    ForEach(seq.participants, id: \.self) {
                        node($0).frame(maxWidth: .infinity)
                    }
                }
                ForEach(seq.messages, id: \.id) { message in
                    HStack {
                        Text(message.from).font(.caption)
                        Image(systemName: "arrow.right")
                        Text(message.to).font(.caption)
                        Text(message.label).foregroundStyle(.secondary)
                    }
                }
            }
        case .unsupported(let type, let raw):
            MermaidUnsupportedView(type: type, raw: raw, reason: nil)
        case .malformed(let type, let raw, let reason):
            MermaidUnsupportedView(type: type, raw: raw, reason: reason)
        }
    }

    @ViewBuilder
    private func diagramBody<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Simplified native preview", systemImage: "point.3.connected.trianglepath.dotted")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(rafuHex: theme.ui.accent))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(rafuHex: theme.ui.elevatedBackground),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(rafuHex: theme.ui.borderSubtle))
        }
    }

    private func node(_ label: String) -> some View {
        Text(label)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(rafuHex: theme.ui.selection), in: Capsule())
    }
}

struct MermaidUnsupportedView: View {
    @Environment(\.rafuTheme) private var theme
    let type: String
    let raw: String
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(noticeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(rafuHex: theme.ui.warning ?? theme.ui.textSecondary))
            Text(raw)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(Color(rafuHex: theme.ui.textPrimary))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(rafuHex: theme.ui.elevatedBackground),
            in: .rect(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(rafuHex: theme.ui.borderSubtle))
        }
    }

    private var noticeText: String {
        if let reason {
            return "diagram type not supported in native preview — \(reason)"
        }
        return "diagram type not supported in native preview"
    }
}
