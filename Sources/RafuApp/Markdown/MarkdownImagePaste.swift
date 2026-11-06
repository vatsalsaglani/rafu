import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One image the user pasted or dropped into a saved Markdown document.
/// Carries only immutable bytes or a file URL, so it crosses into the
/// `@concurrent` writer safely.
nonisolated enum MarkdownImageSource: Sendable, Equatable {
    /// Raw image bytes from the pasteboard (`public.png` or `public.tiff`).
    /// The writer stores them as PNG.
    case imageData(Data)
    /// An image file copied in Finder or dropped from it. The writer copies
    /// the file as it is (format and name kept, name made unique).
    case fileURL(URL)
}

/// Pure decision rules for pasting and dropping images into a Markdown
/// document. Independent of any live `NSPasteboard`, so tests cover every
/// branch with plain values. Policy adapted from Cider's note editor (see
/// `docs/references/markdown-image-paste.md`).
nonisolated enum MarkdownImagePastePolicy {
    enum Decision: Equatable, Sendable {
        /// Read the pasteboard data of this type and store it as a PNG.
        case insertImageData(typeIdentifier: String)
        /// Copy these image files beside the document.
        case copyFiles([URL])
        /// Not an image paste: run the ordinary text paste.
        case defaultPaste
    }

    /// Byte cap for PNG data and for a copied image file (Cider's 25 MiB).
    static let maximumImageBytes = 25 * 1_024 * 1_024
    /// TIFF is uncompressed; a 5K Retina screenshot is about 59 MB as TIFF.
    static let maximumTIFFBytes = 64 * 1_024 * 1_024
    /// Pixel cap read from the image header before any decode (Cider's 40 MP).
    static let maximumPixels = 40_000_000

    /// Raw image data types read from the pasteboard, in order of preference.
    static let imageDataTypeIdentifiers = [UTType.png.identifier, UTType.tiff.identifier]

    static func maximumBytes(forTypeIdentifier identifier: String) -> Int {
        identifier == UTType.tiff.identifier ? maximumTIFFBytes : maximumImageBytes
    }

    /// Decides what a paste does.
    ///
    /// - File URLs come first: when every URL is an image file they are
    ///   copied; any non-image file keeps the ordinary paste (its path text).
    /// - Raw image data wins next, unless the pasteboard also carries real
    ///   text. Office apps and some editors put a picture of copied text
    ///   beside the text itself; that paste must stay text. A single URL as
    ///   the only text is a browser "Copy Image", so the image wins.
    static func decide(
        typeIdentifiers: Set<String>,
        fileURLs: [URL],
        plainText: String?,
        isMarkdown: Bool,
        hasDirectory: Bool
    ) -> Decision {
        guard isMarkdown, hasDirectory else { return .defaultPaste }
        if !fileURLs.isEmpty {
            return areAllImageFiles(fileURLs) ? .copyFiles(fileURLs) : .defaultPaste
        }
        guard let imageType = imageDataTypeIdentifiers.first(where: typeIdentifiers.contains)
        else { return .defaultPaste }
        if let text = plainText?.trimmingCharacters(in: .whitespacesAndNewlines),
            !text.isEmpty, !isSingleURL(text)
        {
            return .defaultPaste
        }
        return .insertImageData(typeIdentifier: imageType)
    }

    /// Whether a file drop goes into the Markdown text instead of opening
    /// the files as editors: only when the editor accepts images and every
    /// dropped URL is an image file. A mixed drop keeps the open behavior.
    static func acceptsDrop(fileURLs: [URL], canAcceptImages: Bool) -> Bool {
        canAcceptImages && areAllImageFiles(fileURLs)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, !url.hasDirectoryPath,
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
        else { return false }
        return type.conforms(to: .image)
    }

    static func areAllImageFiles(_ urls: [URL]) -> Bool {
        !urls.isEmpty && urls.allSatisfy(isImageFile)
    }

    /// The Markdown text to insert for stored images: one image reference
    /// per line, with a leading newline when the caret is not at the start
    /// of a line.
    static func insertionText(relativePaths: [String], atLineStart: Bool) -> String {
        let lines = relativePaths.map { "![Image](\($0))" }.joined(separator: "\n")
        return atLineStart ? lines : "\n" + lines
    }

    private static func isSingleURL(_ text: String) -> Bool {
        guard !text.contains(where: \.isWhitespace), let url = URL(string: text),
            let scheme = url.scheme?.lowercased()
        else { return false }
        return ["http", "https", "file"].contains(scheme)
    }
}

/// The user's "Markdown image folder" setting: a folder path relative to the
/// document's directory. `${name}` expands to the document's file name
/// without its extension, so `${name}.assets` gives Cider's per-note layout.
nonisolated enum MarkdownImageFolder {
    static let defaultsKey = "markdownImageFolder"
    static let defaultTemplate = "assets"
    static let nameToken = "${name}"

    /// The relative folder path for `template`, or `nil` when the template
    /// is empty, absolute, home-relative, or contains `..` (before or after
    /// `${name}` expands). `.` components and repeated slashes are dropped.
    static func resolve(template: String, documentStem: String) -> String? {
        let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else { return nil }
        let expanded = trimmed.replacingOccurrences(of: nameToken, with: documentStem)
        let components = expanded.split(separator: "/").filter { $0 != "." }
        guard !components.isEmpty,
            !components.contains(".."),
            !expanded.contains(where: { $0.isNewline || $0 == "\0" })
        else { return nil }
        return components.joined(separator: "/")
    }

    static func isValid(template: String) -> Bool {
        resolve(template: template, documentStem: "note") != nil
    }

    /// The template stored in user defaults, or the default when unset or
    /// blank.
    static func storedTemplate(in defaults: UserDefaults = .standard) -> String {
        let stored = defaults.string(forKey: defaultsKey) ?? ""
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultTemplate : stored
    }
}

nonisolated enum MarkdownImageAssetError: LocalizedError, Equatable {
    case invalidFolder(String)
    case folderOutsideDocument
    case folderIsNotDirectory(String)
    case tooLarge(bytes: Int, limit: Int)
    case tooManyPixels(width: Int, height: Int)
    case unreadableImage
    case notAnImageFile(String)

    var errorDescription: String? {
        switch self {
        case .invalidFolder(let template):
            "The Markdown image folder “\(template)” is not valid. Use a relative folder such as assets or ${name}.assets, without “..”."
        case .folderOutsideDocument:
            "The Markdown image folder resolves to a location outside this document’s folder. Rafu did not save the image."
        case .folderIsNotDirectory(let name):
            "“\(name)” exists beside this document but is not a folder. Rafu did not save the image."
        case .tooLarge(let bytes, let limit):
            "This image is \(bytes / 1_048_576) MiB. The limit for a pasted image is \(limit / 1_048_576) MiB."
        case .tooManyPixels(let width, let height):
            "This image is \(width) × \(height) pixels. The limit for a pasted image is 40 megapixels."
        case .unreadableImage:
            "Rafu could not read the pasted image."
        case .notAnImageFile(let name):
            "“\(name)” is not an image file."
        }
    }
}

/// Stores a pasted or dropped image beside a saved Markdown document and
/// returns the percent-encoded relative path to put in `![](…)`.
///
/// All file system work and image decoding run off the main actor. The
/// writer never overwrites: names are made unique and the final step is an
/// exclusive rename. The destination folder must resolve (symlinks included)
/// inside the document's own directory.
nonisolated struct MarkdownImageAssetWriter: Sendable {
    var now: @Sendable () -> Date = { Date() }

    @concurrent
    func store(
        _ source: MarkdownImageSource, for documentURL: URL, folderTemplate: String
    ) async throws -> String {
        try Task.checkCancellation()
        let documentDirectory = documentURL.deletingLastPathComponent()
        let stem = documentURL.deletingPathExtension().lastPathComponent
        guard
            let folder = MarkdownImageFolder.resolve(
                template: folderTemplate, documentStem: stem)
        else { throw MarkdownImageAssetError.invalidFolder(folderTemplate) }
        let directory = try Self.prepareDirectory(folder, in: documentDirectory)
        try Task.checkCancellation()

        let storedName: String
        switch source {
        case .imageData(let data):
            let png = try Self.validatedPNG(from: data)
            try Task.checkCancellation()
            storedName = try Self.writeExclusively(
                png, preferredName: Self.pastedImageName(at: now()), in: directory)
        case .fileURL(let url):
            let data = try Self.validatedImageFile(url)
            try Task.checkCancellation()
            storedName = try Self.writeExclusively(
                data, preferredName: url.lastPathComponent, in: directory)
        }
        return Self.markdownPath(folder: folder, fileName: storedName)
    }

    // MARK: - Folder

    /// Creates `folder` under `documentDirectory` one component at a time and
    /// checks after every step that the real path stays inside the document
    /// directory, so a symlinked component never leads the writer elsewhere
    /// and nothing is created through such a link.
    static func prepareDirectory(_ folder: String, in documentDirectory: URL) throws -> URL {
        guard let rootPath = canonicalPath(documentDirectory) else {
            throw MarkdownImageAssetError.folderOutsideDocument
        }
        var current = documentDirectory
        for component in folder.split(separator: "/") {
            current = current.appending(path: String(component), directoryHint: .isDirectory)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: current.path, isDirectory: &isDirectory) {
                guard let path = canonicalPath(current), path.hasPrefix(rootPath + "/") else {
                    throw MarkdownImageAssetError.folderOutsideDocument
                }
                guard isDirectory.boolValue else {
                    throw MarkdownImageAssetError.folderIsNotDirectory(String(component))
                }
            } else {
                try FileManager.default.createDirectory(
                    at: current, withIntermediateDirectories: false)
                guard let path = canonicalPath(current), path.hasPrefix(rootPath + "/") else {
                    throw MarkdownImageAssetError.folderOutsideDocument
                }
            }
        }
        return current
    }

    static func canonicalPath(_ url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { path -> String? in
            guard let path, let resolved = realpath(path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    // MARK: - Image validation

    /// PNG bytes for pasted image data. Size and pixel caps are checked on
    /// the header before any full decode. PNG input is kept as it is; other
    /// formats (TIFF) are decoded once and encoded as PNG.
    static func validatedPNG(from data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let sourceType = CGImageSourceGetType(source) as String?
        else { throw MarkdownImageAssetError.unreadableImage }
        let limit = MarkdownImagePastePolicy.maximumBytes(forTypeIdentifier: sourceType)
        guard data.count <= limit else {
            throw MarkdownImageAssetError.tooLarge(bytes: data.count, limit: limit)
        }
        try checkPixelCount(of: source)
        if sourceType == UTType.png.identifier { return data }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw MarkdownImageAssetError.unreadableImage
        }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { throw MarkdownImageAssetError.unreadableImage }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw MarkdownImageAssetError.unreadableImage
        }
        return output as Data
    }

    /// Bytes of an image file to copy. Refuses non-image files, non-regular
    /// files, and files over the byte cap. Bitmap files also pass the pixel
    /// cap; SVG has no pixel size and is accepted on its byte size.
    static func validatedImageFile(_ url: URL) throws -> Data {
        guard MarkdownImagePastePolicy.isImageFile(url) else {
            throw MarkdownImageAssetError.notAnImageFile(url.lastPathComponent)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw MarkdownImageAssetError.notAnImageFile(url.lastPathComponent)
        }
        let limit = MarkdownImagePastePolicy.maximumImageBytes
        if let size = values.fileSize, size > limit {
            throw MarkdownImageAssetError.tooLarge(bytes: size, limit: limit)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else {
            throw MarkdownImageAssetError.tooLarge(bytes: data.count, limit: limit)
        }
        let isSVG =
            UTType(filenameExtension: url.pathExtension.lowercased())?.conforms(to: .svg) == true
        if !isSVG, let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        {
            try checkPixelCount(of: source)
        }
        return data
    }

    private static func checkPixelCount(of source: CGImageSource) throws {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { throw MarkdownImageAssetError.unreadableImage }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixels <= MarkdownImagePastePolicy.maximumPixels else {
            throw MarkdownImageAssetError.tooManyPixels(width: width, height: height)
        }
    }

    // MARK: - Writing

    /// Writes `data` to a hidden temporary file in `directory`, then renames
    /// it to a unique name with `RENAME_EXCL`, so the final file appears
    /// whole and an existing file is never replaced. Returns the final name.
    static func writeExclusively(
        _ data: Data, preferredName: String, in directory: URL
    ) throws -> String {
        let temporary = directory.appending(
            path: ".rafu-image-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try data.write(to: temporary, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for _ in 0..<16 {
            let destination = WorkspaceFileService.uniqueDestination(
                forName: preferredName, in: directory)
            let result = temporary.withUnsafeFileSystemRepresentation { from in
                destination.withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return Int32(-1) }
                    return renamex_np(from, to, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 { return destination.lastPathComponent }
            guard errno == EEXIST else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        throw POSIXError(.EEXIST)
    }

    static func pastedImageName(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "pasted-image-\(formatter.string(from: date)).png"
    }

    /// `folder/fileName` with every component percent-encoded down to
    /// unreserved ASCII, so spaces, parentheses, and non-ASCII names stay a
    /// valid Markdown link destination and resolve back to the stored file.
    static func markdownPath(folder: String, fileName: String) -> String {
        let allowed = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return (folder.split(separator: "/").map(String.init) + [fileName])
            .map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
    }
}
