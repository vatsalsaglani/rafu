import CryptoKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Node runtime manager")
struct NodeRuntimeManagerTests {
    @Test(
        "Installs the pinned Node runtime from a fixture tarball wrapped like a real Node release")
    func installsFromFixtureTarball() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try makeNodeFixtureTarball(
                    version: NodeRuntimeManager.pinnedVersion, in: fixtures)
                let downloader = FixtureAssetDownloader(fixtureURL: assetURL)
                let manager = NodeRuntimeManager(
                    downloader: downloader,
                    layout: InstallLayout(baseDirectory: installBase),
                    expectedChecksum: nil
                )

                let nodeExecutable = try await manager.ensureInstalled(
                    consentToQuarantineRemoval: false)

                #expect(FileManager.default.isExecutableFile(atPath: nodeExecutable.path))
                #expect(
                    nodeExecutable.path
                        == installBase.appending(
                            path:
                                "Runtimes/node-\(NodeRuntimeManager.pinnedVersion)/bin/node"
                        ).path)
                #expect(await downloader.downloadCount == 1)
            }
        }
    }

    @Test("Is idempotent: an already-installed runtime is never re-downloaded")
    func idempotentAgainstAlreadyInstalledRuntime() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try makeNodeFixtureTarball(
                    version: NodeRuntimeManager.pinnedVersion, in: fixtures)
                let downloader = FixtureAssetDownloader(fixtureURL: assetURL)
                let manager = NodeRuntimeManager(
                    downloader: downloader,
                    layout: InstallLayout(baseDirectory: installBase),
                    expectedChecksum: nil
                )

                _ = try await manager.ensureInstalled(consentToQuarantineRemoval: false)
                #expect(await downloader.downloadCount == 1)

                // A second call, and a second manager instance sharing the
                // same installed layout, must both find `bin/node` already
                // installed and skip downloading again.
                _ = try await manager.ensureInstalled(consentToQuarantineRemoval: false)
                #expect(await downloader.downloadCount == 1)

                let secondManager = NodeRuntimeManager(
                    downloader: downloader,
                    layout: InstallLayout(baseDirectory: installBase),
                    expectedChecksum: nil
                )
                _ = try await secondManager.ensureInstalled(consentToQuarantineRemoval: false)
                #expect(await downloader.downloadCount == 1)
            }
        }
    }

    @Test("Verifies the runtime tarball's checksum when one is configured")
    func verifiesChecksumWhenConfigured() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try makeNodeFixtureTarball(
                    version: NodeRuntimeManager.pinnedVersion, in: fixtures)
                let digest = SHA256.hash(data: try Data(contentsOf: assetURL))
                let hex = digest.map { String(format: "%02x", $0) }.joined()

                let manager = NodeRuntimeManager(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase),
                    expectedChecksum: hex
                )

                let nodeExecutable = try await manager.ensureInstalled(
                    consentToQuarantineRemoval: false)
                #expect(FileManager.default.isExecutableFile(atPath: nodeExecutable.path))
            }
        }
    }

    @Test("A mismatched checksum aborts the runtime install")
    func mismatchedChecksumAborts() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try makeNodeFixtureTarball(
                    version: NodeRuntimeManager.pinnedVersion, in: fixtures)
                let manager = NodeRuntimeManager(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase),
                    expectedChecksum: String(repeating: "0", count: 64)
                )

                await #expect(throws: ServerInstallError.checksumMismatch) {
                    try await manager.ensureInstalled(consentToQuarantineRemoval: false)
                }

                let layout = InstallLayout(baseDirectory: installBase)
                #expect(
                    !FileManager.default.fileExists(
                        atPath: layout.runtimesRoot.appending(
                            path: "node-\(NodeRuntimeManager.pinnedVersion)"
                        ).path))
            }
        }
    }

    /// Builds a `.tar.gz` shaped like a real Node.js release: everything
    /// wrapped in a single top-level `node-v<version>-darwin-arm64/`
    /// directory containing `bin/node`.
    private func makeNodeFixtureTarball(version: String, in directory: URL) throws -> URL {
        let wrapperName = "node-v\(version)-darwin-arm64"
        return try ArchiveFixtureBuilder.makeTarGzip(
            relativePath: "\(wrapperName)/bin/node",
            contents: Data("#!/bin/sh\necho node-fixture\n".utf8),
            in: directory
        )
    }
}
