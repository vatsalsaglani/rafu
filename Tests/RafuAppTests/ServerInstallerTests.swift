import CryptoKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Server installer")
struct ServerInstallerTests {
    @Test("Installs a gzip-compressed singleBinary asset and sets the executable bit")
    func installsGzipSingleBinary() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("#!/bin/sh\necho rust-analyzer\n".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeGzip(
                    binaryName: "rust-analyzer", contents: contents, in: fixtures)

                let descriptor = ServerDescriptor(
                    id: "rust-analyzer",
                    languageIDs: ["rust"],
                    displayName: "rust-analyzer",
                    kind: .singleBinary,
                    source: ServerSource(
                        url: URL(string: "https://example.com/rust-analyzer.gz")!,
                        version: "2024-01-01", checksum: nil, license: "MIT",
                        estimatedBytes: nil),
                    launchArguments: [],
                    archive: ArchiveLayout(format: .gzip, binaryRelativePath: "rust-analyzer"),
                    initializationOptions: nil,
                    prerequisites: []
                )

                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase))

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false)

                #expect(result.checksumStatus == .notPublished)
                #expect(FileManager.default.fileExists(atPath: result.binaryURL.path))
                let attributes = try FileManager.default.attributesOfItem(
                    atPath: result.binaryURL.path)
                let permissions = attributes[.posixPermissions] as? NSNumber
                #expect(permissions?.uint16Value == 0o755)
                let installedContents = try Data(contentsOf: result.binaryURL)
                #expect(installedContents == contents)
            }
        }
    }

    @Test("Installs a zip singleBinary asset with a nested binaryRelativePath")
    func installsZipSingleBinary() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("clangd fixture".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeZip(
                    relativePath: "clangd_18.1.3/bin/clangd", contents: contents, in: fixtures)

                let descriptor = ServerDescriptor(
                    id: "clangd",
                    languageIDs: ["cpp"],
                    displayName: "clangd",
                    kind: .singleBinary,
                    source: ServerSource(
                        url: URL(string: "https://example.com/clangd-mac-18.1.3.zip")!,
                        version: "18.1.3", checksum: nil,
                        license: "Apache-2.0 WITH LLVM-exception", estimatedBytes: nil),
                    launchArguments: [],
                    archive: ArchiveLayout(
                        format: .zip, binaryRelativePath: "clangd_18.1.3/bin/clangd"),
                    initializationOptions: nil,
                    prerequisites: []
                )

                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase))

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false)

                #expect(
                    result.binaryURL.path
                        == installBase.appending(
                            path: "LanguageServers/clangd/clangd_18.1.3/bin/clangd"
                        ).path)
                #expect(try Data(contentsOf: result.binaryURL) == contents)
            }
        }
    }

    @Test("Installs a tarGzip nodeHosted asset with an npm-style package/ prefix")
    func installsTarGzipNodeHosted() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("console.log('pyright fixture')\n".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeTarGzip(
                    relativePath: "package/dist/pyright-langserver.js", contents: contents,
                    in: fixtures)

                let descriptor = ServerDescriptor(
                    id: "pyright",
                    languageIDs: ["python"],
                    displayName: "Pyright",
                    kind: .nodeHosted,
                    source: ServerSource(
                        url: URL(
                            string: "https://registry.npmjs.org/pyright/-/pyright-1.1.377.tgz")!,
                        version: "1.1.377", checksum: nil, license: "MIT", estimatedBytes: nil),
                    launchArguments: ["--stdio"],
                    archive: ArchiveLayout(
                        format: .tarGzip, binaryRelativePath: "package/dist/pyright-langserver.js"
                    ),
                    initializationOptions: nil,
                    prerequisites: [.managedNodeRuntime]
                )

                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase))

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false)

                #expect(try Data(contentsOf: result.binaryURL) == contents)
            }
        }
    }

    @Test("A matching checksum is verified before install")
    func matchingChecksumIsVerified() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("checksummed fixture".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeGzip(
                    binaryName: "tool", contents: contents, in: fixtures)
                let gzippedContents = try Data(contentsOf: assetURL)
                let digest = SHA256.hash(data: gzippedContents)
                let hex = digest.map { String(format: "%02x", $0) }.joined()

                let descriptor = makeDescriptor(
                    id: "checksummed-tool", format: .gzip, binaryRelativePath: "tool",
                    urlSuffix: "tool.gz", checksum: hex)

                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase))

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false)
                #expect(result.checksumStatus == .verified)
            }
        }
    }

    @Test("A mismatched checksum aborts the install and installs nothing")
    func mismatchedChecksumAbortsInstall() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("tampered fixture".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeGzip(
                    binaryName: "tool", contents: contents, in: fixtures)

                let descriptor = makeDescriptor(
                    id: "mismatched-tool", format: .gzip, binaryRelativePath: "tool",
                    urlSuffix: "tool.gz", checksum: String(repeating: "0", count: 64))

                let layout = InstallLayout(baseDirectory: installBase)
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL), layout: layout)

                await #expect(throws: ServerInstallError.checksumMismatch) {
                    try await installer.install(
                        descriptor: descriptor, consentToQuarantineRemoval: false)
                }
                #expect(
                    !FileManager.default.fileExists(
                        atPath: layout.serverDirectory(id: "mismatched-tool").path))
            }
        }
    }

    @Test("A zip-slip tar.gz fixture (a symlink escaping staging) is rejected and never installed")
    func zipSlipFixtureIsRejected() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try ArchiveFixtureBuilder.makeZipSlipTarGzip(
                    escapingLinkName: "escape", in: fixtures)

                let descriptor = makeDescriptor(
                    id: "zip-slip-tool", format: .tarGzip, binaryRelativePath: "escape",
                    urlSuffix: "zip-slip.tar.gz", checksum: nil)

                let layout = InstallLayout(baseDirectory: installBase)
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL), layout: layout)

                await #expect(throws: ServerInstallError.pathTraversal) {
                    try await installer.install(
                        descriptor: descriptor, consentToQuarantineRemoval: false)
                }
                #expect(
                    !FileManager.default.fileExists(
                        atPath: layout.serverDirectory(id: "zip-slip-tool").path))
            }
        }
    }

    @Test("An internal (within-staging) symlink is accepted, mirroring Node's bin/npm links")
    func internalSymlinkIsAccepted() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("#!/bin/sh\necho tool\n".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeInternalSymlinkTarGzip(
                    binaryContents: contents, in: fixtures)

                let descriptor = makeDescriptor(
                    id: "internal-symlink-tool", format: .tarGzip,
                    binaryRelativePath: "package/bin/tool", urlSuffix: "internal-symlink.tar.gz",
                    checksum: nil)

                let layout = InstallLayout(baseDirectory: installBase)
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL), layout: layout)

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false)

                #expect(try Data(contentsOf: result.binaryURL) == contents)
                // The internal symlink survives the move and still resolves.
                let alias = layout.serverDirectory(id: "internal-symlink-tool").appending(
                    path: "package/bin/alias")
                #expect(FileManager.default.fileExists(atPath: alias.path))
            }
        }
    }

    @Test("A missing declared binary after unpack is rejected as binaryMissing")
    func missingDeclaredBinaryIsRejected() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                // The zip fixture really contains `clangd_18.1.3/bin/clangd`;
                // unlike the gzip case (which is renamed to match the
                // declared path during unpack), `ditto` preserves a zip's
                // real entry paths verbatim, so declaring a different path
                // here reliably reproduces "the binary isn't where the
                // descriptor says it is."
                let assetURL = try ArchiveFixtureBuilder.makeZip(
                    relativePath: "clangd_18.1.3/bin/clangd", contents: Data("x".utf8),
                    in: fixtures)

                let descriptor = makeDescriptor(
                    id: "wrong-name-tool", format: .zip,
                    binaryRelativePath: "clangd_99.0.0/bin/clangd",
                    urlSuffix: "clangd-mac-18.1.3.zip", checksum: nil)

                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase))

                await #expect(throws: ServerInstallError.binaryMissing) {
                    try await installer.install(
                        descriptor: descriptor, consentToQuarantineRemoval: false)
                }
            }
        }
    }

    @Test("A local file:// binary entry is validated in place without downloading")
    func localFileEntrySkipsDownload() async throws {
        try await withTemporaryDirectory { directory in
            let binaryURL = directory.appending(path: "already-installed-tool")
            try Data("#!/bin/sh\n".utf8).write(to: binaryURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)

            let descriptor = ServerDescriptor(
                id: "local-tool",
                languageIDs: ["rust"],
                displayName: "Local tool",
                kind: .singleBinary,
                source: ServerSource(
                    url: binaryURL, version: "local", checksum: nil, license: "Unknown",
                    estimatedBytes: nil),
                launchArguments: [],
                archive: nil,
                initializationOptions: nil,
                prerequisites: []
            )

            let downloader = FixtureAssetDownloader(fixtureURL: binaryURL)
            let installer = ServerInstaller(downloader: downloader)

            let result = try await installer.install(
                descriptor: descriptor, consentToQuarantineRemoval: false)

            #expect(result.binaryURL == binaryURL)
            #expect(result.checksumStatus == .notApplicable)
            #expect(await downloader.downloadCount == 0)
        }
    }

    @Test("A local file:// entry pointing at a missing binary is rejected")
    func localFileEntryMissingBinaryIsRejected() async throws {
        try await withTemporaryDirectory { directory in
            let missingURL = directory.appending(path: "does-not-exist")
            let descriptor = ServerDescriptor(
                id: "missing-local-tool",
                languageIDs: ["rust"],
                displayName: "Missing local tool",
                kind: .singleBinary,
                source: ServerSource(
                    url: missingURL, version: "local", checksum: nil, license: "Unknown",
                    estimatedBytes: nil),
                launchArguments: [],
                archive: nil,
                initializationOptions: nil,
                prerequisites: []
            )

            let installer = ServerInstaller(
                downloader: FixtureAssetDownloader(fixtureURL: missingURL))

            await #expect(throws: ServerInstallError.binaryMissing) {
                try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false)
            }
        }
    }

    @Test("Reinstalling the same server id atomically replaces the previous install")
    func reinstallReplacesPreviousInstall() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let layout = InstallLayout(baseDirectory: installBase)

                let firstAsset = try ArchiveFixtureBuilder.makeGzip(
                    binaryName: "tool", contents: Data("version-1".utf8), in: fixtures)
                let firstDescriptor = makeDescriptor(
                    id: "reinstall-tool", format: .gzip, binaryRelativePath: "tool",
                    urlSuffix: "tool.gz", checksum: nil)
                let firstInstaller = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: firstAsset), layout: layout)
                let firstResult = try await firstInstaller.install(
                    descriptor: firstDescriptor, consentToQuarantineRemoval: false)
                #expect(try Data(contentsOf: firstResult.binaryURL) == Data("version-1".utf8))

                let secondFixtures = fixtures.appending(path: "second", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: secondFixtures, withIntermediateDirectories: true)
                let secondAsset = try ArchiveFixtureBuilder.makeGzip(
                    binaryName: "tool", contents: Data("version-2".utf8), in: secondFixtures)
                let secondInstaller = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: secondAsset), layout: layout)
                let secondResult = try await secondInstaller.install(
                    descriptor: firstDescriptor, consentToQuarantineRemoval: false)

                #expect(try Data(contentsOf: secondResult.binaryURL) == Data("version-2".utf8))
            }
        }
    }

    // MARK: - npm dependency resolution (nodeHosted, npmPackageRoot)

    @Test(
        "An npmPackageRoot install runs the resolver in staging, and its node_modules fixture survives the atomic move"
    )
    func npmDependenciesSurviveAtomicMove() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("#!/usr/bin/env node\n".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeTarGzip(
                    relativePath: "package/lib/cli.mjs", contents: contents, in: fixtures)

                let descriptor = makeNodeHostedDescriptor(
                    id: "typescript-language-server", npmPackageRoot: "package")

                let layout = InstallLayout(baseDirectory: installBase)
                let resolver = FakeNodeDependencyResolver()
                let nodeExecutableURL = installBase.appending(path: "node-runtime/bin/node")
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL), layout: layout,
                    resolver: resolver)

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false,
                    nodeExecutableURL: nodeExecutableURL)

                #expect(await resolver.invocationCount == 1)
                let recordedPackageDirectory = await resolver.recordedPackageDirectory
                #expect(recordedPackageDirectory?.path.hasSuffix("/package") == true)
                #expect(await resolver.recordedNodeExecutableURL == nodeExecutableURL)

                let typescriptPackageJSON = layout.serverDirectory(
                    id: "typescript-language-server"
                ).appending(path: "package/node_modules/typescript/package.json")
                #expect(FileManager.default.fileExists(atPath: typescriptPackageJSON.path))
                #expect(try Data(contentsOf: result.binaryURL) == contents)
            }
        }
    }

    @Test(
        "A descriptor with npmPackageRoot but no nodeExecutableURL throws nodeRuntimeUnavailable and installs nothing"
    )
    func missingNodeExecutableURLThrowsNodeRuntimeUnavailable() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try ArchiveFixtureBuilder.makeTarGzip(
                    relativePath: "package/lib/cli.mjs", contents: Data("x".utf8), in: fixtures)

                let descriptor = makeNodeHostedDescriptor(
                    id: "node-no-url-tool", npmPackageRoot: "package")

                let layout = InstallLayout(baseDirectory: installBase)
                let resolver = FakeNodeDependencyResolver()
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL), layout: layout,
                    resolver: resolver)

                await #expect(throws: ServerInstallError.nodeRuntimeUnavailable) {
                    try await installer.install(
                        descriptor: descriptor, consentToQuarantineRemoval: false,
                        nodeExecutableURL: nil)
                }
                #expect(await resolver.invocationCount == 0)
                #expect(
                    !FileManager.default.fileExists(
                        atPath: layout.serverDirectory(id: "node-no-url-tool").path))
            }
        }
    }

    @Test(
        "A Pyright-shaped fixture (npmPackageRoot nil) never invokes the npm dependency resolver"
    )
    func pyrightShapedFixtureNeverInvokesResolver() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let contents = Data("console.log('pyright fixture')\n".utf8)
                let assetURL = try ArchiveFixtureBuilder.makeTarGzip(
                    relativePath: "package/dist/pyright-langserver.js", contents: contents,
                    in: fixtures)

                let descriptor = makeNodeHostedDescriptor(
                    id: "pyright-fixture", binaryRelativePath: "package/dist/pyright-langserver.js",
                    npmPackageRoot: nil)

                let resolver = FakeNodeDependencyResolver()
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL),
                    layout: InstallLayout(baseDirectory: installBase), resolver: resolver)

                let result = try await installer.install(
                    descriptor: descriptor, consentToQuarantineRemoval: false,
                    nodeExecutableURL: installBase.appending(path: "node-runtime/bin/node"))

                #expect(await resolver.invocationCount == 0)
                #expect(try Data(contentsOf: result.binaryURL) == contents)
            }
        }
    }

    @Test(
        "A non-zero npm install exit status is propagated as dependencyResolutionFailed and installs nothing"
    )
    func npmInstallFailureAbortsInstall() async throws {
        try await withTemporaryDirectory { fixtures in
            try await withTemporaryDirectory { installBase in
                let assetURL = try ArchiveFixtureBuilder.makeTarGzip(
                    relativePath: "package/lib/cli.mjs", contents: Data("x".utf8), in: fixtures)

                let descriptor = makeNodeHostedDescriptor(
                    id: "npm-failure-tool", npmPackageRoot: "package")

                let layout = InstallLayout(baseDirectory: installBase)
                let resolver = FakeNodeDependencyResolver(failureStatus: 1)
                let installer = ServerInstaller(
                    downloader: FixtureAssetDownloader(fixtureURL: assetURL), layout: layout,
                    resolver: resolver)

                await #expect(throws: ServerInstallError.dependencyResolutionFailed(1)) {
                    try await installer.install(
                        descriptor: descriptor, consentToQuarantineRemoval: false,
                        nodeExecutableURL: installBase.appending(path: "node-runtime/bin/node"))
                }
                #expect(await resolver.invocationCount == 1)
                #expect(
                    !FileManager.default.fileExists(
                        atPath: layout.serverDirectory(id: "npm-failure-tool").path))
            }
        }
    }

    private func makeDescriptor(
        id: String, format: ArchiveFormat, binaryRelativePath: String, urlSuffix: String,
        checksum: String?
    ) -> ServerDescriptor {
        ServerDescriptor(
            id: id,
            languageIDs: ["rust"],
            displayName: id,
            kind: .singleBinary,
            source: ServerSource(
                url: URL(string: "https://example.com/\(urlSuffix)")!,
                version: "1.0.0", checksum: checksum, license: "MIT", estimatedBytes: nil),
            launchArguments: [],
            archive: ArchiveLayout(format: format, binaryRelativePath: binaryRelativePath),
            initializationOptions: nil,
            prerequisites: []
        )
    }

    private func makeNodeHostedDescriptor(
        id: String, binaryRelativePath: String = "package/lib/cli.mjs", npmPackageRoot: String?
    ) -> ServerDescriptor {
        ServerDescriptor(
            id: id,
            languageIDs: ["typescript"],
            displayName: id,
            kind: .nodeHosted,
            source: ServerSource(
                url: URL(string: "https://registry.npmjs.org/\(id)/-/\(id)-1.0.0.tgz")!,
                version: "1.0.0", checksum: nil, license: "MIT", estimatedBytes: nil),
            launchArguments: ["--stdio"],
            archive: ArchiveLayout(
                format: .tarGzip, binaryRelativePath: binaryRelativePath,
                npmPackageRoot: npmPackageRoot),
            initializationOptions: nil,
            prerequisites: [.managedNodeRuntime]
        )
    }
}
