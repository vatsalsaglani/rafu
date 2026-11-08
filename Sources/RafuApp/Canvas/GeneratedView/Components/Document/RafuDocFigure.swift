import JSONRenderClient
import JSONRenderStandardCatalog
import SwiftUI

/// `Figure`: a local image with an optional title and caption. It never
/// fetches: an `https` source is named, not loaded, whatever the remote-image
/// setting says (ADR 0034). A local file loads only from inside
/// `\.jrLocalImageRoots`; with no roots set (a generated view) nothing loads.
@JRComponent(
    "Figure",
    description:
        "A local image with a caption. src is a local file path or file URL. A web (https) src is only named, never fetched; use Image for a web image in a card."
)
nonisolated struct RafuDocFigure: View {
    @JRProp(description: "Local image path or file URL.") var src: String?
    @JRProp(description: "Optional caption below the image.") var caption: String?
    @JRProp(description: "Optional title above the image.") var title: String?

    var body: some View {
        RafuDocFigureView(src: src, caption: caption, title: title)
    }

    enum Source: Equatable {
        case local(URL)
        case remote(String)
        case blocked
        case missing
    }

    static func source(_ src: String?, roots: [URL]) -> Source {
        guard let src, !src.trimmingCharacters(in: .whitespaces).isEmpty else { return .missing }
        // A bare path has no scheme: read it as a file path.
        let reference = src.hasPrefix("/") ? URL(filePath: src).absoluteString : src
        switch MarkdownImageReference.resolve(source: reference, relativeTo: nil) {
        case .local(let url): return isInside(url, roots: roots) ? .local(url) : .blocked
        case .remote(let url): return .remote(url.absoluteString)
        case .invalid: return .missing
        }
    }

    /// True when `url`, after symbolic links resolve, lies inside a root.
    static func isInside(_ url: URL, roots: [URL]) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return roots.contains { root in
            let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return target.count >= base.count && Array(target.prefix(base.count)) == base
        }
    }
}

struct RafuDocFigureView: View {
    let src: String?
    let caption: String?
    let title: String?

    @Environment(\.rafuTheme) private var theme
    @Environment(\.jrLocalImageRoots) private var roots

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            switch RafuDocFigure.source(src, roots: roots) {
            case .local(let url):
                LocalFileImageProvider().makeImage(url: url)
                    .accessibilityLabel(title ?? caption ?? url.lastPathComponent)
            case .remote(let url):
                note("Remote image not loaded: \(url)", systemImage: "network.slash")
            case .blocked:
                note("Image is outside the allowed folders", systemImage: "lock")
            case .missing:
                note("Image has no local source", systemImage: "photo")
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

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12))
            .foregroundStyle(theme.palette.textSecondary)
    }
}
