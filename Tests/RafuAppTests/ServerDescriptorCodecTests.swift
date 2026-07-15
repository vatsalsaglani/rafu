import Foundation
import Testing

@testable import RafuApp

@Suite("ServerDescriptor codec")
struct ServerDescriptorCodecTests {
    @Test("Round-trips a singleBinary descriptor with a checksum")
    func roundTripsSingleBinaryWithChecksum() throws {
        let descriptor = ServerDescriptor(
            id: "example",
            languageIDs: ["example"],
            displayName: "Example",
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "https://example.com/example.zip")!,
                version: "1.0.0",
                checksum: "deadbeef",
                license: "MIT",
                estimatedBytes: 1_024
            ),
            launchArguments: ["--stdio"],
            archive: ArchiveLayout(format: .zip, binaryRelativePath: "bin/example"),
            initializationOptions: nil,
            prerequisites: [.note("An example prerequisite")]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ServerDescriptor.self, from: data)
        #expect(decoded == descriptor)
    }

    @Test("Round-trips a descriptor with nil checksum and JSONValue initializationOptions")
    func roundTripsNilChecksumAndJSONInitializationOptions() throws {
        let descriptor = ServerDescriptor(
            id: "example-json",
            languageIDs: ["example"],
            displayName: "Example JSON",
            kind: .nodeHosted,
            source: ServerSource(
                url: URL(string: "https://registry.npmjs.org/example/-/example-1.0.0.tgz")!,
                version: "1.0.0",
                checksum: nil,
                license: "MIT",
                estimatedBytes: nil
            ),
            launchArguments: ["--stdio"],
            archive: ArchiveLayout(format: .tarGzip, binaryRelativePath: "package/dist/cli.js"),
            initializationOptions: .object([
                "settings": .object(["maxLines": .number(500)]),
                "flags": .array([.bool(true), .string("verbose")]),
                "note": .null,
            ]),
            prerequisites: [.managedNodeRuntime]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ServerDescriptor.self, from: data)
        #expect(decoded == descriptor)
        #expect(decoded.source?.checksum == nil)
    }

    @Test("Round-trips a localDiscovery descriptor with a nil source")
    func roundTripsLocalDiscoveryWithNilSource() throws {
        let descriptor = ServerDescriptor(
            id: "gopls",
            languageIDs: ["go"],
            displayName: "gopls",
            kind: .localDiscovery,
            source: nil,
            launchArguments: [],
            archive: nil,
            initializationOptions: nil,
            prerequisites: [.note("Requires a Go toolchain")]
        )

        let data = try JSONEncoder().encode(descriptor)
        let decoded = try JSONDecoder().decode(ServerDescriptor.self, from: data)
        #expect(decoded == descriptor)
        #expect(decoded.source == nil)
    }

    @Test("UserEntriesFile round-trips its schema version and servers")
    func userEntriesFileRoundTrips() throws {
        let file = UserEntriesFile(
            schemaVersion: 1,
            servers: [
                ServerDescriptor(
                    id: "local-tool",
                    languageIDs: ["rust"],
                    displayName: "Local tool",
                    kind: .singleBinary,
                    source: ServerSource(
                        url: URL(fileURLWithPath: "/usr/local/bin/local-tool"),
                        version: "local",
                        checksum: nil,
                        license: "Unknown",
                        estimatedBytes: nil
                    ),
                    launchArguments: [],
                    archive: nil,
                    initializationOptions: nil,
                    prerequisites: []
                )
            ]
        )

        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(UserEntriesFile.self, from: data)
        #expect(decoded.schemaVersion == file.schemaVersion)
        #expect(decoded.servers == file.servers)
    }
}
