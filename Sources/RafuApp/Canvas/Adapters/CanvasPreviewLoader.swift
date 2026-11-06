import Darwin
import Foundation
import ImageIO

nonisolated enum CanvasPreviewLoader {
    @concurrent static func relativePath(for url: URL, root: URL) async throws -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let target = url.resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(base.path + "/") else { throw CanvasError.invalidPath }
        let path = String(target.path.dropFirst(base.path.count + 1))
        _ = try checkedURL(path: path, root: base)
        return path
    }

    static func checkedURL(path: String, root: URL) throws -> URL {
        guard CanvasCardContent.validRelativePath(path) else { throw CanvasError.invalidPath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appending(path: path).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw CanvasError.invalidPath }
        return url
    }

    /// The first `limit` bytes of a regular file inside `root`, as UTF-8. The
    /// limit is clamped to `CanvasLimits.markdownPreviewBytes`; the default
    /// stays 8 KiB for the plain excerpt. A cut inside a multi-byte character
    /// decodes to one replacement character at the end.
    @concurrent static func text(path: String, root: URL, limit: Int = 8 * 1_024) async throws
        -> String
    {
        let url = try checkedURL(path: path, root: root)
        let data = try read(
            url, limit: min(max(0, limit), CanvasLimits.markdownPreviewBytes), prefixOnly: true)
        guard !data.contains(0) else { throw CanvasError.unavailable }
        return String(decoding: data, as: UTF8.self)
    }

    @concurrent static func image(path: String, root: URL, pixels: Int = 1_024) async throws
        -> CGImage
    {
        try await CanvasImageDecodeQueue.shared.load(path: path, root: root, pixels: pixels)
    }

    fileprivate static func decodeImage(path: String, root: URL, pixels: Int) throws -> CGImage {
        let data = try read(checkedURL(path: path, root: root), limit: 16 * 1_024 * 1_024)
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: min(1_024, max(64, pixels)),
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { throw CanvasError.unavailable }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw CanvasError.unavailable }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bounded = context.makeImage() else { throw CanvasError.unavailable }
        try Task.checkCancellation()
        return bounded
    }

    private static func read(_ url: URL, limit: Int, prefixOnly: Bool = false) throws -> Data {
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw CanvasError.unavailable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            prefixOnly || info.st_size <= limit
        else { throw CanvasError.unavailable }
        try Task.checkCancellation()
        let data = try handle.read(upToCount: limit + (prefixOnly ? 0 : 1)) ?? Data()
        guard data.count <= limit else { throw CanvasError.unavailable }
        try Task.checkCancellation()
        return data
    }
}

/// Serialize bounded decodes so 100 visible cards cannot each retain a
/// separate 16 MiB encoded input at the same time.
private actor CanvasImageDecodeQueue {
    static let shared = CanvasImageDecodeQueue()
    func load(path: String, root: URL, pixels: Int) throws -> CGImage {
        try CanvasPreviewLoader.decodeImage(path: path, root: root, pixels: pixels)
    }
}
