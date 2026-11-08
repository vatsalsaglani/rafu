import JSONRenderClient
import MarkdownUI
import SwiftUI

/// `Code`: a code block drawn like a fenced block in the Markdown preview,
/// with the same Tree-sitter highlighting. Text over 64 KiB is cut and says so.
@JRComponent(
    "Code",
    description:
        "A block of source code. language is a fence name such as swift or json. Text over 64 KiB is cut."
)
nonisolated struct RafuDocCode: View {
    @JRProp(description: "The code text.") var text: String
    @JRProp(description: "Language name, for highlighting.") var language: String?

    /// Shown bytes. A longer text shows its first 64 KiB.
    static let maxBytes = 64 * 1024

    var body: some View {
        RafuDocCodeView(text: text, language: language)
    }

    static func truncated(_ text: String) -> (text: String, isCut: Bool) {
        guard text.utf8.count > maxBytes else { return (text, false) }
        var length = maxBytes
        while length > 0 {
            if let prefix = String(text.utf8.prefix(length)) { return (prefix, true) }
            length -= 1
        }
        return ("", true)
    }

    /// A fenced block whose fence is longer than any backtick run in `text`,
    /// so the text cannot close the fence early.
    static func fenced(_ text: String, language: String?) -> String {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let info = (language ?? "").filter { !$0.isWhitespace && $0 != "`" }
        return "\(fence)\(info)\n\(text)\n\(fence)"
    }
}

struct RafuDocCodeView: View {
    let text: String
    let language: String?

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        let shown = RafuDocCode.truncated(text)
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Markdown(RafuDocCode.fenced(shown.text, language: language))
                .rafuMarkdownStyling()
            if shown.isCut {
                Text("Showing the first 64 KiB.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
