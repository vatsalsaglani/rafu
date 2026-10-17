import AppKit

/// Counts live image leases, including overlapping presentations during moves.
/// There is no unbounded thumbnail cache behind offscreen cards.
final class CanvasImagePool {
    static let byteLimit = 8 * 1_024 * 1_024
    private(set) var reservedBytes = 0

    func load(path: String, root: URL, pixels: Int) async throws -> Lease {
        let pixels = min(1_024, max(64, pixels))
        let cost = pixels * (pixels * 4 + 64)
        guard reservedBytes + cost <= Self.byteLimit else { throw CanvasError.capacity }
        reservedBytes += cost
        do {
            let image = try await CanvasPreviewLoader.image(path: path, root: root, pixels: pixels)
            try Task.checkCancellation()
            return Lease(image: NSImage(cgImage: image, size: .zero), pool: self, cost: cost)
        } catch {
            reservedBytes -= cost
            throw error
        }
    }

    final class Lease {
        let image: NSImage
        private weak var pool: CanvasImagePool?
        private let cost: Int
        init(image: NSImage, pool: CanvasImagePool, cost: Int) {
            self.image = image
            self.pool = pool
            self.cost = cost
        }
        isolated deinit { pool?.reservedBytes -= cost }
    }
}
