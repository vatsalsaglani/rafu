import JSONRenderClient
import SwiftUI

/// `Mermaid`: a Mermaid diagram drawn natively (ADR 0020), never with
/// mermaid.js. Six diagram kinds render; anything else shows an honest note.
@JRComponent(
    "Mermaid",
    description:
        "A Mermaid diagram. source is the diagram text without code fences. Flowchart, sequence, class, state, ER and XY chart render; other kinds show their source."
)
nonisolated struct RafuDocMermaid: View {
    @JRProp(description: "Mermaid source text.") var source: String

    var body: some View {
        RafuDocMermaidView(source: source)
    }
}

struct RafuDocMermaidView: View {
    let source: String

    @State private var result: MermaidParseResult?

    var body: some View {
        Group {
            if let result {
                MermaidDiagramView(result: result)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .task(id: source) {
            let text = source
            result = await Task.detached { MarkdownParser().parseMermaid(text) }.value
        }
    }
}
