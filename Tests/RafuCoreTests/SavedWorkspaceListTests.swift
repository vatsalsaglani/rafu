import Foundation
import Testing

@testable import RafuCore

@Suite("Saved workspace list")
struct SavedWorkspaceListTests {
    private func entry(_ name: String, opened: Double = 0) -> SavedWorkspaceEntry {
        SavedWorkspaceEntry(
            filePath: "/saved/\(name).rafuworkspace", displayName: name,
            folderPaths: ["/work/\(name)", "/work/shared"],
            lastOpened: Date(timeIntervalSinceReferenceDate: opened))
    }

    @Test("Recording moves an entry to the front without duplicates")
    func recordOrder() {
        var list = SavedWorkspaceList()
        list.record(entry("a"))
        list.record(entry("b"))
        list.record(entry("a", opened: 5))
        #expect(list.entries.map(\.displayName) == ["a", "b"])
        #expect(list.entries.first?.lastOpened == Date(timeIntervalSinceReferenceDate: 5))
        list.remove(filePath: "/saved/./b.rafuworkspace")
        #expect(list.entries.map(\.displayName) == ["a"])
    }

    @Test("The list is bounded")
    func capacity() {
        var list = SavedWorkspaceList()
        for index in 0..<(SavedWorkspaceList.capacity + 10) { list.record(entry("w\(index)")) }
        #expect(list.entries.count == SavedWorkspaceList.capacity)
        #expect(list.entries.first?.displayName == "w\(SavedWorkspaceList.capacity + 9)")
    }

    @Test("Search matches names and folder paths, ignoring case")
    func search() {
        let entries = [entry("Shop"), entry("Blog")]
        #expect(SavedWorkspaceList.filter(entries, query: "shop").map(\.displayName) == ["Shop"])
        #expect(SavedWorkspaceList.filter(entries, query: "/WORK/blog").count == 1)
        #expect(SavedWorkspaceList.filter(entries, query: "shared").count == 2)
        #expect(SavedWorkspaceList.filter(entries, query: "  ").count == 2)
        #expect(SavedWorkspaceList.filter(entries, query: "nothing").isEmpty)
    }

    @Test("Damaged or newer data reads as an empty list")
    func tolerantDecode() throws {
        #expect(SavedWorkspaceList.decode(Data("junk".utf8)).entries.isEmpty)
        let newer = #"{"formatVersion": 9, "entries": []}"#
        #expect(SavedWorkspaceList.decode(Data(newer.utf8)).entries.isEmpty)
        var list = SavedWorkspaceList()
        list.record(entry("a", opened: 1_000))
        let decoded = SavedWorkspaceList.decode(try list.encoded())
        #expect(decoded == list)
    }

    @Test("The store writes atomically to its file and reads it back")
    func storeRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-saved-workspaces-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "nested/saved-workspaces.json")
        let store = SavedWorkspaceListStore(fileURL: fileURL)
        #expect(await store.load().isEmpty)
        try await store.record(entry("a"))
        try await store.record(entry("b"))
        #expect(await store.load().map(\.displayName) == ["b", "a"])
        let remaining = try await store.remove(filePath: "/saved/b.rafuworkspace")
        #expect(remaining.map(\.displayName) == ["a"])
        let other = SavedWorkspaceListStore(fileURL: fileURL)
        #expect(await other.load().map(\.displayName) == ["a"])
        let contents = try FileManager.default.contentsOfDirectory(
            atPath: fileURL.deletingLastPathComponent().path)
        #expect(contents == ["saved-workspaces.json"])
    }

    @Test("An oversized file reads as absent")
    func boundedRead() throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "rafu-saved-bound-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "big.json")
        try Data(repeating: 0x20, count: 64).write(to: url)
        #expect(SavedWorkspaceListStore.readBounded(url, limit: 63) == nil)
        #expect(SavedWorkspaceListStore.readBounded(url, limit: 64)?.count == 64)
    }
}
