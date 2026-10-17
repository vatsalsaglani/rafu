import AppKit
import Darwin
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

@Suite("Canvas bounded repository cards")
@MainActor
struct CanvasRepositoryCardTests {
    @Test("File previews reject paths that leave the workspace and special files without blocking")
    func scopedRegularFiles() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let root = folder.appending(path: "workspace")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outside = folder.appending(path: "outside.txt")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link"), withDestinationURL: outside)
        await #expect(throws: CanvasError.invalidPath) {
            try await CanvasPreviewLoader.text(path: "link", root: root)
        }
        let fifo = root.appending(path: "pipe")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        await #expect(throws: CanvasError.unavailable) {
            try await CanvasPreviewLoader.text(path: "pipe", root: root)
        }
        try Data(String(repeating: "x", count: 16 * 1_024).utf8).write(
            to: root.appending(path: "large.txt"))
        let prefix = try await CanvasPreviewLoader.text(path: "large.txt", root: root)
        #expect(prefix.utf8.count == 8 * 1_024)
    }

    @Test("Image decode has bounded RGBA dimensions and failed loads release their reservation")
    func boundedImage() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try #require(
            CGContext(
                data: nil, width: 256, height: 128,
                bitsPerComponent: 8, bytesPerRow: 256 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: root.appending(path: "image.png"))
        let thumbnail = try await CanvasPreviewLoader.image(
            path: "image.png", root: root, pixels: 128)
        #expect(thumbnail.width <= 128 && thumbnail.height <= 128)
        #expect(thumbnail.bitsPerComponent == 8 && thumbnail.bitsPerPixel == 32)
        let pool = CanvasImagePool()
        do {
            _ = try await pool.load(path: "missing.png", root: root, pixels: 1_024)
            Issue.record("A missing image must fail")
        } catch { #expect(pool.reservedBytes == 0) }
    }

    @Test("A full board keeps layout undo and relationships within its saved bounds")
    func fullBoard() throws {
        var document = CanvasDocument(title: "100 cards")
        document.cards = (0..<CanvasLimits.cards).map { index in
            CanvasCard(title: "Card \(index)", content: .file(path: "file-\(index).swift"))
        }
        document.connections = (0..<CanvasLimits.connections).map { index in
            CanvasConnection(
                from: document.cards[index % document.cards.count].id,
                to: document.cards[(index + 1) % document.cards.count].id, label: "Link \(index)")
        }
        let board = CanvasBoardState(document: document)
        board.selection = Set(board.cards.map(\.id))
        try board.arrange()
        let arranged = board.cards.map(\.rect)
        try board.alignSelection(leading: true)
        board.performUndo()
        #expect(board.cards.map(\.rect) == arranged)
        #expect(board.connections.count == CanvasLimits.connections)
        #expect(try JSONEncoder().encode(board.snapshot()).count < CanvasLimits.documentBytes)
    }
}
