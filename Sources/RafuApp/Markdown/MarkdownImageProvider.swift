import AppKit
import MarkdownUI
import SwiftUI

/// Classifies a Markdown image `source` string once resolved against an
/// optional base URL, mirroring how MarkdownUI's `ImageView` resolves an
/// image reference internally (`URL(string:relativeTo:)`, see
/// `ImageView.url` in the pinned `swift-markdown-ui` checkout) before ever
/// calling `ImageProvider.makeImage(url:)`. Exposed as a pure, `Sendable`
/// value so that resolution behavior — relative paths, absolute paths,
/// `file://`, `http`/`https`, and malformed sources — has explicit unit
/// coverage independent of the SwiftUI view tree.
nonisolated enum MarkdownImageReference: Sendable, Equatable {
    case local(URL)
    case remote(URL)
    case invalid

    static func resolve(source: String, relativeTo base: URL?) -> MarkdownImageReference {
        // `.absoluteURL` normalizes away the `relativeString`/`baseURL` pair
        // Foundation keeps internally for a URL built with `relativeTo:`, so
        // two references that resolve to the same location compare equal
        // regardless of whether they were built relative or absolute.
        guard let resolved = URL(string: source, relativeTo: base) else {
            return .invalid
        }
        let url = resolved.absoluteURL
        if url.isFileURL {
            return .local(url)
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return .remote(url)
        default:
            return .invalid
        }
    }
}

/// A Markdown image provider that decodes `file://` images locally, bounded
/// and off the main actor like `ImagePreviewView.load`, and defers every
/// other URL (`http`/`https`, anything unresolved) to MarkdownUI's built-in
/// `DefaultImageProvider` so remote images keep loading exactly as before.
///
/// MarkdownUI resolves an image's Markdown `source` string against
/// `imageBaseURL` (`URL(string:relativeTo:)`) *before* calling
/// `makeImage(url:)`, so by the time this provider sees a URL it is already
/// absolute; `MarkdownImageReference.resolve` re-derives the same
/// classification from that resolved URL's own `absoluteString` so both the
/// provider and its tests share one code path.
struct LocalFileImageProvider: MarkdownUI.ImageProvider {
    @ViewBuilder
    func makeImage(url: URL?) -> some View {
        if let url {
            switch MarkdownImageReference.resolve(source: url.absoluteString, relativeTo: nil) {
            case .local(let fileURL):
                LocalMarkdownImageLoader(url: fileURL)
            case .remote, .invalid:
                DefaultImageProvider.default.makeImage(url: url)
            }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

/// Loads and decodes a local `file://` image off the main actor, bounded to
/// `maxDecodedPixelSize` the same way `ImagePreviewView.load` bounds its
/// full-tab preview, then displays it resizable/aspect-fit up to
/// `maxDisplayWidth` so a large local image never forces the Markdown
/// preview column wider than its own layout. Falls back to a placeholder
/// glyph (never the raw source path) on decode failure so a missing or
/// corrupt local image degrades quietly instead of breaking the render.
private struct LocalMarkdownImageLoader: View {
    let url: URL

    @State private var image: NSImage?
    @State private var failed = false

    private static let maxDisplayWidth: CGFloat = 720
    private nonisolated static let maxDecodedPixelSize: CGFloat = 2_560

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: min(image.size.width, Self.maxDisplayWidth))
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Image failed to load")
            } else {
                Color.clear.frame(width: 0, height: 0)
            }
        }
        .task(id: url) {
            let loaded = await Self.load(url: url)
            if let loaded {
                image = loaded.image
            } else {
                failed = true
            }
        }
    }

    /// `Sendable` wrapper so a decoded `NSImage` can cross back from the
    /// `@concurrent` loader onto the main actor.
    nonisolated struct LoadedLocalImage: Sendable {
        let image: NSImage
    }

    /// Decodes `url` off the main actor. Raster formats are downsampled to
    /// `maxDecodedPixelSize` via `CGImageSourceCreateThumbnailAtIndex` — the
    /// same bound `ImagePreviewView.load` uses — and SVG renders natively
    /// via `NSImage(contentsOf:)`. Returns `nil` on any decode failure.
    @concurrent
    private static func load(url: URL) async -> LoadedLocalImage? {
        if url.pathExtension.lowercased() == "svg" {
            guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
            return LoadedLocalImage(image: image)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodedPixelSize,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return nil
        }
        let image = NSImage(
            cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        return LoadedLocalImage(image: image)
    }
}
