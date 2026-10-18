import AppKit
import MarkdownUI
import SwiftUI

/// The compact MarkdownUI presentation for Canvas notes (review 7.8). It is a
/// sibling of `RafuMarkdownStyling` and leaves the document preview untouched:
/// New York 14/21 prose, tight spacing, square task boxes, quiet code blocks.
///
/// Block spacing is owned by `CanvasNoteReadView`, which renders one block per
/// `Markdown` view, so every top-level block style here has zero outer margin.
struct RafuNoteMarkdownStyling: ViewModifier {
    @Environment(\.rafuTheme) private var theme

    func body(content: Content) -> some View {
        content
            .markdownTheme(.basic)
            .markdownTextStyle {
                FontFamily(.system(.serif))
                FontSize(14)
                ForegroundColor(theme.palette.textPrimary)
            }
            .markdownTextStyle(\.code) {
                FontFamily(.system())
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.9))
                BackgroundColor(theme.palette.chipBackground)
            }
            .markdownTextStyle(\.link) {
                ForegroundColor(theme.palette.info)
            }
            .markdownBlockStyle(\.paragraph) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.3))
                    .markdownMargin(top: 0, bottom: 8)
            }
            .markdownBlockStyle(\.heading1) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.1))
                    .markdownMargin(top: 0, bottom: 6)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(20)
                    }
            }
            .markdownBlockStyle(\.heading2) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.1))
                    .markdownMargin(top: 0, bottom: 6)
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(17)
                    }
            }
            .markdownBlockStyle(\.heading3) { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.16))
                    .markdownMargin(top: 0, bottom: 6)
                    .markdownTextStyle {
                        FontFamily(.system())
                        FontWeight(.semibold)
                        FontSize(14)
                    }
            }
            .markdownBlockStyle(\.blockquote) { configuration in
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(theme.palette.borderStrong).frame(width: 2)
                    configuration.label
                        .fixedSize(horizontal: false, vertical: true)
                        .relativeLineSpacing(.em(0.3))
                        .markdownTextStyle {
                            FontStyle(.italic)
                            ForegroundColor(theme.palette.textSecondary)
                        }
                        .padding(.leading, 12)
                }
                .fixedSize(horizontal: false, vertical: true)
                .markdownMargin(top: 0, bottom: 0)
            }
            .markdownBlockStyle(\.list) { configuration in
                configuration.label.markdownMargin(top: 0, bottom: 0)
            }
            .markdownBlockStyle(\.listItem) { configuration in
                configuration.label.markdownMargin(top: 2, bottom: 0)
            }
            .markdownBlockStyle(\.bulletedListMarker) { _ in
                Text("•")
                    .font(.system(size: 14, design: .serif))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 18, alignment: .leading)
            }
            .markdownBlockStyle(\.numberedListMarker) { configuration in
                Text("\(configuration.itemNumber).")
                    .font(.system(size: 14, design: .serif))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(minWidth: 18, alignment: .leading)
                    .padding(.trailing, 2)
            }
            .markdownBlockStyle(\.taskListMarker) { configuration in
                CanvasNoteTaskCheckbox(isCompleted: configuration.isCompleted)
            }
            .markdownBlockStyle(\.table) { configuration in
                ScrollView(.horizontal) {
                    configuration.label
                        .markdownTableBorderStyle(
                            .init(color: theme.palette.borderSubtle, width: 1)
                        )
                        .markdownTableBackgroundStyle(
                            .alternatingRows(Color.clear, Color.clear, header: Color.clear))
                }
                .markdownMargin(top: 0, bottom: 0)
            }
            .markdownBlockStyle(\.codeBlock) { configuration in
                CanvasNoteCodeBlock(configuration: configuration)
            }
            .tint(theme.palette.info)
            .markdownCodeSyntaxHighlighter(TreeSitterCodeSyntaxHighlighter(theme: theme))
    }
}

extension View {
    /// Applies the compact Canvas note Markdown presentation.
    func rafuNoteMarkdownStyling() -> some View {
        modifier(RafuNoteMarkdownStyling())
    }
}

// MARK: Task items

/// Frames of the task boxes inside one rendered block, in the block's
/// coordinate space. A box finds its place in reading order by counting the
/// boxes above it, because MarkdownUI gives a task marker no index.
@MainActor
final class CanvasNoteTaskFrames {
    private var frames: [UUID: CGRect] = [:]

    func update(_ id: UUID, frame: CGRect) { frames[id] = frame }
    func remove(_ id: UUID) { frames[id] = nil }

    /// Zero-based position of `id` among the boxes, top to bottom.
    func rank(of id: UUID) -> Int? {
        guard let mine = frames[id] else { return nil }
        return frames.values.filter {
            $0.minY < mine.minY || ($0.minY == mine.minY && $0.minX < mine.minX)
        }.count
    }
}

/// What a task box needs from the block that contains it. A main-actor class,
/// so it is `Sendable` and can sit in the environment.
@MainActor
final class CanvasNoteTaskContext {
    let frames: CanvasNoteTaskFrames
    /// Index of the block's first task in the whole note.
    let firstTaskIndex: Int
    let toggle: (Int) -> Void

    init(frames: CanvasNoteTaskFrames, firstTaskIndex: Int, toggle: @escaping (Int) -> Void) {
        self.frames = frames
        self.firstTaskIndex = firstTaskIndex
        self.toggle = toggle
    }
}

extension EnvironmentValues {
    @Entry var canvasNoteTasks: CanvasNoteTaskContext? = nil
}

private nonisolated let noteBlockSpaceName = "canvasNoteBlock"

extension View {
    /// Names the coordinate space task boxes report their frames in.
    func canvasNoteBlockSpace() -> some View {
        coordinateSpace(.named(noteBlockSpaceName))
    }
}

/// A 12 pt rounded square. Checked is an accent fill with a dark check; the
/// text beside it dims instead of being struck through.
struct CanvasNoteTaskCheckbox: View {
    let isCompleted: Bool

    @Environment(\.rafuTheme) private var theme
    @Environment(\.canvasNoteTasks) private var context
    @State private var identity = UUID()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3)
                .fill(isCompleted ? theme.palette.accent : Color.clear)
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(
                    isCompleted ? theme.palette.accent : theme.palette.textMuted, lineWidth: 1)
            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(theme.palette.onAccent)
            }
        }
        .frame(width: 12, height: 12)
        .frame(width: 18, height: 18, alignment: .leading)
        .contentShape(.rect)
        .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.bottom] - 3 }
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(noteBlockSpaceName))
        } action: { frame in
            context?.frames.update(identity, frame: frame)
        }
        .onDisappear { context?.frames.remove(identity) }
        .onTapGesture {
            guard let context, let rank = context.frames.rank(of: identity) else { return }
            context.toggle(context.firstTaskIndex + rank)
        }
        .accessibilityElement()
        .accessibilityLabel(isCompleted ? "Completed task" : "Task")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            guard let context, let rank = context.frames.rank(of: identity) else { return }
            context.toggle(context.firstTaskIndex + rank)
        }
        .help(isCompleted ? "Mark not done" : "Mark done")
    }
}

// MARK: Code blocks

/// A fenced code block: 1 pt border, 6 pt radius, 10 pt padding, horizontal
/// scroll, the language name in `textMuted`, and a copy button on hover.
struct CanvasNoteCodeBlock: View {
    let configuration: CodeBlockConfiguration

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    private var language: String? {
        configuration.language.flatMap { $0.isEmpty ? nil : $0 }
    }

    var body: some View {
        ScrollView(.horizontal) {
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.2))
                .markdownTextStyle {
                    FontFamily(.system())
                    FontFamilyVariant(.monospaced)
                    FontSize(12)
                }
                .padding(10)
                .padding(.top, language == nil ? 0 : 10)
        }
        .background(theme.palette.editorBackground)
        .overlay(alignment: .topLeading) {
            if let language {
                Text(language)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.textMuted)
                    .padding(.leading, 10).padding(.top, 4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button(action: copy) {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
            .help("Copy code")
            .accessibilityLabel("Copy code block")
            .opacity(isHovering ? 1 : 0)
            .animation(isHovering ? RafuMotion.hoverIn : RafuMotion.hoverOut, value: isHovering)
            .padding(2)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6).strokeBorder(theme.palette.borderSubtle, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovering = $0 }
        .contextMenu { Button("Copy Code", action: copy) }
        .markdownMargin(top: 0, bottom: 0)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(configuration.content, forType: .string)
    }
}
