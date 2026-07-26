import MarkdownUI
import SwiftUI

/// The one MarkdownUI presentation Rafu renders anywhere: theme-token text
/// colors, the flat table treatment, the card-anatomy code block, and the
/// Tree-sitter syntax highlighter.
///
/// It exists because there are now two Markdown surfaces — the document
/// preview (`MarkdownPreviewView`) and the New Ensemble goal pane
/// (`EnsembleGoalPane`) — and a second hand-rolled copy of these six
/// modifiers is exactly how two Markdown surfaces drift apart. Anything
/// genuinely per-document (`baseURL`, `imageBaseURL`, the local-file image
/// provider) deliberately stays at the call site: the goal pane has no
/// document and therefore no base directory to resolve against.
struct RafuMarkdownStyling: ViewModifier {
    @Environment(\.rafuTheme) private var theme

    func body(content: Content) -> some View {
        content
            .markdownTheme(.basic)
            .markdownTextStyle {
                ForegroundColor(theme.palette.textPrimary)
                FontSize(15)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(theme.palette.accent)
            }
            .markdownBlockStyle(\.table) { configuration in
                configuration.label
                    .markdownTableBorderStyle(
                        .init(color: theme.palette.borderSubtle, width: 1)
                    )
                    .markdownTableBackgroundStyle(
                        .alternatingRows(
                            theme.palette.elevatedBackground,
                            Color.clear,
                            header: theme.palette.selection
                        )
                    )
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                RafuMarkdownCodeBlockCard(configuration: configuration)
            }
            .tint(theme.palette.accent)
            .markdownCodeSyntaxHighlighter(TreeSitterCodeSyntaxHighlighter(theme: theme))
    }
}

extension View {
    /// Applies Rafu's shared MarkdownUI presentation (see
    /// `RafuMarkdownStyling`).
    func rafuMarkdownStyling() -> some View {
        modifier(RafuMarkdownStyling())
    }
}

/// A fenced code block as a flat card: a header row (language chip + copy
/// action) over `cardBackground`, then the syntax-highlighted body on a
/// horizontally scrollable strip so long lines never force the surrounding
/// column wide.
struct RafuMarkdownCodeBlockCard: View {
    let configuration: CodeBlockConfiguration

    @Environment(\.rafuTheme) private var theme

    private var language: String {
        configuration.language.flatMap { $0.isEmpty ? nil : $0 } ?? "text"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RafuCardHeaderRow {
                RafuChip(text: language.uppercased())
            } trailing: {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(configuration.content, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .help("Copy code")
                .accessibilityLabel("Copy code block")
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
