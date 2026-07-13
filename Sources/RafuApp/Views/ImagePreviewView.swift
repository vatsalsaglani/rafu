import AppKit
import SwiftUI

/// Native preview for image documents (PNG/JPEG/GIF/SVG/…). Bitmaps are
/// downsampled to a bounded size off the main actor and evicted with the view,
/// keeping per-tab memory small.
struct ImagePreviewView: View {
    let url: URL
    @Environment(\.rafuTheme) private var theme
    @State private var loaded: LoadedImage?
    @State private var failed = false

    private nonisolated static let maxPreviewPixels: CGFloat = 2_560

    var body: some View {
        Group {
            if let loaded {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: loaded.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(
                            maxWidth: min(loaded.image.size.width, 1_400),
                            maxHeight: min(loaded.image.size.height, 1_400)
                        )
                        .padding(24)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay(alignment: .bottom) { infoBar(loaded) }
            } else if failed {
                ContentUnavailableView(
                    "Cannot preview image",
                    systemImage: "photo.badge.exclamationmark",
                    description: Text("The file could not be decoded as an image.")
                )
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.palette.editorBackground)
        .task(id: url) {
            let result = await Self.load(url: url)
            if let result {
                loaded = result
            } else {
                failed = true
            }
        }
    }

    private func infoBar(_ loaded: LoadedImage) -> some View {
        HStack(spacing: 10) {
            let icon = FileIconProvider.fileIcon(named: url.lastPathComponent)
            FileIconView(icon: icon, size: 10)
            Text(url.lastPathComponent)
                .foregroundStyle(theme.palette.textSecondary)
                .lineLimit(1)
            Spacer()
            Text("\(Int(loaded.pixelSize.width)) × \(Int(loaded.pixelSize.height)) px")
                .foregroundStyle(theme.palette.textMuted)
            Text(loaded.formattedFileSize)
                .foregroundStyle(theme.palette.textMuted)
        }
        .font(.caption.monospacedDigit())
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(theme.palette.tabBarBackground.opacity(0.92))
        .overlay(alignment: .top) { Divider().overlay(theme.palette.borderSubtle) }
    }

    nonisolated struct LoadedImage: Sendable {
        let image: NSImage
        let pixelSize: CGSize
        let fileBytes: Int

        var formattedFileSize: String {
            ByteCountFormatter.string(fromByteCount: Int64(fileBytes), countStyle: .file)
        }
    }

    @concurrent
    private static func load(url: URL) async -> LoadedImage? {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if url.pathExtension.lowercased() == "svg" {
            // NSImage renders SVG natively on macOS 11+; vectors stay small.
            guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
            return LoadedImage(image: image, pixelSize: image.size, fileBytes: bytes)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPreviewPixels,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary)
        else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        return LoadedImage(
            image: image,
            pixelSize: CGSize(
                width: pixelWidth > 0 ? pixelWidth : CGFloat(cgImage.width),
                height: pixelHeight > 0 ? pixelHeight : CGFloat(cgImage.height)
            ),
            fileBytes: bytes
        )
    }
}
