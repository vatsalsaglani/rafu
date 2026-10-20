import AppKit
import RafuCore
import SwiftUI

/// A read-only, syntax-coloured excerpt of the first lines of a file (review
/// C12). Loaded lazily, only while the card is on screen, and bounded to 40
/// lines and 8 KiB. An open editor buffer, even a dirty one, is the source
/// when there is one.
struct CanvasFileExcerptCard: View {
    @Environment(\.rafuTheme) private var theme
    let card: CanvasCard
    let path: String
    let board: CanvasBoardState
    let session: WorkspaceSession
    var activate: () -> Void = {}
    @State private var lines: [AttributedString] = []
    @State private var notice: String?

    private let lineHeight = CanvasFileExcerptLines.lineHeight
    private let inset = CanvasFileExcerptLines.inset

    var body: some View {
        CanvasFileExcerptLines(
            lines: lines, notice: notice, noticeColor: theme.palette.textSecondary
        )
        .contentShape(.rect)
        .gesture(
            SpatialTapGesture(count: 2).onEnded { value in
                let line = max(1, Int(((value.location.y - inset) / lineHeight).rounded(.down)) + 1)
                session.openFile(atRelativePath: path, selecting: SourceLocation(line: line))
            }
        )
        .simultaneousGesture(TapGesture().onEnded { activate() })
        .help("Double-click to open \(path) in the editor")
        .accessibilityLabel("\(path), first lines")
        .task(id: path) { await load() }
    }

    private func load() async {
        guard let root = session.rootURL else { return }
        let text: String
        if let document = session.openDocuments.first(where: {
            session.relativePath(for: $0.url) == path
        }), let snapshot = document.textSnapshotProvider {
            text = String(decoding: snapshot().utf8.prefix(8 * 1_024), as: UTF8.self)
        } else {
            do { text = try await CanvasPreviewLoader.text(path: path, root: root) } catch {
                notice = error.localizedDescription
                return
            }
        }
        guard !Task.isCancelled else { return }
        notice = nil
        lines = Self.highlighted(CanvasCardSummaryText.excerpt(of: text), path: path, theme: theme)
    }

    private static func highlighted(_ text: String, path: String, theme: RafuTheme)
        -> [AttributedString]
    {
        let url = URL(fileURLWithPath: path)
        let storage = NSTextStorage(string: text)
        SyntaxHighlighter(
            theme: theme, fileExtension: url.pathExtension, fileName: url.lastPathComponent
        ).apply(to: storage)
        var result: [AttributedString] = []
        var location = 0
        for line in text.components(separatedBy: "\n") {
            let length = (line as NSString).length
            result.append(
                attributed(
                    storage.attributedSubstring(from: NSRange(location: location, length: length))))
            location += length + 1
        }
        return result
    }

    private static func attributed(_ source: NSAttributedString) -> AttributedString {
        var output = AttributedString()
        source.enumerateAttribute(
            .foregroundColor, in: NSRange(location: 0, length: source.length)
        ) { value, range, _ in
            var piece = AttributedString(source.attributedSubstring(from: range).string)
            if let color = value as? NSColor { piece.foregroundColor = Color(nsColor: color) }
            output.append(piece)
        }
        return output
    }
}

/// The excerpt's lines, top-aligned and clipped to the size it is given. Up
/// to 40 lines of 15 pt is far taller than most cards, so the frame must not
/// grow to the lines (`canvasCardFill`): the extra lines are cut at the
/// card's bottom edge, and the first line stays under the header.
struct CanvasFileExcerptLines: View {
    static let lineHeight: CGFloat = 15
    static let inset: CGFloat = 10
    let lines: [AttributedString]
    let notice: String?
    var noticeColor: Color = .secondary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(noticeColor)
            } else {
                ForEach(lines.indices, id: \.self) { index in
                    Text(lines[index])
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .frame(height: Self.lineHeight, alignment: .leading)
                }
            }
        }
        .padding(Self.inset)
        .canvasCardFill()
        .clipped()
    }
}

struct CanvasImagePreview: View {
    let path: String
    let session: WorkspaceSession
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(path, systemImage: "photo").lineLimit(2)
                Spacer()
                Button("Open Image") { session.openCanvasFile(path) }
            }
            CanvasImageContent(path: path, session: session, pixels: 1_024)
        }.padding(20)
    }
}

struct CanvasImageContent: View {
    let path: String
    let session: WorkspaceSession
    var pixels = 128
    @State private var retry = 0
    @State private var lease: CanvasImagePool.Lease?
    @State private var notice: String?
    var body: some View {
        Group {
            if let lease {
                Image(nsImage: lease.image).resizable().scaledToFit().accessibilityLabel(path)
            } else if let notice {
                VStack {
                    Label(notice, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                    Button("Retry Image") { retry += 1 }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(path)#\(retry)") {
            await Task.yield()
            guard let root = session.rootURL else { return }
            do {
                lease = try await session.canvasImages.load(path: path, root: root, pixels: pixels)
            } catch is CancellationError {} catch { notice = error.localizedDescription }
        }
        .onDisappear { lease = nil }
    }
}
