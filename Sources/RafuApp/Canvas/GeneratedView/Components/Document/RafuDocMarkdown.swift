import JSONRenderClient
import MarkdownUI
import SwiftUI

/// `Markdown`: a Markdown block drawn with the same styling as the Markdown
/// preview (`RafuMarkdownStyling`). Relative images resolve against the
/// document directory when the view sits in an MDX document.
///
/// Every document component is a `nonisolated` shell (the `@JRComponent`
/// conformance must be usable from the nonisolated catalog build) that hands
/// its props to a main-actor view.
@JRComponent(
    "Markdown",
    description:
        "A block of Markdown text (headings, lists, tables, links, inline code). Use for prose inside a document or a card."
)
nonisolated struct RafuDocMarkdown: View {
    @JRProp(description: "Markdown source.") var text: String

    var body: some View {
        RafuDocMarkdownView(text: text)
    }
}

struct RafuDocMarkdownView: View {
    let text: String

    @Environment(\.rafuDocumentBaseURL) private var baseURL

    var body: some View {
        Markdown(text, baseURL: baseURL, imageBaseURL: baseURL)
            .markdownImageProvider(LocalFileImageProvider())
            .rafuMarkdownStyling()
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
