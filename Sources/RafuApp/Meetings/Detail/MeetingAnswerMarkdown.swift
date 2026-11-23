import MarkdownUI
import RafuCore
import SwiftUI

/// Model text (an answer or a summary) as Markdown, through the shared
/// MarkdownUI boundary (`rafuMarkdownStyling`), at 13 pt. The text is
/// untrusted:
/// - no image loads: the block and the inline image providers draw
///   nothing and read no URL;
/// - a link opens only when it is a citation (`rafu-meeting-turn:`); every
///   other URL is discarded, so a web link opens nothing;
/// - above `markdownByteLimit` it shows as plain text.
/// The caller rewrites the citations first
/// (`MeetingDetailPresentation.answerMarkdown`).
struct MeetingAnswerMarkdown: View {
    let markdown: String
    let onCite: (MeetingTurnID) -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            if MeetingDetailPresentation.usesMarkdown(markdown) {
                Markdown(markdown)
                    // Applied inside the shared styling, so this size is the
                    // last text style and wins over its 15 pt.
                    .markdownTextStyle { FontSize(13) }
                    .markdownImageProvider(MeetingNoImageProvider())
                    .markdownInlineImageProvider(MeetingNoInlineImageProvider())
                    .rafuMarkdownStyling()
            } else {
                Text(markdown)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.palette.textPrimary)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, Self.openAction(onCite: onCite))
    }

    /// Handles a citation link and discards every other URL.
    static func openAction(onCite: @escaping (MeetingTurnID) -> Void) -> OpenURLAction {
        OpenURLAction { url in
            guard let turn = MeetingDetailPresentation.turn(fromLink: url) else {
                return .discarded
            }
            onCite(turn)
            return .handled
        }
    }
}

/// A Markdown image provider that draws nothing and reads no URL: model
/// text never loads an image from the network or the disk.
struct MeetingNoImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        EmptyView()
    }
}

/// An inline image provider that loads nothing: every image fails at once.
struct MeetingNoInlineImageProvider: InlineImageProvider {
    struct NoImage: Error {}

    func image(with url: URL, label: String) async throws -> Image {
        throw NoImage()
    }
}
