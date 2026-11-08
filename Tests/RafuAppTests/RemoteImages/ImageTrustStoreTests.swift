import Foundation
import Testing

@testable import RafuApp

@Suite("Image trust store")
struct ImageTrustStoreTests {
    private let suffixes = TestSuffixes.list

    private func pattern(_ text: String) throws -> HostPattern {
        try HostPattern.parse(text, suffixes: suffixes)
    }

    @Test("A missing file is an empty list and nothing is created")
    func missingFile() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let store = ImageTrustStore(fileURL: directory.trustFile)
        let report = await store.load(suffixes: suffixes)
        #expect(report.entries.isEmpty)
        #expect(report.skipped == 0)
        #expect(!report.fileWasUnreadable)
        #expect(!FileManager.default.fileExists(atPath: directory.url.path))
    }

    @Test("The file is written with mode 0600 and survives a reload")
    func writeAndReload() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let store = ImageTrustStore(fileURL: directory.trustFile)
        _ = await store.load(suffixes: suffixes)
        try await store.add(pattern("*.example.com"), source: .confirm)
        try await store.add(pattern("cdn.other.net"), source: .settings)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.trustFile.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        // No temporary file is left behind.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(names == ["image-trust.json"])

        let reloaded = ImageTrustStore(fileURL: directory.trustFile)
        let report = await reloaded.load(suffixes: suffixes)
        #expect(report.entries.map(\.pattern) == ["*.example.com", "cdn.other.net"])
        #expect(report.entries.map(\.source) == [.confirm, .settings])
        #expect(report.skipped == 0)
    }

    @Test("A duplicate is not added twice")
    func duplicate() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let store = ImageTrustStore(fileURL: directory.trustFile)
        try await store.add(pattern("example.com"), source: .settings)
        let entries = try await store.add(pattern("EXAMPLE.com."), source: .confirm)
        #expect(entries.count == 1)
    }

    @Test("The list holds at most 200 entries")
    func cap() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let store = ImageTrustStore(fileURL: directory.trustFile)
        for index in 0..<ImageTrustStore.maxEntries {
            try await store.add(pattern("h\(index).example.com"), source: .settings)
        }
        await #expect(throws: ImageTrustStoreError.full) {
            try await store.add(self.pattern("one-more.example.com"), source: .settings)
        }
        #expect(await store.entries.count == 200)
    }

    @Test("Invalid, duplicate and surplus entries are skipped on load")
    func invalidEntriesSkipped() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        try FileManager.default.createDirectory(
            at: directory.url, withIntermediateDirectories: true)
        let json = """
            {"version":1,"entries":[
              {"pattern":"*.example.com","addedAt":"2026-11-07T10:00:00Z","source":"confirm"},
              {"pattern":"*.com","addedAt":"2026-11-07T10:00:00Z","source":"settings"},
              {"pattern":"127.0.0.1","addedAt":"2026-11-07T10:00:00Z","source":"settings"},
              {"pattern":"EXAMPLE.net","addedAt":"2026-11-07T10:00:00Z","source":"settings"},
              {"pattern":"example.net","addedAt":"2026-11-07T10:00:00Z","source":"settings"},
              {"pattern":"missing-fields.example.com"},
              {"pattern":"ok.example.org","addedAt":"2026-11-07T10:00:00Z","source":"unknown"}
            ]}
            """
        try Data(json.utf8).write(to: directory.trustFile)
        let report = await ImageTrustStore(fileURL: directory.trustFile).load(suffixes: suffixes)
        #expect(report.entries.map(\.pattern) == ["*.example.com", "example.net"])
        #expect(report.skipped == 5)
        #expect(!report.fileWasUnreadable)
    }

    @Test("A file that cannot be read is renamed, not overwritten or deleted")
    func unreadableFile() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        try FileManager.default.createDirectory(
            at: directory.url, withIntermediateDirectories: true)
        let garbage = Data("this is not json".utf8)
        try garbage.write(to: directory.trustFile)
        let store = ImageTrustStore(fileURL: directory.trustFile)
        let report = await store.load(suffixes: suffixes)
        #expect(report.fileWasUnreadable)
        #expect(report.entries.isEmpty)
        let kept = directory.url.appending(path: ImageTrustStore.invalidFileName)
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(!FileManager.default.fileExists(atPath: directory.trustFile.path))
        // The user adds an entry: a new file appears, the kept file stays.
        try await store.add(pattern("example.com"), source: .settings)
        #expect(try Data(contentsOf: kept) == garbage)
        #expect(FileManager.default.fileExists(atPath: directory.trustFile.path))
    }

    @Test("A file with the wrong version is kept aside")
    func wrongVersion() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        try FileManager.default.createDirectory(
            at: directory.url, withIntermediateDirectories: true)
        try Data(#"{"version":2,"entries":[]}"#.utf8).write(to: directory.trustFile)
        let report = await ImageTrustStore(fileURL: directory.trustFile).load(suffixes: suffixes)
        #expect(report.fileWasUnreadable)
        #expect(
            FileManager.default.fileExists(
                atPath: directory.url.appending(path: ImageTrustStore.invalidFileName).path))
    }

    @Test("Undo puts back the list as it was, one change at a time")
    func undo() async throws {
        let directory = TestDirectory()
        defer { directory.remove() }
        let store = ImageTrustStore(fileURL: directory.trustFile)
        try await store.add(pattern("a.example.com"), source: .settings)
        try await store.add(pattern("b.example.com"), source: .settings)
        try await store.remove(pattern: "a.example.com")
        #expect(await store.entries.map(\.pattern) == ["b.example.com"])
        try await store.undoLast()
        #expect(await store.entries.map(\.pattern) == ["a.example.com", "b.example.com"])
        try await store.removeAll()
        #expect(await store.entries.isEmpty)
        try await store.undoLast()
        #expect(await store.entries.count == 2)
        // The file follows the list.
        let reloaded = await ImageTrustStore(fileURL: directory.trustFile).load(suffixes: suffixes)
        #expect(reloaded.entries.count == 2)
    }

    @Test("No agent surface knows the trust list")
    func agentsCannotSeeIt() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        var files: [URL] = []
        let bridge = root.appending(
            path: "Sources/RafuCore/CanvasBridge", directoryHint: .isDirectory)
        let enumerator = try #require(
            FileManager.default.enumerator(at: bridge, includingPropertiesForKeys: nil))
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        files.append(
            root.appending(path: "Sources/RafuApp/Canvas/Integration/CanvasAgentActions.swift"))
        #expect(files.count > 3)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for word in ["image-trust", "ImageTrustStore", "RemoteImageTrustModel"] {
                #expect(!text.contains(word), "\(file.lastPathComponent) mentions \(word)")
            }
        }
    }
}
