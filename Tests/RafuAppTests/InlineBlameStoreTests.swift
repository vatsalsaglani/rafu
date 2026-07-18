import Foundation
import Testing

@testable import RafuApp

@Suite("Inline blame store")
struct InlineBlameStoreTests {
    private func blame(_ summary: String = "test") -> GitBlame {
        GitBlame(lines: [
            GitBlameLine(
                lineNumber: 1,
                commitID: String(repeating: "a", count: 40),
                shortID: "aaaaaaaa",
                author: "Ada Lovelace",
                time: Date(timeIntervalSince1970: 0),
                summary: summary,
                isBoundary: false
            )
        ])
    }

    @Test("Returns the cached blame for a matching key")
    func hitOnMatchingKey() {
        var store = InlineBlameStore()
        let key = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 1)
        store.store(blame(), for: key)
        #expect(store.blame(for: key) != nil)
    }

    @Test("Misses when the path changes")
    func missOnPathChange() {
        var store = InlineBlameStore()
        let key = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 1)
        store.store(blame(), for: key)
        let otherKey = InlineBlameCacheKey(path: "b.swift", headOID: "head1", revision: 1)
        #expect(store.blame(for: otherKey) == nil)
    }

    @Test("Misses when the HEAD OID changes")
    func missOnHeadChange() {
        var store = InlineBlameStore()
        let key = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 1)
        store.store(blame(), for: key)
        let otherKey = InlineBlameCacheKey(path: "a.swift", headOID: "head2", revision: 1)
        #expect(store.blame(for: otherKey) == nil)
    }

    @Test("Misses when the document revision changes")
    func missOnRevisionChange() {
        var store = InlineBlameStore()
        let key = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 1)
        store.store(blame(), for: key)
        let otherKey = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 2)
        #expect(store.blame(for: otherKey) == nil)
    }

    @Test("Storing a new key evicts the previous entry — active file only")
    func evictsPreviousEntryOnNewKey() {
        var store = InlineBlameStore()
        let firstKey = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 1)
        store.store(blame("first"), for: firstKey)
        let secondKey = InlineBlameCacheKey(path: "b.swift", headOID: "head1", revision: 1)
        store.store(blame("second"), for: secondKey)

        #expect(store.blame(for: firstKey) == nil)
        #expect(store.blame(for: secondKey)?.lines.first?.summary == "second")
    }

    @Test("Explicit invalidation clears the retained entry")
    func explicitInvalidation() {
        var store = InlineBlameStore()
        let key = InlineBlameCacheKey(path: "a.swift", headOID: "head1", revision: 1)
        store.store(blame(), for: key)
        store.invalidate()
        #expect(store.blame(for: key) == nil)
    }

    @Test("An empty store misses any key")
    func emptyStoreMisses() {
        let store = InlineBlameStore()
        let key = InlineBlameCacheKey(path: "a.swift", headOID: nil, revision: 0)
        #expect(store.blame(for: key) == nil)
    }
}
