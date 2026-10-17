import Foundation
import Testing

@testable import RafuApp

@Suite("Recent workspace bookmark persistence")
struct RecentWorkspaceBookmarkPersistenceTests {
    @Test("A serialized recent entry resolves its security-scoped bookmark")
    func bookmarkPersistenceRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-recents-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Exercise the persisted entry and resolver without reading or changing
        // UserDefaults.standard, which belongs to the running app/test process.
        let bookmark = try directory.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let opened = Date(timeIntervalSinceReferenceDate: 1_000)
        let entry = RecentWorkspaceEntry(
            bookmark: bookmark, rootPath: directory.path, displayName: "Test workspace",
            lastOpened: opened)
        let data = try JSONEncoder().encode([entry])
        let decoded = try JSONDecoder().decode([RecentWorkspaceEntry].self, from: data)
        let restored = try #require(decoded.first)
        #expect(decoded.count == 1)
        #expect(!restored.bookmark.isEmpty)
        #expect(restored.bookmark == bookmark)
        #expect(restored.rootPath == directory.path)
        #expect(restored.displayName == "Test workspace")
        #expect(restored.lastOpened == opened)
        #expect(restored.id == directory.path)

        let resolved = try RecentWorkspacesStore().resolve(restored)
        #expect(resolved.resolvingSymlinksInPath().path == directory.resolvingSymlinksInPath().path)
    }

    @Test("Invalid bookmark data fails resolution")
    func invalidBookmarkFailsResolution() {
        let entry = RecentWorkspaceEntry(
            bookmark: Data(), rootPath: "/unused", displayName: "Invalid",
            lastOpened: Date(timeIntervalSinceReferenceDate: 0))
        #expect(throws: (any Error).self) {
            try RecentWorkspacesStore().resolve(entry)
        }
    }
}
