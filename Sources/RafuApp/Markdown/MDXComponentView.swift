import MarkdownUI
import SwiftUI

/// Draws one resolved MDX component natively (ADR 0034). Every component the
/// registry knows renders through the Rafu json-render catalog
/// (`MDXCatalogBlockView`); an unknown component keeps the plain fallback
/// block. All data is derived when the document is parsed; this view only
/// lays it out. No JavaScript runs and no web view is created.
struct MDXComponentView: View {
    let block: MDXBlock
    let baseURL: URL

    var body: some View {
        if case .fallback = block.body {
            MDXFallbackBlock(block: block, baseURL: baseURL)
        } else {
            MDXCatalogBlockView(block: block, baseURL: baseURL)
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

/// A component with no native renderer. The name and props stay visible
/// and the children still render, so no content is hidden.
struct MDXFallbackBlock: View {
    let block: MDXBlock
    let baseURL: URL

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        RafuDocumentFrame {
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
