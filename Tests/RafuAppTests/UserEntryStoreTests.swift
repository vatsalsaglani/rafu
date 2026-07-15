import Foundation
import Testing

@testable import RafuApp

@Suite("User entry store")
struct UserEntryStoreTests {
    @Test("A fresh directory has no user entries")
    func freshDirectoryHasNoEntries() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            try await #expect(store.load().isEmpty)
        }
    }

    @Test("Adding an entry persists it atomically and it round-trips via a fresh instance")
    func addPersistsAndRoundTrips() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            try await store.add(makeDescriptor(id: "my-tool"))

            let reloaded = try await UserEntryStore(baseDirectory: directory).load()
            #expect(reloaded.map(\.id) == ["my-tool"])
        }
    }

    @Test("Adding a descriptor with the same id replaces the previous entry")
    func addingSameIDReplaces() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            try await store.add(makeDescriptor(id: "my-tool", displayName: "First"))
            try await store.add(makeDescriptor(id: "my-tool", displayName: "Second"))

            let servers = try await store.load()
            #expect(servers.count == 1)
            #expect(servers.first?.displayName == "Second")
        }
    }

    @Test("Removing an id deletes only that entry")
    func removeDeletesOnlyThatEntry() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            try await store.add(makeDescriptor(id: "keep-me"))
            try await store.add(makeDescriptor(id: "remove-me"))

            try await store.remove(id: "remove-me")

            let servers = try await store.load()
            #expect(servers.map(\.id) == ["keep-me"])
        }
    }

    @Test("Removing an unknown id is a no-op")
    func removingUnknownIDIsNoOp() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            try await store.add(makeDescriptor(id: "keep-me"))
            try await store.remove(id: "does-not-exist")
            #expect(try await store.load().map(\.id) == ["keep-me"])
        }
    }

    @Test("A non-https, non-file source URL is rejected before being persisted")
    func rejectsInsecureSourceURL() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            let insecure = ServerDescriptor(
                id: "insecure-tool",
                languageIDs: ["rust"],
                displayName: "Insecure tool",
                kind: .singleBinary,
                source: ServerSource(
                    url: URL(string: "ftp://example.com/tool")!,
                    version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil),
                launchArguments: [],
                archive: ArchiveLayout(format: .rawBinary, binaryRelativePath: "tool"),
                initializationOptions: nil,
                prerequisites: []
            )

            await #expect(throws: UserEntryStoreError.insecureSourceURL(id: "insecure-tool")) {
                try await store.add(insecure)
            }
            try await #expect(store.load().isEmpty)
        }
    }

    @Test("An explicit local file:// source URL is accepted")
    func acceptsLocalFileURL() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            let local = ServerDescriptor(
                id: "local-binary",
                languageIDs: ["rust"],
                displayName: "Local binary",
                kind: .singleBinary,
                source: ServerSource(
                    url: URL(fileURLWithPath: "/usr/local/bin/my-server"),
                    version: "local", checksum: nil, license: "Unknown", estimatedBytes: nil),
                launchArguments: [],
                archive: nil,
                initializationOptions: nil,
                prerequisites: []
            )

            try await store.add(local)
            #expect(try await store.load().map(\.id) == ["local-binary"])
        }
    }

    @Test("A localDiscovery descriptor (nil source) is always accepted")
    func acceptsLocalDiscoveryWithNilSource() async throws {
        try await withTemporaryDirectory { directory in
            let store = UserEntryStore(baseDirectory: directory)
            let descriptor = ServerDescriptor(
                id: "discovered-tool",
                languageIDs: ["go"],
                displayName: "Discovered tool",
                kind: .localDiscovery,
                source: nil,
                launchArguments: [],
                archive: nil,
                initializationOptions: nil,
                prerequisites: []
            )
            try await store.add(descriptor)
            #expect(try await store.load().map(\.id) == ["discovered-tool"])
        }
    }

    private func makeDescriptor(id: String, displayName: String = "Tool") -> ServerDescriptor {
        ServerDescriptor(
            id: id,
            languageIDs: ["rust"],
            displayName: displayName,
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "https://example.com/\(id).zip")!,
                version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil),
            launchArguments: [],
            archive: ArchiveLayout(format: .zip, binaryRelativePath: "bin/tool"),
            initializationOptions: nil,
            prerequisites: []
        )
    }
}
