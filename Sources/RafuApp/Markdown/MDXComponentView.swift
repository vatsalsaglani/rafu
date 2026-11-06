import MarkdownUI
import SwiftUI

/// Draws one resolved MDX component natively (ADR 0034). All data is
/// derived when the document is parsed; this view only lays it out. No
/// JavaScript runs and no web view is created.
struct MDXComponentView: View {
    let block: MDXBlock
    let baseURL: URL

    var body: some View {
        switch block.body {
        case .callout(let tone):
            MDXCalloutView(block: block, tone: tone, baseURL: baseURL)
        case .card(let status):
            MDXFrame {
                MDXHeader(
                    systemImage: "square.stack", title: block.title ?? block.name,
                    badge: status.map(MDXPresentation.statusLabel))
            } content: {
                MDXChildrenView(children: block.children, baseURL: baseURL)
            }
        case .checklist(let done, let total):
            MDXFrame {
                MDXHeader(
                    systemImage: "checklist", title: block.title ?? "Checklist",
                    badge: total > 0 ? "\(done) of \(total) done" : nil)
            } content: {
                MDXChildrenView(children: block.children, baseURL: baseURL)
            }
        case .questions(let questions):
            MDXFrame {
                MDXHeader(
                    systemImage: "questionmark.bubble",
                    title: block.title ?? "Questions", badge: nil)
            } content: {
                if questions.isEmpty {
                    MDXChildrenView(children: block.children, baseURL: baseURL)
                } else {
                    MDXQuestionsList(questions: questions)
                }
            }
        case .fileTree(let entries):
            MDXFrame {
                MDXHeader(
                    systemImage: "folder", title: block.title ?? "Files",
                    badge: nil)
            } content: {
                if entries.isEmpty {
                    MDXChildrenView(children: block.children, baseURL: baseURL)
                } else {
                    MDXFileTreeList(entries: entries)
                }
            }
        case .svg(let source, let caption):
            MDXFigureView(title: block.title, source: source, caption: caption)
        case .fallback:
            MDXFallbackBlock(block: block, baseURL: baseURL)
        }
    }
}

nonisolated enum MDXPresentation {
    /// `in-progress` → `In progress`.
    static func statusLabel(_ raw: String) -> String {
        let words = raw.replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        guard let first = words.first else { return raw }
        return first.uppercased() + words.dropFirst()
    }
}

/// Children in source order: Markdown, Mermaid, and nested components.
private struct MDXChildrenView: View {
    let children: [MDXBlockChild]
    let baseURL: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(children) { child in
                switch child.content {
                case .markdown(let source):
                    Markdown(source, baseURL: baseURL, imageBaseURL: baseURL)
                        .markdownImageProvider(LocalFileImageProvider())
                        .rafuMarkdownStyling()
                        .textSelection(.enabled)
                case .mermaid(let result):
                    MermaidDiagramView(result: result)
                case .component(let nested):
                    // `AnyView` breaks the recursive opaque type.
                    AnyView(MDXComponentView(block: nested, baseURL: baseURL))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The quiet bordered container every non-callout block shares.
private struct MDXFrame<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, RafuMetrics.space3)
                .padding(.vertical, RafuMetrics.space2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .bottom) {
                    Divider().overlay(theme.palette.borderSubtle)
                }
            content
                .padding(RafuMetrics.space3)
        }
        .background(theme.palette.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusPanel, style: .continuous))
    }
}

private struct MDXHeader: View {
    let systemImage: String
    let title: String
    let badge: String?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: systemImage)
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            Spacer(minLength: RafuMetrics.space2)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, RafuMetrics.space2)
                    .padding(.vertical, 2)
                    .background(theme.palette.chipBackground, in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A tone is shown by an icon and a word, never by color alone.
private struct MDXCalloutView: View {
    let block: MDXBlock
    let tone: MDXCalloutTone
    let baseURL: URL

    @Environment(\.rafuTheme) private var theme

    private var toneColor: Color {
        switch tone {
        case .note, .decision: theme.palette.accent
        case .tip: theme.palette.success
        case .info: theme.palette.info
        case .warning: theme.palette.warning
        case .risk: theme.palette.error
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                Image(systemName: tone.systemImage)
                    .foregroundStyle(toneColor)
                    .accessibilityHidden(true)
                Text(block.title ?? tone.label)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                if block.title != nil {
                    Text(tone.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                block.title.map { "\(tone.label): \($0)" } ?? tone.label)
            MDXChildrenView(children: block.children, baseURL: baseURL)
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .leading) {
            Rectangle().fill(toneColor).frame(width: 3)
        }
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
        .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous))
    }
}

private struct MDXQuestionsList: View {
    let questions: [MDXQuestion]

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            ForEach(questions) { question in
                VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                    Text("\(question.id + 1). \(question.text)")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(Array(question.options.enumerated()), id: \.offset) { _, option in
                        Label {
                            Text(option)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "circle")
                                .accessibilityHidden(true)
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(theme.palette.textSecondary)
                        .padding(.leading, RafuMetrics.space3)
                    }
                }
            }
        }
        .textSelection(.enabled)
    }
}

private struct MDXFileTreeList: View {
    let entries: [MDXFileTreeEntry]

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            ForEach(entries) { entry in
                HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
                    Image(systemName: entry.path.hasSuffix("/") ? "folder" : "doc")
                        .foregroundStyle(theme.palette.textSecondary)
                        .accessibilityHidden(true)
                    if let action = entry.action {
                        Text(action)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    Text(entry.path)
                        .font(.system(size: 12.5, design: .monospaced))
                        .foregroundStyle(theme.palette.textPrimary)
                    if let note = entry.note {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, CGFloat(entry.depth) * 16)
                .accessibilityElement(children: .combine)
            }
        }
        .textSelection(.enabled)
    }
}

/// `<Svg src=… />`: a local image through the shared Markdown image loader.
/// A remote source is named, never fetched.
private struct MDXFigureView: View {
    let title: String?
    let source: MDXImageSource
    let caption: String?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            switch source {
            case .local(let url):
                LocalFileImageProvider().makeImage(url: url)
                    .accessibilityLabel(title ?? caption ?? url.lastPathComponent)
            case .remote(let url):
                Label("Remote image not loaded: \(url)", systemImage: "network.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            case .missing:
                Label("Image has no local source", systemImage: "photo")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

/// A component with no native renderer. The name and props stay visible
/// and the children still render, so no content is hidden.
private struct MDXFallbackBlock: View {
    let block: MDXBlock
    let baseURL: URL

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        MDXFrame {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "<\(block.name)>")
                    .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary)
                if !block.propsLine.isEmpty {
                    Text(verbatim: block.propsLine)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(theme.palette.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .textSelection(.enabled)
            .help(
                "No native renderer for \(block.name). Map it in .rafu/mdx-components.json."
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Component \(block.name), shown as text")
        } content: {
            if block.children.isEmpty {
                Text("No content")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textMuted)
            } else {
                MDXChildrenView(children: block.children, baseURL: baseURL)
            }
        }
    }
}

/// Problems in `.rafu/mdx-components.json`, shown once above the preview.
struct MDXRegistryWarningsView: View {
    let warnings: [String]

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                    Text(warning)
                }
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle")
                .accessibilityHidden(true)
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.palette.textSecondary)
        .accessibilityLabel("Component registry problems: \(warnings.joined(separator: " "))")
    }
}
