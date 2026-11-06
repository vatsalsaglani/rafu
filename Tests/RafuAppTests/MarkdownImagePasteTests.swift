import AppKit
import Foundation
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

// MARK: - Paste policy

private let png = UTType.png.identifier
private let tiff = UTType.tiff.identifier
private let plainText = UTType.utf8PlainText.identifier

private func decide(
    _ types: Set<String>, fileURLs: [URL] = [], text: String? = nil,
    isMarkdown: Bool = true, hasDirectory: Bool = true
) -> MarkdownImagePastePolicy.Decision {
    MarkdownImagePastePolicy.decide(
        typeIdentifiers: types, fileURLs: fileURLs, plainText: text,
        isMarkdown: isMarkdown, hasDirectory: hasDirectory)
}

@Test("PNG-only pasteboard inserts the PNG")
func pastePolicyPNGOnly() {
    #expect(decide([png]) == .insertImageData(typeIdentifier: png))
}

@Test("TIFF-only pasteboard inserts the TIFF; PNG is preferred when both exist")
func pastePolicyTIFF() {
    #expect(decide([tiff]) == .insertImageData(typeIdentifier: tiff))
    #expect(decide([tiff, png]) == .insertImageData(typeIdentifier: png))
}

@Test("Copied image files are copied; any non-image file keeps the text paste")
func pastePolicyFileURLs() {
    let image = URL(fileURLWithPath: "/tmp/shot.png")
    let other = URL(fileURLWithPath: "/tmp/readme.txt")
    let types: Set<String> = [UTType.fileURL.identifier, tiff, plainText]
    #expect(decide(types, fileURLs: [image]) == .copyFiles([image]))
    #expect(decide(types, fileURLs: [image, other]) == .defaultPaste)
    #expect(decide(types, fileURLs: [other]) == .defaultPaste)
}

@Test("Image with real text stays a text paste; image with a lone URL is an image paste")
func pastePolicyStringAndImage() {
    #expect(decide([png, plainText], text: "Quarterly totals\t42") == .defaultPaste)
    #expect(
        decide([png, plainText], text: "https://example.com/cat.png")
            == .insertImageData(typeIdentifier: png))
    #expect(decide([png, plainText], text: "  \n") == .insertImageData(typeIdentifier: png))
}

@Test("Empty or text-only pasteboards keep the default paste")
func pastePolicyEmpty() {
    #expect(decide([]) == .defaultPaste)
    #expect(decide([plainText], text: "hello") == .defaultPaste)
}

@Test("Non-Markdown and untitled documents keep the default paste")
func pastePolicyDocumentGate() {
    #expect(decide([png], isMarkdown: false) == .defaultPaste)
    #expect(decide([png], hasDirectory: false) == .defaultPaste)
}

@Test("Insertion text adds one line per image and a newline mid-line")
func insertionText() {
    #expect(
        MarkdownImagePastePolicy.insertionText(relativePaths: ["assets/a.png"], atLineStart: true)
            == "![Image](assets/a.png)")
    #expect(
        MarkdownImagePastePolicy.insertionText(
            relativePaths: ["assets/a.png", "assets/b.png"], atLineStart: false)
            == "\n![Image](assets/a.png)\n![Image](assets/b.png)")
}

// MARK: - Folder setting

@Test("Folder templates resolve relative paths and the ${name} token")
func folderTemplateResolution() {
    #expect(MarkdownImageFolder.resolve(template: "assets", documentStem: "plan") == "assets")
    #expect(
        MarkdownImageFolder.resolve(template: "${name}.assets", documentStem: "plan")
            == "plan.assets")
    #expect(
        MarkdownImageFolder.resolve(template: "./docs//img/", documentStem: "plan") == "docs/img")
}

@Test("Folder templates refuse empty, absolute, home, and parent paths")
func folderTemplateRefusals() {
    for template in ["", "  ", "/tmp/x", "~/x", "../x", "a/../b", ".", "${name}"] {
        #expect(MarkdownImageFolder.resolve(template: template, documentStem: "..") == nil)
    }
    #expect(!MarkdownImageFolder.isValid(template: "../assets"))
    #expect(MarkdownImageFolder.isValid(template: "${name}.assets"))
}

// MARK: - Asset writer

private struct Fixture {
    let directory: URL
    let document: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "markdown-image-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        document = directory.appending(path: "Plan Notes.md")
        try Data("# Plan\n".utf8).write(to: document)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// A small RGBA PNG, or a 1-bit grayscale one for very large sizes so the
/// pixel-cap test stays cheap in memory (8,000 × 5,001 is about 5 MB).
private func pngData(width: Int = 4, height: Int = 3) throws -> Data {
    let large = width * height > 1_000_000
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: large ? 1 : 8, samplesPerPixel: large ? 1 : 4, hasAlpha: !large,
            isPlanar: false, colorSpaceName: large ? .deviceWhite : .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private let fixedWriter = MarkdownImageAssetWriter(now: {
    Date(timeIntervalSince1970: 1_800_000_000)
})

@Test("Pasted PNG data lands in assets/ with a unique name and a resolvable link")
func writerStoresPastedPNG() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let data = try pngData()
    let first = try await fixedWriter.store(
        .imageData(data), for: fixture.document, folderTemplate: "assets")
    let second = try await fixedWriter.store(
        .imageData(data), for: fixture.document, folderTemplate: "assets")
    #expect(first.hasPrefix("assets/pasted-image-"))
    #expect(first != second)
    #expect(second.hasSuffix("%202.png"))
    for path in [first, second] {
        let reference = MarkdownImageReference.resolve(
            source: path, relativeTo: fixture.document.deletingLastPathComponent())
        guard case .local(let url) = reference else {
            Issue.record("\(path) did not resolve as local")
            continue
        }
        #expect(try Data(contentsOf: url) == data)
    }
    let leftovers = try FileManager.default.contentsOfDirectory(
        atPath: fixture.directory.appending(path: "assets").path
    ).filter { $0.hasPrefix(".") }
    #expect(leftovers.isEmpty)
}

@Test("TIFF data is stored as PNG")
func writerConvertsTIFF() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let tiffData = try #require(NSBitmapImageRep(data: try pngData())?.tiffRepresentation)
    let path = try await fixedWriter.store(
        .imageData(tiffData), for: fixture.document, folderTemplate: "assets")
    let url = fixture.directory.appending(path: path.removingPercentEncoding ?? path)
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    #expect(CGImageSourceGetType(source) as String? == UTType.png.identifier)
}

@Test("The ${name} token gives a per-document folder and names are percent-encoded")
func writerNameTokenAndEncoding() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let source = fixture.directory.appending(path: "my shot (1).png")
    try pngData().write(to: source)
    let path = try await fixedWriter.store(
        .fileURL(source), for: fixture.document, folderTemplate: "${name}.assets")
    #expect(path == "Plan%20Notes.assets/my%20shot%20%281%29.png")
    let reference = MarkdownImageReference.resolve(
        source: path, relativeTo: fixture.document.deletingLastPathComponent())
    guard case .local(let url) = reference else {
        Issue.record("\(path) did not resolve as local")
        return
    }
    #expect(
        url.standardizedFileURL.path
            == fixture.directory.appending(path: "Plan Notes.assets/my shot (1).png")
            .standardizedFileURL.path)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test("Invalid folders are refused before anything is written")
func writerRefusesInvalidFolders() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let data = try pngData()
    for template in ["../escape", "/tmp/escape"] {
        await #expect(throws: MarkdownImageAssetError.invalidFolder(template)) {
            try await fixedWriter.store(
                .imageData(data), for: fixture.document, folderTemplate: template)
        }
    }
}

@Test("A symlinked folder that leaves the document directory is refused")
func writerRefusesSymlinkEscape() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let outside = FileManager.default.temporaryDirectory
        .appending(path: "markdown-image-outside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: outside) }
    try FileManager.default.createSymbolicLink(
        at: fixture.directory.appending(path: "assets"), withDestinationURL: outside)
    let data = try pngData()
    await #expect(throws: MarkdownImageAssetError.folderOutsideDocument) {
        try await fixedWriter.store(
            .imageData(data), for: fixture.document, folderTemplate: "assets/deeper")
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
}

@Test("Over-size data, over-size pixel counts, and non-image files are refused")
func writerEnforcesCaps() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let huge = try pngData(width: 8_000, height: 5_001)
    await #expect(throws: MarkdownImageAssetError.tooManyPixels(width: 8_000, height: 5_001)) {
        try await fixedWriter.store(
            .imageData(huge), for: fixture.document, folderTemplate: "assets")
    }
    var padded = try pngData()
    padded.append(Data(count: MarkdownImagePastePolicy.maximumImageBytes))
    let paddedCount = padded.count
    await #expect(
        throws: MarkdownImageAssetError.tooLarge(
            bytes: paddedCount, limit: MarkdownImagePastePolicy.maximumImageBytes)
    ) {
        try await fixedWriter.store(
            .imageData(padded), for: fixture.document, folderTemplate: "assets")
    }
    let text = fixture.directory.appending(path: "notes.txt")
    try Data("hi".utf8).write(to: text)
    await #expect(throws: MarkdownImageAssetError.notAnImageFile("notes.txt")) {
        try await fixedWriter.store(
            .fileURL(text), for: fixture.document, folderTemplate: "assets")
    }
}

@Test("SVG files are copied as they are")
func writerCopiesSVG() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let svg = fixture.directory.appending(path: "logo.svg")
    let body = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"/>"#.utf8)
    try body.write(to: svg)
    let path = try await fixedWriter.store(
        .fileURL(svg), for: fixture.document, folderTemplate: "assets")
    #expect(path == "assets/logo.svg")
    #expect(try Data(contentsOf: fixture.directory.appending(path: "assets/logo.svg")) == body)
}
