import CoreGraphics
import Foundation

/// Decoded remote images for one Ensemble: a least-recently-used cache in
/// memory only, limited to `byteLimit` bytes counted with the
/// `CanvasImagePool` formula. Each entry carries the grant that allowed it, so
/// revoking the grant drops the image.
@MainActor
final class RemoteImageCache {
    struct Entry {
        let image: CGImage
        let cost: Int
        let grant: RemoteImageGrant
        let host: String
    }

    let byteLimit: Int
    private(set) var usedBytes = 0
    private var entries: [String: Entry] = [:]
    /// Oldest first.
    private var order: [String] = []

    init(byteLimit: Int = RemoteImageFetchPolicy.cacheByteLimit) {
        self.byteLimit = byteLimit
    }

    var count: Int { entries.count }

    /// The `CanvasImagePool` cost of an image: `pixels * (pixels * 4 + 64)`
    /// with the longest side clamped to 64...1,024 (a square is assumed, so a
    /// wide image costs more than it uses).
    nonisolated static func cost(of image: CGImage) -> Int {
        let pixels = min(1_024, max(64, max(image.width, image.height)))
        return pixels * (pixels * 4 + 64)
    }

    /// The image for `key`, marked as most recently used.
    func image(for key: String) -> CGImage? {
        guard let entry = entries[key] else { return nil }
        touch(key)
        return entry.image
    }

    func grant(for key: String) -> RemoteImageGrant? { entries[key]?.grant }

    /// Stores an image, dropping the oldest entries until it fits.
    func insert(
        _ image: CGImage, key: String, grant: RemoteImageGrant, host: String
    ) {
        let cost = Self.cost(of: image)
        guard cost <= byteLimit else { return }
        remove(key)
        while usedBytes + cost > byteLimit, let oldest = order.first {
            remove(oldest)
        }
        entries[key] = Entry(image: image, cost: cost, grant: grant, host: host)
        order.append(key)
        usedBytes += cost
    }

    /// Drops every entry whose grant satisfies `matches`. Returns the count.
    @discardableResult
    func drop(where matches: (RemoteImageGrant) -> Bool) -> Int {
        let doomed = order.filter { key in entries[key].map { matches($0.grant) } ?? false }
        for key in doomed { remove(key) }
        return doomed.count
    }

    @discardableResult
    func dropAll() -> Int {
        let count = entries.count
        entries.removeAll()
        order.removeAll()
        usedBytes = 0
        return count
    }

    private func touch(_ key: String) {
        if let index = order.firstIndex(of: key) {
            order.remove(at: index)
            order.append(key)
        }
    }

    private func remove(_ key: String) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        usedBytes -= entry.cost
        if let index = order.firstIndex(of: key) { order.remove(at: index) }
    }
}
