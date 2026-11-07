import CoreGraphics
import Foundation
import Testing

@testable import RafuApp

@Suite("Remote image cache")
@MainActor
struct RemoteImageCacheTests {
    private let board = CanvasID()

    @Test("The cost is the CanvasImagePool formula with the side clamped to 64...1024")
    func cost() {
        #expect(
            RemoteImageCache.cost(of: TestImages.cgImage(width: 8, height: 8)) == 64 * (64 * 4 + 64)
        )
        #expect(
            RemoteImageCache.cost(of: TestImages.cgImage(width: 256, height: 100)) == 256
                * (256 * 4 + 64))
        #expect(
            RemoteImageCache.cost(of: TestImages.cgImage(width: 2_000, height: 10))
                == 1_024 * (1_024 * 4 + 64))
    }

    @Test("The oldest entry goes first when the byte limit is reached")
    func lruEviction() {
        let image = TestImages.cgImage(width: 512, height: 512)
        let cost = RemoteImageCache.cost(of: image)
        let cache = RemoteImageCache(byteLimit: cost * 2 + cost / 2)
        cache.insert(image, key: "a", grant: .global, host: "a.example.com")
        cache.insert(image, key: "b", grant: .global, host: "b.example.com")
        #expect(cache.count == 2)
        // Touch "a": "b" is now the oldest.
        #expect(cache.image(for: "a") != nil)
        cache.insert(image, key: "c", grant: .global, host: "c.example.com")
        #expect(cache.image(for: "b") == nil)
        #expect(cache.image(for: "a") != nil)
        #expect(cache.image(for: "c") != nil)
        #expect(cache.usedBytes == cost * 2)
    }

    @Test("The default limit is the 8 MB image pool limit")
    func defaultLimit() {
        let cache = RemoteImageCache()
        #expect(cache.byteLimit == 8 * 1_024 * 1_024)
        let big = TestImages.cgImage(width: 1_024, height: 1_024)
        cache.insert(big, key: "1", grant: .global, host: "h.example.com")
        cache.insert(big, key: "2", grant: .global, host: "h.example.com")
        // Two 1,024 px images (about 4.2 MB each) do not fit in 8 MB together.
        #expect(cache.count == 1)
        #expect(cache.usedBytes <= cache.byteLimit)
    }

    @Test("Dropping by grant removes exactly those entries")
    func dropByGrant() {
        let image = TestImages.cgImage()
        let cache = RemoteImageCache()
        cache.insert(image, key: "p", grant: .pattern("*.example.com"), host: "a.example.com")
        cache.insert(image, key: "q", grant: .pattern("other.net"), host: "other.net")
        cache.insert(image, key: "e", grant: .ensemble(board), host: "x.org")
        cache.insert(image, key: "g", grant: .global, host: "y.org")
        #expect(cache.drop { $0 == .pattern("*.example.com") } == 1)
        #expect(cache.image(for: "p") == nil)
        #expect(cache.drop { $0 == .ensemble(board) } == 1)
        #expect(cache.drop { $0 == .global } == 1)
        #expect(cache.count == 1)
        #expect(cache.dropAll() == 1)
        #expect(cache.usedBytes == 0)
    }

    @Test("Replacing a key does not count the old cost twice")
    func replace() {
        let cache = RemoteImageCache()
        let image = TestImages.cgImage()
        cache.insert(image, key: "k", grant: .global, host: "h.example.com")
        let once = cache.usedBytes
        cache.insert(image, key: "k", grant: .global, host: "h.example.com")
        #expect(cache.usedBytes == once)
        #expect(cache.count == 1)
    }
}
