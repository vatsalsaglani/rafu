import AppKit
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// The diagram API that UI commands and agent tools share. Every mutation is
/// an ordinary undoable board edit, visible on the board.
@MainActor
enum CanvasDiagramService {
    /// Ranked icon matches across the Common pack and imported packs.
    static func searchIcons(query: String, limit: Int = 20) -> [CanvasServiceIconMatch] {
        CanvasIconPackLibrary.shared.search(query, limit: max(1, min(limit, 100)))
    }

    /// Frames `memberIDs` on the board. Returns the frame card's id, or nil
    /// when the board is not open or no member is on it.
    @discardableResult
    static func createFrame(
        title: String, memberIDs: [CanvasCardID], in boardID: CanvasID, session: WorkspaceSession
    ) -> CanvasCardID? {
        guard let board = session.canvas.boards[boardID] else { return nil }
        return createFrame(title: title, memberIDs: memberIDs, in: board, session: session)
    }

    /// The same, for a caller that already holds the board (agent tools).
    @discardableResult
    static func createFrame(
        title: String, memberIDs: [CanvasCardID], in board: CanvasBoardState,
        session: WorkspaceSession
    ) -> CanvasCardID? {
        do {
            return try board.createFrame(title: title, memberIDs: memberIDs)
        } catch {
            board.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Adds a service icon card. Returns nil when the icon is not in an
    /// installed pack or the board is not open.
    @discardableResult
    static func addServiceIcon(
        _ icon: CanvasServiceIcon, at center: CGPoint? = nil, in boardID: CanvasID,
        session: WorkspaceSession
    ) -> CanvasCardID? {
        guard let board = session.canvas.boards[boardID],
            CanvasIconPackLibrary.shared.entry(for: icon) != nil
        else { return nil }
        do {
            return try board.addServiceIcon(icon, center: center)
        } catch {
            board.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Renders `target` as PNG, PDF or an animated GIF into the workspace's
    /// `exports` folder and returns the file. Never writes outside the workspace.
    static func export(
        boardID: CanvasID, target: CanvasDiagramExportTarget, format: CanvasDiagramExportFormat,
        session: WorkspaceSession, theme: RafuTheme? = nil
    ) async throws -> URL {
        guard let root = session.rootURL else { throw CanvasDiagramError.noWorkspace }
        guard let board = session.canvas.boards[boardID] else {
            throw CanvasDiagramError.boardUnavailable
        }
        await CanvasIconPackLibrary.shared.loadIfNeeded()
        let document = try board.snapshot()
        let nodes = CanvasFrameLayout.nodes(document.cards)
        let ids = CanvasDiagramExportPlan.cardIDs(
            for: target, nodes: nodes, selection: board.selection)
        guard !ids.isEmpty,
            let scene = CanvasDiagramExportScene(document: document, ids: ids, rootURL: root)
        else { throw CanvasDiagramError.nothingToExport }
        let resolvedTheme = theme ?? RafuThemeCatalog.resolvedForCurrentAppearance()
        let data = try await CanvasDiagramRenderer.render(
            scene: scene, board: board, theme: resolvedTheme, format: format)
        let name = CanvasDiagramExportPlan.fileName(
            boardTitle: document.title, targetName: targetName(target, document: document),
            format: format, date: Date())
        return try await CanvasDiagramExportWriter.write(data, fileName: name, root: root)
    }

    private static func targetName(
        _ target: CanvasDiagramExportTarget, document: CanvasDocument
    ) -> String {
        switch target {
        case .board: "board"
        case .selection: "selection"
        case .frame(let id): document.cards.first { $0.id == id }?.title ?? "frame"
        }
    }
}

// MARK: Rendering

@MainActor
enum CanvasDiagramRenderer {
    static func render(
        scene: CanvasDiagramExportScene, board: CanvasBoardState, theme: RafuTheme,
        format: CanvasDiagramExportFormat
    ) async throws -> Data {
        let snapshots = try await CanvasMermaidExportSnapshot.prepare(
            cards: scene.items.map(\.card), theme: MermaidThemeSpec(theme: theme))
        let view = CanvasDiagramExportView(
            scene: scene, board: board, mermaidSnapshots: snapshots
        ).rafuTheme(theme)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(scene.bounds.size)
        switch format {
        case .pdf:
            return try pdf(renderer)
        case .png(let requested):
            renderer.scale = CGFloat(
                CanvasDiagramExportPlan.pngScale(for: scene.bounds, requested: requested))
            guard let image = renderer.cgImage, let raster = CanvasRaster(image) else {
                throw CanvasDiagramError.renderFailed
            }
            return try await CanvasRasterEncoder.png(raster)
        case .gif(let seconds, let fps):
            let scale = CanvasDiagramExportPlan.gifScale(for: scene.bounds)
            renderer.scale = CGFloat(scale)
            guard let image = renderer.cgImage, let raster = CanvasRaster(image) else {
                throw CanvasDiagramError.renderFailed
            }
            return try await CanvasRasterEncoder.gif(
                background: raster, edges: scene.flowEdges,
                plan: CanvasGIFPlan(seconds: seconds, fps: fps), scale: scale,
                dot: CanvasRGBA(theme.palette.accent),
                halo: CanvasRGBA(theme.palette.editorBackground))
        }
    }

    private static func pdf<Content: View>(_ renderer: ImageRenderer<Content>) throws -> Data {
        let data = NSMutableData()
        var failed = true
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(data: data as CFMutableData),
                let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            failed = false
        }
        guard !failed, data.length > 0 else { throw CanvasDiagramError.renderFailed }
        return data as Data
    }
}

/// An sRGB colour as plain numbers, so it can cross into the encoder.
nonisolated struct CanvasRGBA: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    @MainActor
    init(_ color: Color) {
        let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .systemOrange
        self.init(
            red: Double(resolved.redComponent), green: Double(resolved.greenComponent),
            blue: Double(resolved.blueComponent), alpha: Double(resolved.alphaComponent))
    }

    var cgColor: CGColor {
        CGColor(
            srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue),
            alpha: CGFloat(alpha))
    }
}

/// RGBA pixels in memory: a value that can cross actors, unlike `CGImage`.
nonisolated struct CanvasRaster: Sendable {
    let width: Int
    let height: Int
    let pixels: Data

    var bytesPerRow: Int { width * 4 }

    init?(_ image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0,
            let context = Self.context(width: width, height: height)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        self.width = width
        self.height = height
        pixels = Data(bytes: base, count: width * 4 * height)
    }

    static func context(width: Int, height: Int) -> CGContext? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData),
            let space = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// Image encoding off the main actor.
nonisolated enum CanvasRasterEncoder {
    @concurrent
    static func png(_ raster: CanvasRaster) async throws -> Data {
        guard let image = raster.makeImage() else { throw CanvasDiagramError.renderFailed }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.png.identifier as CFString, 1, nil)
        else { throw CanvasDiagramError.renderFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CanvasDiagramError.renderFailed
        }
        return data as Data
    }

    /// One frame per plan step: the static picture with a dot on every link.
    @concurrent
    static func gif(
        background: CanvasRaster, edges: [CanvasGIFFlow.Edge], plan: CanvasGIFPlan,
        scale: Double, dot: CanvasRGBA, halo: CanvasRGBA
    ) async throws -> Data {
        guard let base = background.makeImage() else { throw CanvasDiagramError.renderFailed }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data as CFMutableData, UTType.gif.identifier as CFString, plan.frameCount, nil)
        else { throw CanvasDiagramError.renderFailed }
        let loop: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(destination, loop as CFDictionary)
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: plan.delay,
                kCGImagePropertyGIFUnclampedDelayTime: plan.delay,
            ]
        ]
        let width = background.width
        let height = background.height
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = 4.5 * scale
        let ring = 1.5 * scale
        for frame in 0..<plan.frameCount {
            try Task.checkCancellation()
            guard let context = CanvasRaster.context(width: width, height: height) else {
                throw CanvasDiagramError.renderFailed
            }
            context.draw(base, in: full)
            for item in CanvasGIFFlow.dots(for: edges, progress: plan.progress(ofFrame: frame)) {
                let x = Double(item.point.x) * scale
                let y = Double(height) - Double(item.point.y) * scale
                let outer = CGRect(
                    x: x - radius - ring, y: y - radius - ring, width: 2 * (radius + ring),
                    height: 2 * (radius + ring))
                context.setFillColor(halo.cgColor)
                context.fillEllipse(in: outer)
                context.setFillColor(dot.cgColor)
                context.fillEllipse(
                    in: CGRect(x: x - radius, y: y - radius, width: 2 * radius, height: 2 * radius))
            }
            guard let image = context.makeImage() else { throw CanvasDiagramError.renderFailed }
            CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw CanvasDiagramError.renderFailed
        }
        return data as Data
    }
}

/// Writes exports into `<workspace>/exports/`, creating it when needed.
nonisolated enum CanvasDiagramExportWriter {
    static let folderName = "exports"

    @concurrent
    static func write(_ data: Data, fileName: String, root: URL) async throws -> URL {
        guard CanvasIconPackEntry.isPlainFileName(fileName) else {
            throw CanvasDiagramError.outsideWorkspace
        }
        let folder = root.appending(path: folderName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: fileName, directoryHint: .notDirectory)
        guard CanvasDiagramExportPlan.isInside(folder, root: root),
            CanvasDiagramExportPlan.isInside(url, root: root)
        else { throw CanvasDiagramError.outsideWorkspace }
        try data.write(to: url, options: .atomic)
        return url
    }
}
